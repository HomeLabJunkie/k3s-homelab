#!/usr/bin/env python3
"""Rolling OS maintenance; all remote mutations are explicit and serial."""
import argparse
import json
import os
import re
from pathlib import Path
import signal
import subprocess
import sys
import textwrap
import time
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent
# Use the repository's pinned Ansible (.venv) ahead of the laptop's own.
if os.environ.get('USE_PROJECT_VENV', 'true') == 'true' and (ROOT / '.venv/bin').is_dir():
    os.environ['PATH'] = f"{ROOT / '.venv/bin'}{os.pathsep}{os.environ.get('PATH', '')}"


def run(args, capture=False):
    result = subprocess.run([str(a) for a in args], text=True,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}): {' '.join(map(str, args))}\n"
                           f"{result.stderr or ''}")
    return result.stdout.strip() if capture else None


def kube(*args):
    return run(['kubectl', '--request-timeout=20s', *args], capture=True)


def group_hosts(inventory, group, trail=()):
    if group in trail:
        raise RuntimeError(f'Inventory group cycle: {group}')
    value = inventory.get(group, {})
    hosts = list(value.get('hosts', []))
    for child in value.get('children', []):
        hosts.extend(group_hosts(inventory, child, (*trail, group)))
    return list(dict.fromkeys(hosts))


def discover(inventory, nodes):
    workers = group_hosts(inventory, 'node')
    masters = group_hosts(inventory, 'master')
    if not workers or not masters or set(workers) & set(masters):
        raise RuntimeError('Require nonempty, disjoint node and master inventory groups')
    result = []
    for role, hosts in [('worker', workers), ('control-plane', masters)]:
        for host in hosts:
            variables = inventory.get('_meta', {}).get('hostvars', {}).get(host, {})
            addresses = {host, str(variables.get('ansible_host', host))}
            matches = [n for n in nodes if n['metadata']['name'] in addresses or
                       addresses & {a['address'] for a in n['status'].get('addresses', [])}]
            if len(matches) != 1:
                raise RuntimeError(f'{host}: expected exactly one matching Kubernetes node')
            node = matches[0]
            labels = node['metadata'].get('labels', {})
            control = any(f'node-role.kubernetes.io/{r}' in labels for r in ('control-plane', 'master'))
            if control != (role == 'control-plane'):
                raise RuntimeError(f'{host}: inventory and Kubernetes roles disagree')
            if node.get('spec', {}).get('unschedulable'):
                raise RuntimeError(f'{host}: already cordoned; resolve existing maintenance first')
            result.append(dict(target=host, node=node['metadata']['name'], role=role, status='SKIP'))
    if len({r['node'] for r in result}) != len(result):
        raise RuntimeError('Multiple inventory hosts map to the same Kubernetes node')
    return result


def ready(obj):
    return any(c.get('type') == 'Ready' and c.get('status') == 'True'
               for c in obj.get('status', {}).get('conditions', []))


def longhorn_volume_ok(volume):
    # Detached volumes (scaled-down workloads, DR restore tests) report
    # robustness "unknown"; only attached volumes can prove replica health.
    status = volume.get('status', {})
    state, robustness = status.get('state'), status.get('robustness')
    return ((state == 'attached' and robustness == 'healthy') or
            (state == 'detached' and robustness != 'faulted'))


def rebuild_progress(names):
    # Lowest rebuild percentage per volume; progress only, so errors are ignored.
    try:
        engines = json.loads(kube('-n', 'longhorn-system', 'get', 'engines.longhorn.io', '-o', 'json'))['items']
    except (RuntimeError, ValueError, KeyError):
        return {}
    result = {}
    for engine in engines:
        name = engine.get('spec', {}).get('volumeName')
        progress = [s.get('progress', 0) for s in (engine.get('status', {}).get('rebuildStatus') or {}).values()
                    if s.get('isRebuilding') or s.get('state') == 'in_progress']
        if name in names and progress:
            result[name] = min(progress)
    return result


