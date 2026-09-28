#!/usr/bin/env python3
"""Exercise upstream sync against temporary local repositories; no network/build."""
import os
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

script = Path(__file__).resolve().parents[1] / 'Tools/sync-upstream.sh'
env = dict(os.environ, GIT_AUTHOR_NAME='Sync Test', GIT_AUTHOR_EMAIL='sync@example.invalid',
           GIT_COMMITTER_NAME='Sync Test', GIT_COMMITTER_EMAIL='sync@example.invalid',
           GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')

def run(cwd, *args, ok=True):
    result = subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True)
    if ok and result.returncode:
        raise AssertionError(result.stdout + result.stderr)
    return result

with tempfile.TemporaryDirectory(prefix='vorkraft-sync-test-') as tmp:
    root = Path(tmp)
    upstream = root / 'upstream'
    upstream.mkdir()
    run(upstream, 'git', 'init')
    run(upstream, 'git', 'symbolic-ref', 'HEAD', 'refs/heads/main')
    (upstream / 'feature.txt').write_text('original\n')
    (upstream / 'Sources/Vorkraft').mkdir(parents=True)
    (upstream / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorssaint\"\n')
    run(upstream, 'git', 'add', '.')
    run(upstream, 'git', 'commit', '-m', 'upstream initial')
    fork = root / 'fork'
    run(root, 'git', 'clone', str(upstream), str(fork))
    run(fork, 'git', 'remote', 'rename', 'origin', 'upstream')
    url = 'https://github.com/vorssaint/vorssaint-utils.git'
    run(fork, 'git', 'remote', 'set-url', 'upstream', url)
    # get-url expands insteadOf, so rewrite only the fetch through a git wrapper.
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    real_git = shutil.which('git')
    wrapper = bin_dir / 'git'
    wrapper.write_text(f'''#!/bin/bash
if [[ "$1" == fetch ]]; then
    exec "{real_git}" -c 'url.{upstream}.insteadOf={url}' "$@"
fi
exec "{real_git}" "$@"
''')
    wrapper.chmod(0o755)
    env['PATH'] = str(bin_dir) + os.pathsep + env['PATH']
    (fork / 'Tools').mkdir()
    shutil.copy2(script, fork / 'Tools/sync-upstream.sh')
    shutil.copy2(script.with_name('resolve-upstream-branding.py'), fork / 'Tools/resolve-upstream-branding.py')
    (fork / 'Tools/verify-port.py').write_text('print("fixture validation")\n')
    (fork / 'build.sh').write_text('#!/bin/sh\nmkdir -p build\nprintf "#!/bin/sh\\nexit 0\\n" > build/Vorkraft\nchmod +x build/Vorkraft\n')
    (fork / 'build.sh').chmod(0o755)
    (fork / '.gitignore').write_text('build/\n')
    (fork / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorkraft\"\n')
    run(fork, 'git', 'add', '.')
    run(fork, 'git', 'commit', '-m', 'fork tooling')
    command = './Tools/sync-upstream.sh'
    assert 'already contains' in run(fork, command).stdout
    (fork / 'dirty').write_text('keep me')
    assert run(fork, command, ok=False).returncode != 0
    (fork / 'dirty').unlink()
    (upstream / 'new-feature').write_text('new feature\n')
    (upstream / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorssaint\"\nlet newFeature = true\n')
    run(upstream, 'git', 'add', '.')
    run(upstream, 'git', 'commit', '-m', 'new feature')
    before = run(fork, 'git', 'rev-parse', 'HEAD').stdout
    run(fork, command, '--check')
    assert before == run(fork, 'git', 'rev-parse', 'HEAD').stdout
    run(fork, command)
    assert (fork / 'new-feature').exists()
    revision = json.loads((fork / 'upstream-revision.json').read_text())
    assert revision == {'branch': 'main', 'commit': run(upstream, 'git', 'rev-parse', 'HEAD').stdout.strip()}
    assert (fork / 'Sources/Vorkraft/Demo.swift').read_text() == 'let name = \"Vorkraft\"\nlet newFeature = true\n'
    assert run(fork, 'git', 'branch', '--show-current').stdout.startswith('sync/upstream-')
    assert len(run(fork, 'git', 'rev-list', '--parents', '-n', '1', 'HEAD').stdout.split()) == 3
    run(fork, 'git', 'switch', '-C', 'main')
    (fork / 'feature.txt').write_text('fork version\n')
    (fork / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorkraft Custom\"\n')
    run(fork, 'git', 'commit', '-am', 'fork change')
    (upstream / 'feature.txt').write_text('upstream version\n')
    (upstream / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorssaint New\"\n')
    run(upstream, 'git', 'commit', '-am', 'upstream conflict')
    assert run(fork, command, ok=False).returncode != 0
    assert 'Demo.swift' in run(fork, 'git', 'ls-files', '-u').stdout
    assert run(fork, command, '--resume', ok=False).returncode != 0
    (fork / 'feature.txt').write_text('resolved version\n')
    (fork / 'Sources/Vorkraft/Demo.swift').write_text('let name = \"Vorkraft Resolved\"\n')
    run(fork, 'git', 'add', 'feature.txt', 'Sources/Vorkraft/Demo.swift')
    run(fork, command, '--resume')
    assert (fork / 'feature.txt').read_text() == 'resolved version\n'
    assert not run(fork, 'git', 'status', '--porcelain').stdout
    run(fork, 'git', 'switch', '-C', 'main')
    (fork / 'Tools/verify-port.py').write_text('raise SystemExit("blocked fixture")\n')
    run(fork, 'git', 'commit', '-am', 'validation failure fixture')
    (upstream / 'another-feature').write_text('incoming\n')
    run(upstream, 'git', 'add', '.')
    run(upstream, 'git', 'commit', '-m', 'another feature')
    before = run(fork, 'git', 'rev-parse', 'HEAD').stdout
    assert run(fork, command, ok=False).returncode != 0
    assert before == run(fork, 'git', 'rev-parse', 'HEAD').stdout
    assert run(fork, 'git', 'rev-parse', '--verify', 'MERGE_HEAD').returncode == 0
    (fork / 'Tools/verify-port.py').write_text('print("corrected fixture")\n')
    run(fork, 'git', 'add', 'Tools/verify-port.py')
    run(fork, command, '--resume')
print('PASS: no-op, dirty checkout, check-only, verified merge, conflicts, failed validation, and resume')
