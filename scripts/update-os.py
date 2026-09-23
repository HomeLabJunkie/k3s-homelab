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
import time
from datetime import datetime

ROOT = Path(__file__).resolve().parent.parent


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
        bad = [f"{v['metadata']['name']} ({v.get('status', {}).get('state')}/{v.get('status', {}).get('robustness')})"
               for v in volumes if not longhorn_volume_ok(v)]
        if bad:
            raise RuntimeError(f'Longhorn volumes unhealthy, faulted, or transitioning: {", ".join(bad)}')
        for namespace in ('kube-system', 'longhorn-system'):
            controllers = json.loads(kube('-n', namespace, 'get', 'deployments,daemonsets,statefulsets', '-o', 'json'))['items']
            for obj in controllers:
                status, spec = obj.get('status', {}), obj.get('spec', {})
                desired = status.get('desiredNumberScheduled', 0) if obj['kind'] == 'DaemonSet' else spec.get('replicas', 1)
                available = status.get('numberReady', 0) if obj['kind'] == 'DaemonSet' else status.get('readyReplicas', 0)
                if available < desired or status.get('observedGeneration', 0) < obj['metadata'].get('generation', 1):
                    raise RuntimeError(f'{namespace}/{obj["metadata"]["name"]} has not recovered')


def wait_health(records, timeout, storage=True):
    deadline = time.monotonic() + timeout
    while True:
        try:
            health(records, storage)
            return
        except (RuntimeError, ValueError, KeyError) as exc:
            if time.monotonic() >= deadline:
                raise RuntimeError(f'Health check timed out: {exc}') from exc
            print(f'Waiting for recovery: {exc}', flush=True)
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
                 os_refresh_cache=args.apply and not apply)
    command = ['ansible-playbook', '-i', args.inventory, ROOT / 'maintenance/update-os.yml',
               '--limit', record['target'], '-e', json.dumps(extra)]
    if args.ask_become_pass:
        command.append('--ask-become-pass')
    run(command)


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
                kept_back=int(counts.group(4)), indexes_refreshed=assessment['indexes_refreshed'])


def execute(records, directory, args):
    for index, record in enumerate(records):
        report_dir = directory / f'{index + 1:02d}'
        report_dir.mkdir()
        record['report_dir'] = str(report_dir)
        record['status'] = 'FAIL'
        cordoned = False
        try:
            print(f'\nSTART: {record["target"]} ({record["role"]})', flush=True)
            health(records)
            playbook(record, report_dir, args)
            assessment = maintenance_assessment(report_dir)
            record['assessment'] = assessment
            if not assessment['package_work'] and not assessment['reboot_required']:
                record['status'] = 'UP-TO-DATE' if args.apply else 'PLAN'
                record['no_maintenance_needed'] = True
                print(f"{record['target']}: no actionable package updates or pending reboot; skipping maintenance.", flush=True)
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
    return result


def summary(records, directory):
    for record in records:
        if record.get('report_dir'):
            record['distro_upgrade'] = release_report(Path(record['report_dir']))
    (directory / 'summary.json').write_text(json.dumps(records, indent=2) + '\n')
    lines = ['ROLLING OS UPDATE SUMMARY']
    for r in records:
        lines.append(f'{r["status"]}: {r["target"]} ({r["role"]}, {r["node"]})')
        release = r.get('distro_upgrade')
        if release:
            current = release.get('current', 'unknown distro')
            target = f" -> {release['target']}" if release.get('target') else ''
            lines.append(f"  Distro upgrade: {release['status']} ({current}{target})")
            lines.append(f"    {' '.join(release['detail'].split())}")
        if r.get('error'):
            lines.append(f'  Error: {r["error"]}')
        if r.get('left_cordoned'):
            lines.append('  LEFT CORDONED: repair and verify health before manually uncordoning.')
        if r.get('changes') is not None:
            lines.append(f'  {len(r["changes"])} package changes; rebooted={r["rebooted"]}; '
                         f'kernel {r["kernel_before"]} -> {r["kernel_after"]}')
            if r.get('k3s_after'):
                lines.append(f'  K3s: {r["k3s_before"]!r} -> {r["k3s_after"]!r}')
            for change in r['changes']:
                lines.append(f'    {change["package"]}: {change["before"] or "(absent)"} -> {change["after"] or "(removed)"}')
            lines.append(f'  Held packages: {", ".join(r["held"]) or "none"}')
        elif r.get('no_maintenance_needed'):
            qualifier = 'refreshed' if r['assessment']['indexes_refreshed'] else 'cached'
            lines.append(f'  No actionable package updates ({qualifier} indexes); no pending reboot. Maintenance skipped.')
            if r['assessment']['kept_back']:
                lines.append(f"  Packages kept back: {r['assessment']['kept_back']}")
        elif r['status'] != 'SKIP':
            lines.append('  Actual changes not recorded; see node plan and run log.')
    lines.append(f'Reports: {directory}')
    output = '\n'.join(lines) + '\n'
    (directory / 'summary.txt').write_text(output)
    print(output, flush=True)


def main():
    parser = argparse.ArgumentParser(description='Workers-first rolling Debian/Ubuntu OS package updates. Default: read-only remote plan using existing APT indexes.')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--yes', action='store_true', help='Explicit unattended apply')
    parser.add_argument('--ask-become-pass', action='store_true', help='Prompt for sudo password for each Ansible invocation')
    parser.add_argument('--inventory', default=str(ROOT / 'inventory/k3s-ansible/hosts.ini'))
    parser.add_argument('--health-timeout', type=int, default=3600, help='Seconds to wait for each recovery phase (default: 3600)')
    args = parser.parse_args()
    if args.yes and not args.apply:
        parser.error('--yes requires --apply')
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
        try:
            print(f'OS update {"APPLY" if args.apply else "PLAN"}; log: {log.name}', flush=True)
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
            if records and all(r.get('no_maintenance_needed') for r in records):
                print('No nodes require package updates or a reboot; no nodes were cordoned.', flush=True)
            print(f'ROLLING OS UPDATE: {"PASS" if args.apply else "PLAN COMPLETE"}', flush=True)
            return 0
        except (Exception, KeyboardInterrupt) as exc:
            print(f'ROLLING OS UPDATE: FAIL: {exc}', flush=True)
            return 1
        finally:
            summary(records, directory)
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