def health(records, storage=True):
    if kube('get', '--raw=/readyz') != 'ok':
        raise RuntimeError('Kubernetes API /readyz is not ok')
    nodes = json.loads(kube('get', 'nodes', '-o', 'json'))['items']
    by_name = {n['metadata']['name']: n for n in nodes}
    if any(not ready(n) for n in nodes) or any(r['node'] not in by_name for r in records):
        raise RuntimeError('A Kubernetes node is missing or not Ready')
    for selector, names in [
        ('k8s-app=cilium', [r['node'] for r in records]),
        ('name=kube-vip-ds', [r['node'] for r in records if r['role'] == 'control-plane']),
    ]:
        pods = json.loads(kube('-n', 'kube-system', 'get', 'pods', '-l', selector, '-o', 'json'))['items']
        for name in names:
            selected = [p for p in pods if p.get('spec', {}).get('nodeName') == name]
            if not selected or any(not ready(p) or p['metadata'].get('deletionTimestamp') or
                                   p['status'].get('phase') != 'Running' for p in selected):
                raise RuntimeError(f'{selector} is not healthy on {name}')
    if storage:
        volumes = json.loads(kube('-n', 'longhorn-system', 'get', 'volumes.longhorn.io', '-o', 'json'))['items']
        bad = [v for v in volumes if not longhorn_volume_ok(v)]
        if bad:
            progress = rebuild_progress({v['metadata']['name'] for v in bad})
            bad = [f"{v['metadata']['name']} ({v.get('status', {}).get('state')}/{v.get('status', {}).get('robustness')}"
                   f"{f', rebuilding {progress[n]}%' if (n := v['metadata']['name']) in progress else ''})"
                   for v in bad]
            raise RuntimeError(f'Longhorn volumes unhealthy, faulted, or transitioning: {", ".join(bad)}')
        for namespace in ('kube-system', 'longhorn-system'):
            controllers = json.loads(kube('-n', namespace, 'get', 'deployments,daemonsets,statefulsets', '-o', 'json'))['items']
            for obj in controllers:
                status, spec = obj.get('status', {}), obj.get('spec', {})
                desired = status.get('desiredNumberScheduled', 0) if obj['kind'] == 'DaemonSet' else spec.get('replicas', 1)
                available = status.get('numberReady', 0) if obj['kind'] == 'DaemonSet' else status.get('readyReplicas', 0)
                if available < desired or status.get('observedGeneration', 0) < obj['metadata'].get('generation', 1):
                    raise RuntimeError(f'{namespace}/{obj["metadata"]["name"]} has not recovered')


def elapsed(seconds):
    return f'{int(seconds) // 60}m{int(seconds) % 60:02d}s'


def wait_health(records, timeout, storage=True):
    # Checks every 10 seconds but prints only when the reason changes or once a
    # minute, with the clock time and how long this wait has taken.
    start = time.monotonic()
    deadline = start + timeout
    last_reason, last_print = None, None
    while True:
        try:
            health(records, storage)
            if last_reason is not None:
                print(f'{time.strftime("%H:%M:%S")} Recovered after {elapsed(time.monotonic() - start)}', flush=True)
            return
        except (RuntimeError, ValueError, KeyError) as exc:
            now = time.monotonic()
            if now >= deadline:
                raise RuntimeError(f'Health check timed out: {exc}') from exc
            reason = re.sub(r', rebuilding \d+%', '', str(exc))
            if reason != last_reason or now - last_print >= 60:
                print(f'{time.strftime("%H:%M:%S")} Waiting for recovery ({elapsed(now - start)}): {exc}', flush=True)
                last_reason, last_print = reason, now
            time.sleep(min(10, max(0, deadline - time.monotonic())))


def packages(snapshot):
    result = {}
    for line in snapshot['packages'].splitlines():
        name, version, status = line.split('\t')
        if status == 'installed':
            result[name] = version
    return result


def package_report(directory):
    before, after = directory / 'before.json', directory / 'after.json'
    if not before.exists() or not after.exists():
        return {'changes': None, 'note': 'Actual package changes unavailable; see plan/log.'}
    old, new = json.loads(before.read_text()), json.loads(after.read_text())
    a, b = packages(old), packages(new)
    changes = [{'package': name, 'before': a.get(name), 'after': b.get(name)}
               for name in sorted(a.keys() | b.keys()) if a.get(name) != b.get(name)]
    return dict(changes=changes, kernel_before=old['kernel'], kernel_after=new['kernel'],
                rebooted=new['rebooted'], held=new['held'],
                k3s_before=old.get('k3s'), k3s_after=new.get('k3s'))


