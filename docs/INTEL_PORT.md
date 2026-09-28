# Intel Mac port plan

## Acceptance criteria

- Build the main executable, fan helper, Now Playing adapter, and all native dependencies for `x86_64` with a macOS 14 deployment target.
- Replace application branding with Vorkraft, including a distinct icon, bundle identifiers, helper identifiers, signing identity, support destinations, and update source. Preserve attribution and license notices.
- Ensure the updater can never install an upstream Vorssaint release over Vorkraft.
- Audit architecture-specific system monitoring, GPU/SMC sensors, fan control, audio processing, and private-framework integration; represent unsupported hardware features accurately.
- Run upstream self-tests and unit tests on Intel, then verify launch, permissions, menu bar interaction, window tools, clipboard, audio, sleep/wake, and monitoring on Intel hardware.
- Package an Intel app and verify every bundled Mach-O architecture, signing, and clean installation. Configure Vorkraft CI before enabling releases.

## Initial findings

- `Package.swift` requires macOS 14 and Swift tools 5.9.
- `build.sh` hardcodes `arm64-apple-macosx14.0`.
- App identity and repository URLs are defined in `Sources/Vorssaint/Core/AppInfo.swift`; additional branding and release URLs appear elsewhere and require a complete audit.
- Upstream requires forks to use separate branding, bundle identity, signing identity, and update feed.
- The existing local `Vorssaint.app` is excluded from version control and is not a Vorkraft deliverable.

## Progress

- [x] Preserve upstream Git history and licensing.
- [x] Establish Vorkraft repository documentation.
- [x] Implement Vorkraft branding and isolated update identity.
- [x] Implement Intel build configuration and resolve compiler failures.
- [ ] Validate Intel functionality and hardware-specific fallbacks.
- [ ] Enable Intel CI, packaging, and release workflow.

## Implementation in progress

- Renamed source/module and runtime identities to Vorkraft; preserved upstream copyright headers.
- Switched native targets to `x86_64-apple-macosx14.0`.
- Added a generated Vorkraft icon and isolated signing keychain names.
- Changed fan-helper peer validation to pin the local signing certificate; unsigned/ad-hoc peers are rejected.
- Disabled automatic installation of releases until Vorkraft release signing is configured.
- Added `Tools/sync-upstream.sh` with a local-repository integration test and a port verification gate.
- Intel release build, 69,942 regression checks, installation, signature verification, native launch, and sensor readback pass. Interactive permissions/features and GitHub CI remain under validation. See `INTEL_VALIDATION.md`.
