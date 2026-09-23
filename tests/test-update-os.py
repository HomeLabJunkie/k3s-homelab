#!/usr/bin/env python3
"""Offline tests: never contact the cluster or invoke Ansible."""
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import sys
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location('update_os', Path(__file__).resolve().parents[1] / 'scripts/update-os.py')
os_update = importlib.util.module_from_spec(spec)
spec.loader.exec_module(os_update)


def node(name, control=False):
    return {'metadata': {'name': name, 'labels': {'node-role.kubernetes.io/control-plane': 'true'} if control else {}},
            'spec': {}, 'status': {'conditions': [{'type': 'Ready', 'status': 'True'}]}}


def records():
    return [dict(target=n, node=n, role=r, status='SKIP') for n, r in
            [('worker1', 'worker'), ('worker2', 'worker'), ('master1', 'control-plane')]]


class UpdateTests(unittest.TestCase):
    def test_inventory_children_workers_first(self):
        inv = {'node': {'children': ['workers']}, 'workers': {'hosts': ['worker1']},
               'master': {'hosts': ['master1']}}
        result = os_update.discover(inv, [node('master1', True), node('worker1')])
        self.assertEqual([r['target'] for r in result], ['worker1', 'master1'])

    def test_ambiguous_inventory_refused(self):
        with self.assertRaises(RuntimeError):
            os_update.discover({'node': {'hosts': ['a']}, 'master': {'hosts': ['a']}}, [])

    def test_cordoned_node_refused(self):
        worker = node('worker1')
        worker['spec']['unschedulable'] = True
        with self.assertRaisesRegex(RuntimeError, 'already cordoned'):
            os_update.discover({'node': {'hosts': ['worker1']}, 'master': {'hosts': ['master1']}},
                               [worker, node('master1', True)])

    def test_role_mismatch_refused(self):
        with self.assertRaisesRegex(RuntimeError, 'roles disagree'):
            os_update.discover({'node': {'hosts': ['worker1']}, 'master': {'hosts': ['master1']}},
                               [node('worker1', True), node('master1', True)])

    def execute(self, apply=True, failure=None, no_work=(), reboot=()):
        self.events = []
        recs = records()
        def play(record, directory, args, apply=False):
            self.events.append(('apply' if apply else 'plan', record['target']))
            if not apply:
                count = 0 if record['target'] in no_work else 1
                (directory / 'pending.json').write_text(json.dumps(dict(
                    plan=f'{count} upgraded, 0 newly installed, 0 to remove and 0 not upgraded.',
                    reboot_required=record['target'] in reboot, indexes_refreshed=args.apply)))
            if apply:
                (directory / 'before.json').write_text(json.dumps(dict(packages='pkg\t1\tinstalled\n', kernel='old')))
                (directory / 'after.json').write_text(json.dumps(dict(packages='pkg\t2\tinstalled\n', kernel='new', held=[], rebooted=True)))
                if failure == 'update':
                    raise RuntimeError('update failed')
        def kube(*args):
            self.events.append(args)
            if args[0] == failure:
                raise RuntimeError(f'{failure} failed')
        def wait(recs, timeout, storage=True):
            self.events.append(('health', storage))
            if failure == ('storage' if storage else 'core'):
                raise RuntimeError('unhealthy')
        with tempfile.TemporaryDirectory() as tmp, patch.object(os_update, 'health'), \
             patch.object(os_update, 'run') as run, patch.object(os_update, 'playbook', side_effect=play), \
             patch.object(os_update, 'kube', side_effect=kube), patch.object(os_update, 'wait_health', side_effect=wait):
            args = SimpleNamespace(apply=apply, health_timeout=1)
            if failure:
                with self.assertRaises(RuntimeError):
                    os_update.execute(recs, Path(tmp), args)
            else:
                os_update.execute(recs, Path(tmp), args)
            if not apply or all(r['target'] in no_work and r['target'] not in reboot for r in recs):
                run.assert_not_called()
            os_update.summary(recs, Path(tmp))
            self.assertTrue((Path(tmp) / 'summary.json').exists())
        return recs

    def test_plan_has_no_mutations(self):
        recs = self.execute(apply=False)
        self.assertEqual(self.events, [('plan', r['target']) for r in recs])
        self.assertEqual([r['status'] for r in recs], ['PLAN'] * 3)

    def test_all_up_to_date_skips_all_maintenance(self):
        recs = self.execute(no_work=('worker1', 'worker2', 'master1'))
        self.assertEqual([r['status'] for r in recs], ['UP-TO-DATE'] * 3)
        self.assertEqual(self.events, [('plan', r['target']) for r in recs])

    def test_mixed_nodes_only_update_when_needed(self):
        recs = self.execute(no_work=('worker1', 'master1'))
        self.assertEqual([r['status'] for r in recs], ['UP-TO-DATE', 'PASS', 'UP-TO-DATE'])
        self.assertEqual([e for e in self.events if e[0] == 'cordon'], [('cordon', 'worker2')])

    def test_pending_reboot_still_requires_maintenance(self):
        recs = self.execute(no_work=('worker1', 'worker2', 'master1'), reboot=('worker1',))
        self.assertEqual([r['status'] for r in recs], ['PASS', 'UP-TO-DATE', 'UP-TO-DATE'])
        self.assertIn(('cordon', 'worker1'), self.events)

    def test_invalid_assessment_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'pending.json').write_text(json.dumps(dict(plan='apt error', reboot_required=False)))
            with self.assertRaisesRegex(RuntimeError, 'Invalid'):
                os_update.maintenance_assessment(directory)

    def test_serial_success_and_package_summary(self):
        recs = self.execute()
        self.assertEqual([r['status'] for r in recs], ['PASS'] * 3)
        self.assertEqual([e for e in self.events if e[0] == 'apply'],
                         [('apply', r['target']) for r in recs])
        self.assertLess(self.events.index(('health', True)), self.events.index(('plan', 'worker2')))
        self.assertLess(self.events.index(('health', False)), self.events.index(('uncordon', 'worker1')))
        self.assertEqual(recs[0]['changes'], [{'package': 'pkg', 'before': '1', 'after': '2'}])

    def test_drain_failure_stops_before_update(self):
        recs = self.execute(failure='drain')
        self.assertFalse(any(e[0] == 'apply' for e in self.events))
        self.assertEqual([r['status'] for r in recs], ['FAIL', 'SKIP', 'SKIP'])
        self.assertTrue(recs[0]['left_cordoned'])

    def test_update_failure_keeps_partial_summary(self):
        recs = self.execute(failure='update')
        self.assertTrue(recs[0]['left_cordoned'])
        self.assertEqual(len(recs[0]['changes']), 1)
        self.assertNotIn(('uncordon', 'worker1'), self.events)

    def test_core_failure_leaves_cordoned(self):
        recs = self.execute(failure='core')
        self.assertTrue(recs[0]['left_cordoned'])
        self.assertNotIn(('uncordon', 'worker1'), self.events)

    def test_storage_failure_re_cordons_and_stops(self):
        recs = self.execute(failure='storage')
        self.assertTrue(recs[0]['left_cordoned'])
        self.assertEqual(self.events[-1], ('cordon', 'worker1'))
        self.assertEqual([r['status'] for r in recs], ['FAIL', 'SKIP', 'SKIP'])

    def test_unready_node_blocks_health(self):
        unhealthy = node('worker1')
        unhealthy['status']['conditions'] = []
        with patch.object(os_update, 'kube', side_effect=['ok', json.dumps({'items': [unhealthy]})]):
            with self.assertRaisesRegex(RuntimeError, 'not Ready'):
                os_update.health(records())

    def test_missing_cilium_blocks_health(self):
        nodes = [node('worker1'), node('worker2'), node('master1', True)]
        with patch.object(os_update, 'kube', side_effect=['ok', json.dumps({'items': nodes}), '{"items": []}']):
            with self.assertRaisesRegex(RuntimeError, 'cilium'):
                os_update.health(records())

    def test_backup_failure_prevents_cordon(self):
        recs = records()
        with tempfile.TemporaryDirectory() as tmp, patch.object(os_update, 'health'), \
             patch.object(os_update, 'playbook'), patch.object(os_update, 'kube') as kube, \
             patch.object(os_update, 'run', side_effect=RuntimeError('stale backup')), \
             patch.object(os_update, 'maintenance_assessment', return_value=dict(package_work=True, reboot_required=False)):
            with self.assertRaisesRegex(RuntimeError, 'stale backup'):
                os_update.execute(recs, Path(tmp), SimpleNamespace(apply=True, health_timeout=1))
            kube.assert_not_called()
        self.assertEqual([r['status'] for r in recs], ['FAIL', 'SKIP', 'SKIP'])

    def test_health_retries_and_timeout(self):
        with patch.object(os_update, 'health', side_effect=[RuntimeError('recovering'), None]), \
             patch.object(os_update.time, 'sleep'):
            os_update.wait_health(records(), 10)
        with patch.object(os_update, 'health', side_effect=RuntimeError('still unhealthy')):
            with self.assertRaisesRegex(RuntimeError, 'timed out'):
                os_update.wait_health(records(), 0)

    def storage_health(self, *volume_states):
        nodes = [node('worker1'), node('worker2'), node('master1', True)]
        pods = [dict(node(n), spec={'nodeName': n}) for n in ('worker1', 'worker2', 'master1')]
        for pod in pods:
            pod['status']['phase'] = 'Running'
        volumes = [{'metadata': {'name': f'vol{i}'}, 'status': {'state': s, 'robustness': r}}
                   for i, (s, r) in enumerate(volume_states)]
        empty = json.dumps({'items': []})
        responses = ['ok', json.dumps({'items': nodes}), json.dumps({'items': pods}),
                     json.dumps({'items': [pods[-1]]}), json.dumps({'items': volumes}), empty, empty]
        with patch.object(os_update, 'kube', side_effect=responses):
            os_update.health(records())

    def test_degraded_longhorn_blocks_progress(self):
        with self.assertRaisesRegex(RuntimeError, 'Longhorn'):
            self.storage_health(('attached', 'degraded'))

    def test_detached_longhorn_volume_does_not_block(self):
        self.storage_health(('attached', 'healthy'), ('detached', 'unknown'))

    def test_faulted_detached_longhorn_blocks_progress(self):
        with self.assertRaisesRegex(RuntimeError, r'vol1 \(detached/faulted\)'):
            self.storage_health(('attached', 'healthy'), ('detached', 'faulted'))

    def test_transitioning_longhorn_blocks_progress(self):
        with self.assertRaisesRegex(RuntimeError, r'vol0 \(attaching/unknown\)'):
            self.storage_health(('attaching', 'unknown'))

    def release_check(self, rc, stdout='', stderr='', distribution='Ubuntu'):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'release-check.json').write_text(json.dumps(dict(
                distribution=distribution, version='26.04', rc=rc, stdout=stdout, stderr=stderr)))
            return os_update.release_report(directory)

    def test_release_available(self):
        result = self.release_check(0, "New release '26.10' available.")
        self.assertEqual(result['status'], 'AVAILABLE')
        self.assertEqual(result['target'], '26.10')

    def test_release_none(self):
        self.assertEqual(self.release_check(1, 'No new release found.')['status'], 'NONE')

    def test_release_network_error_is_not_none(self):
        result = self.release_check(1, 'No new release found.', 'Failed to connect to release server')
        self.assertEqual(result['status'], 'UNKNOWN')

    def test_release_timeout_and_missing_tool(self):
        self.assertEqual(self.release_check(124)['status'], 'UNKNOWN')
        self.assertEqual(self.release_check(127, stderr='No such file or directory')['status'], 'UNKNOWN')

    def test_release_disabled_and_unsupported(self):
        self.assertEqual(self.release_check(1, "Prompt set to never")['status'], 'DISABLED')
        self.assertEqual(self.release_check(-1, distribution='Debian')['status'], 'UNSUPPORTED')

    def test_release_in_plan_and_apply_summaries(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'release-check.json').write_text(json.dumps(dict(
                distribution='Ubuntu', version='26.04', rc=0, stdout="New release '26.10' available.")))
            for status in ('PLAN', 'PASS', 'FAIL'):
                recs = [dict(records()[0], status=status, report_dir=tmp)]
                os_update.summary(recs, directory)
                self.assertIn('Distro upgrade: AVAILABLE (Ubuntu 26.04 -> 26.10)',
                              (directory / 'summary.txt').read_text())
                saved = json.loads((directory / 'summary.json').read_text())
                self.assertEqual(saved[0]['distro_upgrade']['target'], '26.10')

    def test_package_add_remove_upgrade(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            (directory / 'before.json').write_text(json.dumps(dict(packages='a\t1\tinstalled\nb\t1\tinstalled\n', kernel='1')))
            (directory / 'after.json').write_text(json.dumps(dict(packages='a\t2\tinstalled\nc\t1\tinstalled\nb\t1\tconfig-files\n', kernel='2', held=['held'], rebooted=True)))
            report = os_update.package_report(directory)
            self.assertEqual(report['changes'], [dict(package='a', before='1', after='2'),
                             dict(package='b', before='1', after=None), dict(package='c', before=None, after='1')])
            self.assertTrue(report['rebooted'])


if __name__ == '__main__':
    unittest.main()
