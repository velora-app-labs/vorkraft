# Vorkraft troubleshooting

## macOS shows permission enabled, but Vorkraft says “Not granted”

First quit and reopen `/Applications/Vorkraft.app`. Screen Recording and Full Disk Access can require a restart. Accessibility, Screen Recording, and Full Disk Access have separate entries.

A permission entry created for an early ad-hoc build can become stale when switching to the stable locally signed build. If restarting does not help, quit Vorkraft and reset only the affected Vorkraft permission:

```sh
tccutil reset Accessibility com.veloraapplabs.vorkraft
tccutil reset ScreenCapture com.veloraapplabs.vorkraft
open /Applications/Vorkraft.app
```

In Vorkraft, click **Grant access** for Accessibility and **Request** for Screen Recording, approve the fresh entries in System Settings, and choose **Quit & Reopen** if macOS offers it. These commands revoke only the named permissions for Vorkraft; macOS requires you to grant them again. They do not grant access automatically or reset other apps.

This procedure restored both permissions on the Intel validation Mac after its initial ad-hoc build was replaced by a locally signed build.

`./build.sh --install` creates/reuses Vorkraft’s dedicated local signing identity so subsequent locally signed builds keep the same identity. Moving to a different signing certificate later may require fresh permission grants.

## Which copy to open

Use `/Applications/Vorkraft.app` for daily use. `build/stage/Vorkraft.app` is a build artifact. Avoid granting permissions to old downloaded or development copies.

## Updates

Run `./Tools/sync-upstream.sh --install` from a clean checkout. See [the sync guide](UPSTREAM_SYNC.md) if an upstream change requires conflict resolution. Vorkraft does not install upstream Vorssaint binaries over itself.

## Hosted features

This private fork does not have the upstream project's sharing/feedback server or notarized automatic-update channel. Save captures and recordings locally and use the [Vorkraft issue tracker](https://github.com/velora-app-labs/vorkraft/issues) for support.
