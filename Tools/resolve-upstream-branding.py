#!/usr/bin/env python3
"""Resolve only upstream merge conflicts proven to be identity-only fork edits."""
import pathlib
import subprocess


def git(*args):
    return subprocess.check_output(['git', *args])


def rebrand(text):
    result = []
    for line in text.splitlines(keepends=True):
        if 'Copyright' not in line and '© 2026 Vorssaint' not in line:
            line = (line.replace('vorssaint/vorssaint-utils', 'velora-app-labs/vorkraft')
                    .replace('com.vorssaint.utils', 'com.veloraapplabs.vorkraft')
                    .replace('VORSSAINT', 'VORKRAFT').replace('Vorssaint', 'Vorkraft')
                    .replace('vorssaint', 'vorkraft'))
        result.append(line)
    return ''.join(result)


def main():
    # Only a pending merge is eligible. Never rewrite ordinary working changes.
    git('rev-parse', '--verify', 'MERGE_HEAD')
    conflicts = git('diff', '--name-only', '--diff-filter=U', '-z').decode().split('\0')
    for name in filter(None, conflicts):
        if not name.startswith(('Sources/Vorkraft/', 'Tests/')) or not name.endswith('.swift'):
            continue
        path = pathlib.Path(name)
        if path.is_symlink():
            continue
        try:
            base, ours, theirs = (git('show', f':{stage}:{name}').decode() for stage in (1, 2, 3))
        except (subprocess.CalledProcessError, UnicodeError):
            continue
        if ours == rebrand(base):
            path.write_text(rebrand(theirs))
            subprocess.check_call(['git', 'add', '--', name])
            print(f'Resolved identity-only conflict: {name}')

    # New upstream test declarations can refer to the old source directory
    # even when Git has correctly mapped the source-file renames.
    generator = pathlib.Path('Tests/generate_sources.py')
    if generator.is_file() and str(generator) not in conflicts:
        text = generator.read_text()
        updated = text.replace('Sources/Vorssaint/', 'Sources/Vorkraft/')
        if updated != text:
            generator.write_text(updated)
            subprocess.check_call(['git', 'add', '--', str(generator)])

    # Test-only preference domains must match the namespace cleanup contract.
    # Also adapt literal source paths in newly added/changed test fixtures.
    changed = git('diff', '--cached', '--name-only', '-z').decode().split('\0')
    for name in changed:
        if name in conflicts or not name.startswith('Tests/') or not name.endswith('.swift'):
            continue
        path = pathlib.Path(name)
        if not path.is_file() or path.is_symlink():
            continue
        text = path.read_text()
        updated = text.replace('com.vorssaint.tests.', 'com.vorkraft.tests.').replace(
            'Sources/Vorssaint/', 'Sources/Vorkraft/')
        if updated != text:
            path.write_text(updated)
            subprocess.check_call(['git', 'add', '--', name])

    # Vorkraft owns its README; keep upstream documentation separately, even
    # when Git would have merged an upstream paragraph without a conflict.
    if pathlib.Path('docs/UPSTREAM_README.md').is_file():
        ours = git('show', 'HEAD:README.md')
        theirs = git('show', 'MERGE_HEAD:README.md')
        pathlib.Path('README.md').write_bytes(ours)
        pathlib.Path('docs/UPSTREAM_README.md').write_bytes(theirs)
        subprocess.check_call(['git', 'add', '--', 'README.md', 'docs/UPSTREAM_README.md'])


if __name__ == '__main__':
    main()
