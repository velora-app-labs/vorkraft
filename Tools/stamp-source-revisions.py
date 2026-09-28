#!/usr/bin/env python3
"""Stamp the revisions included in a build, without querying remote heads."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

root = Path(__file__).resolve().parents[1]

def git(*args):
    result = subprocess.run(['git', *args], cwd=root, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ''

upstream = json.loads((root / 'upstream-revision.json').read_text())
commit = git('rev-parse', 'HEAD') or 'Unavailable'
if git('status', '--porcelain', '--untracked-files=normal'):
    commit += ' (uncommitted changes)'
branch = git('symbolic-ref', '--quiet', '--short', 'HEAD')
branch = branch or os.environ.get('GITHUB_HEAD_REF') or os.environ.get('GITHUB_REF_NAME') or 'Detached HEAD'
path = Path(sys.argv[1])
with path.open('rb') as source:
    info = plistlib.load(source)
info.update(VorkraftSourceBranch=branch, VorkraftSourceCommit=commit,
            VorkraftUpstreamBranch=upstream['branch'], VorkraftUpstreamCommit=upstream['commit'])
with path.open('wb') as target:
    plistlib.dump(info, target)