def playbook(record, directory, args, apply=False):
    extra = dict(target=record['target'], os_report_dir=str(directory), os_apply=apply,
                 os_refresh_cache=(args.apply or args.refresh) and not apply)
    command = ['ansible-playbook', '-i', args.inventory, ROOT / 'maintenance/update-os.yml',
               '--limit', record['target'], '-e', json.dumps(extra)]
    if args.ask_become_pass:
        command.append('--ask-become-pass')
    run(command)


def planned_upgrades(plan):
    # apt-get --simulate lines: "Inst name [current] (new release [arch])"; new packages lack [current].
    return [dict(package=m[1], before=m[2], after=m[3])
            for m in re.finditer(r'^Inst (\S+) (?:\[(\S+)\] )?\((\S+)', plan, re.MULTILINE)]


def plan_section(plan, header):
    # Package names listed on indented lines under an apt-get header line.
    match = re.search(rf'^{re.escape(header)}\n((?:[ \t]+\S.*\n?)+)', plan, re.MULTILINE)
    return match.group(1).split() if match else []


def maintenance_assessment(directory):
    assessment = json.loads((directory / 'pending.json').read_text())
    # Require a recognized simulation summary rather than treating missing output as no work.
    counts = re.search(r'(\d+) upgraded, (\d+) newly installed, (\d+) to remove and (\d+) not upgraded',
                       assessment['plan'])
    if not counts or not isinstance(assessment.get('reboot_required'), bool):
        raise RuntimeError('Invalid package/reboot assessment; refusing to assume the node is up to date')
    package_work = any(int(n) for n in counts.groups()[:3]) or bool(
        re.search(r'^(Inst|Conf|Remv) ', assessment['plan'], re.MULTILINE))
    return dict(package_work=package_work, reboot_required=assessment['reboot_required'],
                kept_back=int(counts.group(4)), indexes_refreshed=assessment['indexes_refreshed'],
                upgrades=planned_upgrades(assessment['plan']),
                kept_back_packages=plan_section(assessment['plan'], 'The following packages have been kept back:'),
                # Ubuntu releases these gradually; a later run installs them once this node's turn comes.
                phased=plan_section(assessment['plan'], 'The following upgrades have been deferred due to phasing:'),
                reboot_packages=list(dict.fromkeys(assessment.get('reboot_packages') or [])))


def execute(records, directory, args):
    for index, record in enumerate(records):
        report_dir = directory / f'{index + 1:02d}'
        report_dir.mkdir()
        record['report_dir'] = str(report_dir)
        record['status'] = 'FAIL'
        cordoned = False
        try:
            print(f'\n{"-" * 60}\nNODE {index + 1}/{len(records)}: {record["target"]} ({record["role"]}): '
                  f'{"updating" if args.apply else "checking for updates"}\n{"-" * 60}', flush=True)
            health(records)
            playbook(record, report_dir, args)
            assessment = maintenance_assessment(report_dir)
            record['assessment'] = assessment
            if not assessment['package_work'] and not assessment['reboot_required']:
                record['status'] = 'UP-TO-DATE' if args.apply else 'PLAN'
                record['no_maintenance_needed'] = True
                print(f"{record['target']}: up to date, no reboot pending; nothing to do.", flush=True)
                continue
            if args.apply:
                # Verify backup freshness again before each node is changed.
                run([ROOT / 'backup/verify-backup.sh'])
                run([ROOT / 'backup/verify-velero.sh'])
                health(records)
                kube('cordon', record['node'])
                cordoned = True
                kube('drain', record['node'], '--ignore-daemonsets', '--delete-emptydir-data',
                     '--grace-period=60', '--timeout=10m')
                playbook(record, report_dir, args, apply=True)
                # Storage/workload replicas may require this node to be schedulable.
                wait_health(records, args.health_timeout, storage=False)
                kube('uncordon', record['node'])
                cordoned = False
                wait_health(records, args.health_timeout)
                record.update(package_report(report_dir))
                record['status'] = 'PASS'
            else:
                record['status'] = 'PLAN'
        except BaseException as exc:
            record['error'] = str(exc) or type(exc).__name__
            if args.apply:
                record.update(package_report(report_dir))
                # Re-cordon if full recovery failed after provisional uncordon.
                if not cordoned and record.get('report_dir') and (report_dir / 'after.json').exists():
                    try:
                        kube('cordon', record['node'])
                        cordoned = True
                    except RuntimeError as cordon_error:
                        record['cordon_error'] = str(cordon_error)
            record['left_cordoned'] = cordoned
            raise


