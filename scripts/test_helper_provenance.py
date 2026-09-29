#!/usr/bin/env python3
"""Isolated provenance/checker tests; never build or launch the application."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import sys
import unittest

sys.dont_write_bytecode = True

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('fingerprint', ROOT / 'scripts/helper_source_fingerprint.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class HelperProvenanceTests(unittest.TestCase):
    def test_checkout_independence_and_stale_rejection(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = Path(temporary) / 'first'
            second = Path(temporary) / 'elsewhere'
            first.mkdir()
            for name in ('KeyStatsHelper', 'KeyStats.xcodeproj', 'scripts'):
                shutil.copytree(ROOT / name, first / name, ignore=shutil.ignore_patterns('__pycache__', 'xcuserdata'))
            shutil.copytree(first, second)
            expected = module.fingerprint(first)
            self.assertEqual(expected, module.fingerprint(second))
            vendor = first / 'vendor'
            (vendor / 'KeyStatsHelper.app').mkdir(parents=True)
            (vendor / 'KeyStatsHelper.cdhash.txt').write_text('fixture-hash\n')
            provenance = vendor / 'KeyStatsHelper.source.sha256'
            provenance.write_text(expected + '\n')
            # Only signature verification is stubbed; exercise the real checker and fingerprint.
            bin_dir = Path(temporary) / 'bin'
            bin_dir.mkdir()
            codesign = bin_dir / 'codesign'
            codesign.write_text('#!/bin/sh\n[ "$1" = "--verify" ] && exit 0\necho CDHash=fixture-hash >&2\n')
            codesign.chmod(0o755)
            environment = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'])

            def check():
                return subprocess.run(['bash', str(first / 'scripts/check_vendored_helper.sh')],
                                      env=environment, capture_output=True, text=True)

            self.assertEqual(check().returncode, 0)
            provenance.unlink()
            self.assertIn('Missing Helper source provenance', check().stdout)
            provenance.write_text(expected + '\n')
            source = next((first / 'KeyStatsHelper').glob('*.swift'))
            original = source.read_bytes()
            source.write_bytes(original + b'\n// changed fixture\n')
            self.assertNotEqual(check().returncode, 0)
            self.assertIn('stale', check().stdout)
            source.write_bytes(original)
            self.assertEqual(check().returncode, 0)
            asset = first / 'KeyStatsHelper' / 'fixture-resource.txt'
            asset.write_text('new resource')
            self.assertNotEqual(module.fingerprint(first), expected)
            asset.unlink()
            project = first / 'KeyStats.xcodeproj/project.pbxproj'
            content = project.read_text()
            project.write_text(content.replace('PRODUCT_NAME = KeyStatsHelper;', 'PRODUCT_NAME = ChangedHelper;'))
            self.assertNotEqual(module.fingerprint(first), expected)
            project.write_text(content.replace('PRODUCT_BUNDLE_IDENTIFIER = com.keystats.app;', 'PRODUCT_BUNDLE_IDENTIFIER = com.fixture.main;'))
            self.assertEqual(module.fingerprint(first), expected)
            project.write_text(content)
            data = json.loads(subprocess.check_output([
                '/usr/bin/plutil', '-convert', 'json', '-o', '-', str(project)]))
            objects = data['objects']
            helper_id = next(key for key, value in objects.items()
                             if value.get('isa') == 'PBXNativeTarget' and value.get('name') == 'helper')
            group = next(value for value in objects.values()
                         if value.get('isa') == 'PBXFileSystemSynchronizedRootGroup')
            exception_id = group['exceptions'][0]
            exception = objects[exception_id]
            exception['membershipExceptions'].append('MainOnly.swift')
            project.write_text(json.dumps(data))
            self.assertEqual(module.fingerprint(first), expected)
            # Even changing the main-only exception reference must remain irrelevant.
            objects['MAIN_ONLY_NEW_ID'] = objects.pop(exception_id)
            group['exceptions'] = ['MAIN_ONLY_NEW_ID']
            project.write_text(json.dumps(data))
            self.assertEqual(module.fingerprint(first), expected)
            exception['target'] = helper_id
            project.write_text(json.dumps(data))
            helper_baseline = module.fingerprint(first)
            self.assertNotEqual(helper_baseline, expected)
            exception['membershipExceptions'].append('HelperOnly.swift')
            project.write_text(json.dumps(data))
            self.assertNotEqual(module.fingerprint(first), helper_baseline)


if __name__ == '__main__':
    unittest.main()
