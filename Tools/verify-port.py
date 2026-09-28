#!/usr/bin/env python3
"""Fail an upstream merge if it restores upstream identity or an ARM-only build."""
import argparse
import pathlib
import plistlib
import re
import subprocess
import sys

root = pathlib.Path(__file__).resolve().parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--bundle', type=pathlib.Path)
args = parser.parse_args()
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

info = plistlib.loads((root / 'Resources/Info.plist').read_bytes())
require(info.get('CFBundleIdentifier') == 'com.veloraapplabs.vorkraft', 'Wrong bundle identifier')
require(info.get('CFBundleExecutable') == 'Vorkraft', 'Wrong executable name')
require('TARGET="x86_64-apple-macosx14.0"' in (root / 'build.sh').read_text(), 'Intel build target changed')
require(not (root / 'Sources/Vorssaint').exists(), 'Upstream source directory was reintroduced; port new files')
for folder in ('Sources', 'Resources'):
    for path in (root / folder).rglob('*'):
        if not path.is_file() or path.suffix not in ('.swift', '.plist', '.strings', '.entitlements'):
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            if 'Copyright' in line or '© 2026 Vorssaint' in line:
                continue
            if any(token in line for token in ('com.vorssaint.utils', '3D485NHW29',
                                               'screenshots.vorssaint.com', '"Vorssaint"',
                                               'vorssaint/vorssaint-utils/releases')):
                errors.append(f'{path.relative_to(root)}:{number}: upstream identity/service restored')
for workflow in (root / '.github/workflows').glob('*'):
    require(workflow.name == 'intel.yml', f'Review new upstream workflow before enabling: {workflow.name}')
if args.bundle:
    bundle = args.bundle.resolve()
    built = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
    require(built.get('CFBundleIdentifier') == info['CFBundleIdentifier'], 'Built identity mismatch')
    binaries = [bundle / 'Contents/MacOS/Vorkraft',
                bundle / 'Contents/Library/LaunchServices/com.veloraapplabs.vorkraft.fan-control',
                bundle / 'Contents/Frameworks/libVorkraftNowPlaying.dylib']
    for binary in binaries:
        require(binary.is_file(), f'Missing required binary: {binary}')
    # Inspect every native payload, including dependencies introduced upstream.
    magic = {bytes.fromhex(value) for value in ('feedface', 'cefaedfe', 'feedfacf',
                                               'cffaedfe', 'cafebabe', 'bebafeca',
                                               'cafebabf', 'bfbafeca')}
    for binary in bundle.rglob('*'):
        if not binary.is_file():
            continue
        with binary.open('rb') as stream:
            if stream.read(4) not in magic:
                continue
        result = subprocess.run(['lipo', '-archs', str(binary)], capture_output=True, text=True)
        require(result.returncode == 0 and result.stdout.strip() == 'x86_64', f'Not an Intel-only binary: {binary}')
        load = subprocess.run(['otool', '-l', str(binary)], capture_output=True, text=True)
        minimum = re.search(r'\bminos (\d+)\.(\d+)', load.stdout)
        require(load.returncode == 0 and minimum is not None
                and tuple(map(int, minimum.groups())) <= (14, 0),
                f'Native payload requires a newer macOS deployment target: {binary}')
    result = subprocess.run(['codesign', '--verify', '--deep', '--strict', str(bundle)])
    require(result.returncode == 0, 'Bundle signature verification failed')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print('Vorkraft identity and Intel port checks passed.')