def release_report(directory):
    path = directory / 'release-check.json'
    if not path.exists():
        return dict(status='UNKNOWN', detail='Release check was not completed.')
    check = json.loads(path.read_text())
    current = f"{check['distribution']} {check['version']}"
    output = '\n'.join(check.get(key, '') for key in ('stdout', 'stderr', 'message')).strip()
    result = dict(current=current, status='UNKNOWN', detail=output or 'No result from release checker.')
    if check['distribution'] != 'Ubuntu':
        result.update(status='UNSUPPORTED', detail='Automatic release checks currently support Ubuntu only.')
    elif check['rc'] == 124:
        result['detail'] = 'Release availability check timed out after 120 seconds.'
    elif check['rc'] == 0:
        match = re.search(r"New release ['\"]([^'\"]+)['\"] available", output)
        result.update(status='AVAILABLE', target=match.group(1) if match else None)
    elif any(word in output.lower() for word in ('failed', 'error', 'could not', 'unable to')):
        # Some checker versions print "No new release" even after a fetch error.
        pass
    elif 'Prompt' in output and 'never' in output:
        result.update(status='DISABLED', detail='Release notifications disabled by the node release-upgrade policy.')
    elif check['rc'] == 1 and 'No new release found' in output:
        result.update(status='NONE', detail='No new release offered by the configured upgrade policy.')
    elif check['rc'] == 1 and 'no development version of an LTS available' in output:
        # On an LTS with Prompt=lts this is the checker's normal "nothing newer" answer.
        result.update(status='NONE', detail='No newer LTS release available.')
    return result


def plural(count, word):
    return f'{count} {word}{"" if count == 1 else "s"}'


def wrapped(label, names):
    names = textwrap.fill(', '.join(names), 78, initial_indent='      ', subsequent_indent='      ',
                          break_on_hyphens=False, break_long_words=False)
    return f'    {label}:\n{names}'


def package_lines(changes):
    width = max(len(c['package']) for c in changes)
    return [f'    {c["package"]:<{width}}  {c["before"] or "(new)"} -> {c["after"] or "(removed)"}'
            for c in changes]


def table_row(r):
    assessment = r.get('assessment') or {}
    if r.get('changes') is not None:
        updates = str(len(r['changes'])) if r['changes'] else 'none'
        reboot = 'done' if r.get('rebooted') else 'no'
    elif assessment:
        updates = str(len(assessment['upgrades'])) if assessment.get('upgrades') else 'none'
        reboot = 'pending' if assessment.get('reboot_required') else 'no'
    else:
        updates = reboot = '-'
    status = {'SKIP': 'not checked', 'FAIL': 'FAILED', 'PASS': 'updated'}.get(r['status'], 'maintenance needed')
    if r.get('no_maintenance_needed'):
        status = 'up to date'
    return r['target'], r['role'], updates, reboot, status


def package_details(r):
    lines = []
    assessment = r.get('assessment') or {}
    if r.get('changes'):
        lines.extend(package_lines(r['changes']))
    elif r['status'] in ('PLAN', 'FAIL') and assessment.get('upgrades'):
        lines.extend(package_lines(assessment['upgrades']))
    # A reboot can change the running kernel even when this run installed no packages.
    if r.get('kernel_before') != r.get('kernel_after'):
        lines.append(f'    Running kernel: {r["kernel_before"]} -> {r["kernel_after"]}')
    if r.get('k3s_after') and r.get('k3s_before') != r.get('k3s_after'):
        lines.append(f'    K3s: {r["k3s_before"]} -> {r["k3s_after"]}')
    if r.get('rebooted') and assessment.get('reboot_packages'):
        lines.append(wrapped('Rebooted for', assessment['reboot_packages']))
    if assessment.get('phased'):
        lines.append(wrapped("Waiting on Ubuntu's phased rollout (a later run installs them)", assessment['phased']))
    if assessment.get('kept_back_packages'):
        lines.append(wrapped('Kept back by apt (needs a manual decision)', assessment['kept_back_packages']))
    if r.get('held'):
        lines.append(wrapped('Held', r['held']))
    return lines


