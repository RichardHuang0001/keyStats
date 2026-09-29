#!/usr/bin/env python3
"""Hash Helper inputs without building; paths are relative to the checkout.

Includes synchronized source trees, explicit build-phase files, Helper target
configuration and inherited Release settings. Main-app-only settings are excluded.
This is a stale-source guard, not a claim of reproducible compiler output.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import sys


def fingerprint(root):
    root = Path(root).resolve()
    project = json.loads(subprocess.check_output([
        '/usr/bin/plutil', '-convert', 'json', '-o', '-',
        str(root / 'KeyStats.xcodeproj/project.pbxproj')]))
    objects = project['objects']
    targets = [(key, obj) for key, obj in objects.items()
               if obj.get('isa') == 'PBXNativeTarget' and obj.get('name') == 'helper']
    if len(targets) != 1:
        raise ValueError('Expected exactly one helper target')
    target_id, target = targets[0]
    if target.get('dependencies') or target.get('packageProductDependencies'):
        raise ValueError('Helper dependencies changed; extend provenance coverage before rebuilding')
    parents = {child: key for key, obj in objects.items()
               if obj.get('isa') in ('PBXGroup', 'PBXVariantGroup')
               for child in obj.get('children', [])}

    def file_path(key):
        obj = objects[key]
        tree = obj.get('sourceTree', '<group>')
        if tree == 'BUILT_PRODUCTS_DIR':
            return None
        if tree not in ('<group>', 'SOURCE_ROOT'):
            raise ValueError('Unsupported sourceTree: ' + tree)
        parent = file_path(parents[key]) if tree == '<group>' and key in parents else root
        return parent / obj.get('path', '')

    selected = {}
    files = {}

    def add_path(path):
        path = path.resolve()
        path.relative_to(root)  # No machine-specific external inputs.
        if not path.exists():
            raise ValueError('Missing Helper input: ' + str(path))
        paths = path.rglob('*') if path.is_dir() else [path]
        for item in paths:
            if item.is_file() and item.name != '.DS_Store':
                files[item.relative_to(root).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()

    def visit(key):
        if key in selected:
            return
        obj = objects[key]
        if (obj.get('isa', '').startswith('PBXFileSystemSynchronized')
                and obj.get('target') not in (None, target_id)):
            return
        if obj.get('isa') == 'PBXFileSystemSynchronizedRootGroup':
            # Shared folders may have exceptions belonging exclusively to the main
            # app. Exclude both those objects and their references from the digest.
            obj = dict(obj)
            obj['exceptions'] = [reference for reference in obj.get('exceptions', [])
                                 if objects[reference].get('target') in (None, target_id)]
        selected[key] = obj
        if obj.get('isa') == 'PBXShellScriptBuildPhase':
            raise ValueError('Helper shell phase added; extend provenance coverage before rebuilding')
        if obj.get('isa') in ('PBXFileReference', 'PBXFileSystemSynchronizedRootGroup'):
            path = file_path(key)
            if path is not None:
                add_path(path)
        if obj.get('baseConfigurationReference'):
            raise ValueError('Helper xcconfig added; include its transitive inputs before rebuilding')
        # Exception-set target is a membership selector, not a build dependency.
        for field, value in obj.items():
            if field == 'target' and obj.get('isa', '').startswith('PBXFileSystemSynchronized'):
                continue
            values = value if isinstance(value, list) else [value]
            for entry in values:
                if isinstance(entry, str) and entry in objects:
                    visit(entry)
        for setting in ('INFOPLIST_FILE', 'CODE_SIGN_ENTITLEMENTS', 'SWIFT_OBJC_BRIDGING_HEADER'):
            path = obj.get('buildSettings', {}).get(setting)
            if path:
                path = path.replace('$(SRCROOT)/', '').replace('$(PROJECT_DIR)/', '')
                if '$' in path:
                    raise ValueError('Unresolved Helper input: ' + path)
                add_path(root / path)

    visit(target_id)
    project_obj = objects[project['rootObject']]
    configs = objects[project_obj['buildConfigurationList']]['buildConfigurations']
    for key in configs:
        if objects[key]['name'] == 'Release':
            visit(key)
    # Include the recipe: arch/signing switches affect the shipped helper too.
    for name in ('rebuild_vendored_helper.sh', 'helper_source_fingerprint.py'):
        add_path(root / 'scripts' / name)
    payload = {'format': 1, 'objects': selected, 'files': files}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


if __name__ == '__main__':
    try:
        print(fingerprint(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent))
    except (ValueError, OSError, subprocess.CalledProcessError, KeyError) as error:
        sys.exit('Helper provenance failed: ' + str(error))
