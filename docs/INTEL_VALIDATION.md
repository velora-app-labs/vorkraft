# Intel validation record

Host: Intel Mac running macOS 26.7, Apple Swift 6.3.2. Deployment target: macOS 14.

## Confirmed

- Main executable, fan helper, and Now Playing adapter compile as `x86_64`.
- All bundled Mach-O files pass Intel architecture and macOS deployment-target checks.
- Ad-hoc bundle signatures verify with `codesign --verify --deep --strict`.
- Main self-test and helper self-test pass.
- The app launches as a native Intel process; the user confirmed normal onboarding/menu-bar display.
- User confirmed Accessibility and Screen Recording are granted after resetting stale entries from the early ad-hoc build.
- Final locally signed DMG packaging succeeds for the upstream-synced build.
- Read-only SMC probe finds CPU core/package, integrated/discrete GPU, battery, and both fan readings.
- Actual upstream update through `9d4f26048eb5038b2f520217fd01364d39039071` completed via the sync command, including build, self-tests, full regression suite, and bundle verification.
- Upstream sync integration tests cover no-op, preview, dirty checkout, clean merge, conflicts, validation failure, and resume.
- Full post-fix suite passes 69,942 checks and preference cleanup.
- Dedicated Vorkraft local signing certificate created successfully.
- Corrected app installed in `/Applications/Vorkraft.app`; Intel/deployment/signature checks and self-test pass.
- Installed app reports valid Intel CPU/GPU/battery temperatures.
- Certificate-pinned authentication requirements accept the installed app and helper signed by the Vorkraft certificate.
- Recorder suite passes 640 checks after choosing H.264 for Intel capture and export.

## Architecture changes

The upstream SMC filters selected Apple Silicon `Tp`/`Te` CPU and `Tg` GPU families. On the validation Mac, Intel readings instead include `TC1C` through `TC8C`, `TCXC`, `TCGC`, and `TG0P`/`TG1P`. Intel classification now separates CPU cores/package/diodes, CPU auxiliary sensors, and GPU sensors. Fan curves require verified core/package/diode readings; proximity readings cannot substitute for them.

The sensor naming was cross-checked against [Stats' sensor catalogue](https://github.com/exelban/stats/blob/master/Modules/Sensors/values.swift). Unsupported or invalid sensor readings remain unavailable rather than being fabricated. Older Intel fan controllers without the supported per-fan control keys remain read-only; the app does not write undocumented controller modes to claim compatibility.

The upstream HEVC path accepted writer settings but failed recording/export tests on Intel. Selecting H.264 on `x86_64` passed the same production-path tests, including retimed video, cuts, blur, and audio export. Apple Silicon retains the upstream codec preference.

## Remaining verification

- Exercise permission-dependent capture, window interaction, clipboard, and sleep/wake in the installed app.
- Finish the Intel GitHub Actions run.

## Distribution limitations

This is an independent private fork. It does not have a Vorkraft Developer ID/notarized distribution channel or a hosted sharing/feedback service. Automatic binary updates are disabled; source updates use `Tools/sync-upstream.sh`. Local recording, image capture, editing, and export remain supported. Installing a dedicated local signing certificate enables authenticated fan-helper IPC; ad-hoc peers are rejected.