def node_names(targets, records):
    if len(targets) == len(records) and len(records) > 1:
        return f'all {len(records)} nodes'
    return ', '.join(targets)


def release_text(release):
    current = release.get('current', 'unknown distro')
    status = release['status']
    if status == 'AVAILABLE':
        return f'{current}, new release {release.get("target") or "(unknown version)"} available (this script does not install it)'
    if status == 'NONE':
        return f'{current}, {release["detail"][0].lower()}{release["detail"][1:].rstrip(".")}'
    if status == 'DISABLED':
        return f'{current}, release upgrade notifications disabled'
    if status == 'UNSUPPORTED':
        return f'{current}, release check not supported'
    return f'{current}, release check failed: {" ".join(release["detail"].split())}'


def summary(records, directory, result=None, apply=False):
    for record in records:
        if record.get('report_dir'):
            record['distro_upgrade'] = release_report(Path(record['report_dir']))
    (directory / 'summary.json').write_text(json.dumps(records, indent=2) + '\n')
    checked = [r for r in records if r.get('assessment')]
    refreshed = bool(checked) and all(r['assessment']['indexes_refreshed'] for r in checked)
    title = 'OS UPDATE RESULTS' if apply else 'OS UPDATE PREVIEW'
    if checked:
        title += ' (package lists refreshed)' if refreshed else " (using the nodes' cached package lists)"
    lines = ['', '=' * 60, title, '=' * 60, '']

    rows = [('NODE', 'ROLE', 'UPDATES', 'REBOOT', 'STATUS')] + [table_row(r) for r in records]
    widths = [max(len(row[i]) for row in rows) for i in range(4)]
    lines.extend('  ' + '  '.join(f'{cell:<{width}}' for cell, width in zip(row, widths)) + '  ' + row[4]
                 for row in rows)

    details = [(r, package_details(r)) for r in records]
    details = [(r, d) for r, d in details if d]
    lines.append('')
    lines.append('Changes made:' if apply else 'Updates available:')
    if not details:
        lines.append('  none')
    for r, detail in details:
        lines.append(f'  {r["target"]}')
        lines.extend(detail)

    pending = [r for r in records if r['status'] == 'PLAN' and (r.get('assessment') or {}).get('reboot_required')]
    if pending:
        lines.append('')
        lines.append('Reboots pending (updates already installed on the node, e.g. by unattended-upgrades):')
        reasons = {}
        for r in pending:
            reasons.setdefault(tuple(r['assessment'].get('reboot_packages') or []), []).append(r['target'])
        for packages_, targets in reasons.items():
            lines.append(f'  {node_names(targets, records)}')
            lines.append(wrapped('Requested by', packages_) if packages_ else '    Requested by: (not recorded)')

    errors = [r for r in records if r.get('error')]
    if errors:
        lines.append('')
        lines.append('Errors:')
        for r in errors:
            lines.append(f'  {r["target"]}: {r["error"]}')
            if r.get('left_cordoned'):
                lines.append(f'    LEFT CORDONED: fix the node and check the cluster, then kubectl uncordon {r["node"]}')

    releases = {}
    for r in records:
        if r.get('distro_upgrade'):
            releases.setdefault(release_text(r['distro_upgrade']), []).append(r['target'])
    if releases:
        lines.append('')
        lines.append('Ubuntu release upgrade:')
        for text, targets in releases.items():
            lines.append(f'  {node_names(targets, records)}: {text}')

    lines.append('')
    planned = [r for r in records if r['status'] == 'PLAN' and r.get('assessment') and not r.get('no_maintenance_needed')]
    if planned:
        to_update = [r for r in planned if r['assessment'].get('upgrades')]
        to_reboot = [r for r in planned if r['assessment'].get('reboot_required')]
        steps = []
        if to_update:
            total = sum(len(r['assessment']['upgrades']) for r in to_update)
            steps.append(f'install {plural(total, "update")} on {node_names([r["target"] for r in to_update], records)}')
        if to_reboot:
            steps.append(f'reboot {node_names([r["target"] for r in to_reboot], records)}')
        lines.append(f'Next: ./update-os.sh --apply will {" and ".join(steps)},')
        lines.append('      one node at a time, draining each node first.')
    elif checked and all(r.get('no_maintenance_needed') for r in records):
        lines.append('Nothing to do: every node is up to date with no reboot pending.')
    if checked and not refreshed and not apply:
        lines.append('Package lists were not refreshed; run ./update-os.sh --refresh for a current check.')
    lines.append(f'Reports: {directory}')
    if result:
        lines.append(result)
    output = '\n'.join(lines) + '\n'
    (directory / 'summary.txt').write_text(output)
    print(output, flush=True)


