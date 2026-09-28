# Vorkraft changelog

## [0.1.0] - 2026-09-28

### Added
- Initial Intel Mac port with separate Vorkraft app identity and original icon.
- Upstream source synchronization command with conflict recovery and Intel validation.
- Latest upstream linear mouse scrolling feature, integrated through commit `9d4f2604`.

### Changed
- Native executables and helper libraries target Intel Macs running macOS 14 or later.
- Intel CPU/GPU temperature sensors are classified separately from Apple Silicon sensors.
- Intel recording and video export use H.264 for encoder compatibility.
- Preferences, files, helper identities, and local signing are separate from Vorssaint.

### Distribution
- This development version uses local signing; a notarized release is not available yet.
- Automatic binary updates and hosted sharing are unavailable. Update from source and use local file export.

Source and original feature history are preserved in the upstream CHANGELOG.md.
