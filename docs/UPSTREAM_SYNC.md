# Keeping Vorkraft current

Vorkraft retains upstream history and uses merge commits to track which Vorssaint changes have been integrated. The `upstream` remote is `https://github.com/vorssaint/vorssaint-utils.git`; `origin` is the private Vorkraft repository.

## Routine update

1. Start from a clean, committed Vorkraft checkout, normally `main`.
2. Run `./Tools/sync-upstream.sh` (or add `--install` to install after validation).
3. Inspect the new `sync/upstream-*` branch and test the resulting app. The command runs identity checks, the Intel build, self-tests, unit tests, architecture checks, and signature verification.
4. Merge the reviewed branch into `main` and push when ready. The sync command itself never pushes or publishes releases.

Use `--check` to fetch and list incoming changes without changing your branch or working files. No incoming changes is a successful no-op.

## Conflicts or validation failures

The sync branch and uncommitted merge remain available for inspection. Resolve conflicts and any build/test failures, stage corrections with `git add`, and run `./Tools/sync-upstream.sh --resume`. Add `--install` again if desired. Do not make a manual merge commit before resuming; the tool makes that commit after validation passes.

To cancel, use `git merge --abort` and switch back to your original branch. The command never discards local work automatically.

## What needs human review

Name-only source conflicts are resolved automatically only when the entire Vorkraft side is exactly the upstream base with the known branding substitutions. Any additional behavioral changes still require manual review. Vorkraft’s README stays in place and the incoming upstream README is kept in `docs/UPSTREAM_README.md`.

Git carries existing fork changes forward; it cannot design Intel replacements for new architecture-specific upstream code. Newly added files, changed update/signing contracts, sensor behavior, new service endpoints, and new upstream workflows require review. Source checks catch known identity regressions but are not proof of complete runtime compatibility. Upstream workflows remain archived until explicitly adapted for Vorkraft.

The private repository is not a public update feed. This source-update command is the supported update path during development; the app does not automatically download upstream releases.