def main():
    parser = argparse.ArgumentParser(description='Workers-first rolling Debian/Ubuntu OS package updates. Default: read-only remote plan using existing APT indexes.')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--refresh', action='store_true',
                        help='Preview only: run apt-get update on each node first so the preview is current (installs nothing)')
    parser.add_argument('--yes', action='store_true', help='Explicit unattended apply')
    parser.add_argument('--ask-become-pass', action='store_true', help='Prompt for sudo password for each Ansible invocation')
    parser.add_argument('--inventory', default=str(ROOT / 'inventory/k3s-ansible/hosts.ini'))
    parser.add_argument('--health-timeout', type=int, default=3600, help='Seconds to wait for each recovery phase (default: 3600)')
    args = parser.parse_args()
    if args.yes and not args.apply:
        parser.error('--yes requires --apply')
    if args.refresh and args.apply:
        parser.error('--refresh is for previews; --apply already refreshes package lists')
    if args.health_timeout <= 0:
        parser.error('--health-timeout must be positive')
    os.chdir(ROOT)
    os.umask(0o077)
    directory = ROOT / 'logs/os-updates' / datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    directory.mkdir(parents=True)
    # tee captures subprocess output as well as Python messages, preserving stdin prompts.
    with (directory / 'run.log').open('w') as log:
        tee = subprocess.Popen(['tee', str(directory / 'run.log')], stdin=subprocess.PIPE)
        saved = os.dup(1), os.dup(2)
        os.dup2(tee.stdin.fileno(), 1)
        os.dup2(tee.stdin.fileno(), 2)
        records = []
        result = None
        try:
            if args.apply:
                mode = 'APPLY: installing updates'
            elif args.refresh:
                mode = 'PREVIEW: refreshing package lists, then checking for updates (installs nothing)'
            else:
                mode = 'PREVIEW: checking for updates, changing nothing'
            print(f'OS update {mode}\nLog: {log.name}', flush=True)
            run([ROOT / 'scripts/check-ansible-toolchain.sh'])
            inventory = json.loads(run(['ansible-inventory', '-i', args.inventory, '--list'], capture=True))
            nodes = json.loads(kube('get', 'nodes', '-o', 'json'))['items']
            records = discover(inventory, nodes)
            for r in records:
                print(f'  {r["role"]}: {r["target"]} ({r["node"]})', flush=True)
            if args.apply and not args.yes:
                print('Drain deletes emptyDir data. Reboots occur when /var/run/reboot-required exists.', flush=True)
                if input('Type UPDATE OS to continue: ') != 'UPDATE OS':
                    raise RuntimeError('Confirmation did not match; no nodes changed')
            execute(records, directory, args)
            result = f'RESULT: {"PASS" if args.apply else "PREVIEW COMPLETE"}'
            return 0
        except (Exception, KeyboardInterrupt) as exc:
            result = f'RESULT: FAIL: {exc}'
            return 1
        finally:
            summary(records, directory, result, args.apply)
            sys.stdout.flush()
            sys.stderr.flush()
            os.dup2(saved[0], 1)
            os.dup2(saved[1], 2)
            os.close(saved[0])
            os.close(saved[1])
            tee.stdin.close()
            tee.wait()


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit('Terminated'))
    sys.exit(main())
