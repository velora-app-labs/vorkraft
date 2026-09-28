#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorkraft contributors
set -euo pipefail
cd "$(dirname "$0")/.."

usage() {
    cat <<'HELP'
Usage: ./Tools/sync-upstream.sh [--check | --resume] [--install]

Default: fetch upstream/main, merge on a new sync branch, validate the Intel
port, build, run self-tests and unit tests, then commit the verified merge.
--check    Only fetch and show incoming commits; do not change the checkout.
--resume   Continue a conflicted/failed sync after resolving and staging fixes.
--install  Install the verified app after the sync succeeds (opt-in).

Conflicts are left in place. Resolve them, git add the resolved files, then run
--resume. To abandon an in-progress merge use git merge --abort, then return to
your original branch. This command never pushes or changes GitHub releases.
HELP
}
mode=sync
install=0
for arg in "$@"; do
    case "$arg" in
        --help|-h) usage; exit 0 ;;
        --check|--resume)
            [[ "$mode" == sync ]] || { usage >&2; exit 2; }
            mode="${arg#--}" ;;
        --install) install=1 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$mode" != check || "$install" == 0 ]] || { usage >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
[[ "$PWD" == "$root" ]] || { echo 'Run from the Vorkraft checkout.' >&2; exit 1; }

if [[ "$mode" == resume ]]; then
    branch="$(git symbolic-ref --quiet --short HEAD)"
    [[ "$branch" == sync/upstream-* ]] || { echo 'Not on an upstream sync branch.' >&2; exit 1; }
    git rev-parse -q --verify MERGE_HEAD >/dev/null || {
        echo 'No pending upstream merge. Start a new sync instead.' >&2; exit 1;
    }
    [[ -z "$(git ls-files -u)" ]] || { echo 'Resolve and stage remaining conflicts first.' >&2; exit 1; }
    git diff --quiet || { echo 'Stage your resolved changes with git add first.' >&2; exit 1; }
else
    [[ -z "$(git status --porcelain)" ]] || { echo 'Commit or stash local changes before syncing.' >&2; exit 1; }
    upstream_url='https://github.com/vorssaint/vorssaint-utils.git'
    if git remote get-url upstream >/dev/null 2>&1; then
        [[ "$(git remote get-url upstream)" == "$upstream_url" ]] || {
            echo "Unexpected upstream URL; expected $upstream_url" >&2; exit 1;
        }
    else
        git remote add upstream "$upstream_url"
    fi
    git fetch --no-tags upstream main
    incoming="$(git rev-parse FETCH_HEAD)"
    if git merge-base --is-ancestor "$incoming" HEAD; then
        echo 'Vorkraft already contains the latest upstream main.'
        exit 0
    fi
    git log --oneline "HEAD..$incoming"
    [[ "$mode" != check ]] || exit 0
    branch="sync/upstream-$(date -u +%Y%m%d-%H%M%S)-${incoming:0:8}"
    git switch -c "$branch"
    merge_status=0
    git -c merge.renameLimit=10000 merge --no-ff --no-commit "$incoming" || merge_status=$?
    # Mechanical name-only differences are safe to carry forward; all other
    # conflicts still require review. An operational merge failure is not a
    # conflict and must never be turned into a success.
    git rev-parse -q --verify MERGE_HEAD >/dev/null || { echo "Merge did not start." >&2; exit 1; }
    python3 Tools/resolve-upstream-branding.py
    if [[ -n "$(git ls-files -u)" ]]; then
        echo 'Resolve conflicts, stage the fixes, and run ./Tools/sync-upstream.sh --resume.' >&2
        exit 1
    fi
fi

# Persist the integrated upstream revision for offline and shallow-clone builds.
printf '{"branch":"main","commit":"%s"}\n' "$(git rev-parse MERGE_HEAD)" > upstream-revision.json
git add upstream-revision.json

# All changes remain reviewable until every validation step passes.
python3 Tools/verify-port.py
./build.sh
./build/Vorkraft --selftest
./build.sh --test
python3 Tools/verify-port.py --bundle build/stage/Vorkraft.app
git diff --check
git diff --cached --check
git commit -m "Merge upstream into Vorkraft after Intel validation"
printf 'Verified update on %s. Review and merge this branch into main when ready.\n' "$branch"
if [[ "$install" == 1 ]]; then
    ./build.sh --install
fi
