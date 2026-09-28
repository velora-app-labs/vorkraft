#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Vorssaint

# Builds Vorkraft, assembles the .app bundle, signs it and (with --install)
# installs it into /Applications.
#
# The bundle is staged in a temporary directory outside ~/Documents: folders synced
# by File Provider gain xattrs (com.apple.provenance etc.) that invalidate codesign.
set -euo pipefail
cd "$(dirname "$0")"

# The icon catalog and the bundle are staged in temp dirs; sweep both however
# the script ends.
ICON_TMP=""
STAGE_TMP=""

cleanup() {
    [[ -n "$ICON_TMP" ]] && rm -rf "$ICON_TMP"
    [[ -n "$STAGE_TMP" ]] && rm -rf "$STAGE_TMP"
    return 0
}
trap cleanup EXIT
# zsh runs the EXIT trap when the script is hung up, but not when it is
# interrupted or terminated; route those through exit so a Ctrl-C partway
# into the build sweeps like any other ending.
trap 'exit 1' INT TERM HUP

# Flags: --dev builds the local-only "Vorkraft (Developer)" variant (its own
# bundle id, so it coexists with the official app); --install puts it in /Applications.
DEV=0
INSTALL=0
TEST=0
TEST_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dev)     DEV=1 ;;
        --install) INSTALL=1 ;;
        --test)    TEST=1 ;;
        --test-suite=*) TEST=1; TEST_ARGS+=("--suite=${arg#*=}") ;;
        --list-tests) TEST=1; TEST_ARGS+=(--list) ;;
    esac
done

if (( DEV )); then
    APP_NAME="Vorkraft (Developer)"
    EXECUTABLE="VorkraftDeveloper"
    APP_BUNDLE_ID="com.veloraapplabs.vorkraft.dev"
    BUILD_VARIANT_FLAGS=(-D VORKRAFT_DEVELOPMENT)
    APP_OPTIMIZATION_FLAGS=(-Onone)
    BUILD_CONFIGURATION="debug"
else
    APP_NAME="Vorkraft"
    EXECUTABLE="Vorkraft"
    APP_BUNDLE_ID="com.veloraapplabs.vorkraft"
    BUILD_VARIANT_FLAGS=()
    APP_OPTIMIZATION_FLAGS=(-O)
    BUILD_CONFIGURATION="release"
fi
FAN_HELPER_ID="$APP_BUNDLE_ID.fan-control"
# Now Playing is read through /usr/bin/perl loading this library; see
# Sources/NowPlayingAdapter. Staged under Contents/Frameworks, signed on its own.
NOW_PLAYING_ADAPTER_ID="$APP_BUNDLE_ID.now-playing"
NOW_PLAYING_ADAPTER="libVorkraftNowPlaying.dylib"
TARGET="x86_64-apple-macosx14.0"
ENTITLEMENTS="Resources/Vorkraft.entitlements"
LEGACY_IDENTITY="Vorkraft Utils Signing"

developer_id_identity() {
    security find-identity -v -p codesigning 2>/dev/null \
        | grep 'Developer ID Application' \
        | head -1 \
        | sed -E 's/.*"(.*)".*/\1/' || true
}

# A find-identity listing also names certificates codesign then rejects (an
# expired one fails the build with errSecInternalComponent), and -v excludes
# every self-signed one; ask codesign itself with a throwaway copy of /bin/echo.
legacy_identity_installed() {
    local probe signed=1
    # A locked keychain still lists its identities but cannot sign with them,
    # and this one is locked after every reboot; unlock it before asking.
    security unlock-keychain -p vorkraft-signing \
        "$HOME/Library/Keychains/vorkraft-signing.keychain-db" 2>/dev/null || true
    probe="$(mktemp)"
    cp /bin/echo "$probe"
    /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$probe" \
        >/dev/null 2>&1 && signed=0
    rm -f "$probe"
    return $signed
}

# Any build that lands in /Applications needs a stable signature, not just the
# Developer one: macOS ties Accessibility and Screen Recording grants to the
# exact binary hash, so an ad-hoc rebuild orphans them while System Settings
# keeps showing them as granted, and no new prompt ever appears. A plain
# --install strands them under the released bundle id, on the app the user
# actually relies on. When no identity is installed, create the stable local one
# up front instead of falling through to ad-hoc — setup-signing.sh is free,
# offline and idempotent. Gating on the install rather than the variant keeps
# this off CI, where neither ci.yml nor release.yml passes --install.
if (( DEV || INSTALL )) && [[ -z "$(developer_id_identity)" ]] \
    && ! legacy_identity_installed; then
    echo "▸ No signing identity installed; creating the stable local one…"
    if ! ./Tools/setup-signing.sh; then
        echo "  ⚠ Tools/setup-signing.sh failed; signing ad-hoc instead." >&2
        echo "    Accessibility and Screen Recording grants will not survive rebuilds:" >&2
        echo "    System Settings will show them as granted while the app is not trusted." >&2
        echo "    After fixing the identity, clear the stale grant once with:" >&2
        echo "      tccutil reset Accessibility $APP_BUNDLE_ID" >&2
    fi
fi

codesign_with_timestamp_retry() {
    local attempt
    for attempt in 1 2 3; do
        if /usr/bin/codesign "$@"; then
            return 0
        fi
        if (( attempt < 3 )); then
            echo "  Developer ID signing failed; retrying ($((attempt + 1))/3)"
            sleep "$attempt"
        fi
    done
    return 1
}

write_swift_output_file_map() {
    local output_file="$1"
    local object_dir="$2"
    shift 2
    local source artifact

    {
        print -r -- "{"
        print -r -- "  \"\": {"
        print -r -- "    \"swift-dependencies\": \"$object_dir/master.swiftdeps\""
        print -r -- "  }"
        for source in "$@"; do
            artifact="${source//\//__}"
            artifact="${artifact%.swift}"
            print -r -- ","
            print -r -- "  \"$source\": {"
            print -r -- "    \"object\": \"$object_dir/$artifact.o\","
            print -r -- "    \"swift-dependencies\": \"$object_dir/$artifact.swiftdeps\""
            print -r -- "  }"
        done
        print -r -- "}"
    } > "$output_file"
}

finalize_installed_bundle_after_child() {
    local bundle="$1"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
    local devid
    devid="$(developer_id_identity)"

    echo "▸ Finalizing installed signature…"
    sleep 3
    if [[ -n "$devid" ]]; then
        [[ -f "$helper" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$FAN_HELPER_ID" --sign "$devid" "$helper"
        [[ -f "$adapter" ]] && codesign_with_timestamp_retry --force --strip-disallowed-xattrs \
            --options runtime --timestamp --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$devid" "$adapter"
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$devid" "$bundle"
    elif legacy_identity_installed; then
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign "$LEGACY_IDENTITY" "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$LEGACY_IDENTITY" "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$bundle"
    else
        [[ -f "$helper" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$FAN_HELPER_ID" --sign - "$helper"
        [[ -f "$adapter" ]] && /usr/bin/codesign --force --strip-disallowed-xattrs \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$adapter"
        /usr/bin/codesign --force --strip-disallowed-xattrs --sign - "$bundle"
    fi
    [[ -f "$helper" ]] && /usr/bin/codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && /usr/bin/codesign --verify --strict "$adapter"
    /usr/bin/codesign --verify --deep --strict "$bundle"
    echo "✓ Signature ready: $bundle"
}

if (( INSTALL && ! TEST )) && [[ "${VORKRAFT_INSTALL_CHILD:-0}" != "1" ]]; then
    VORKRAFT_INSTALL_CHILD=1 "$0" "$@"
    child_status=$?
    if (( child_status != 0 )); then
        exit "$child_status"
    fi
    finalize_installed_bundle_after_child "/Applications/$APP_NAME.app"
    exit 0
fi

# Prefer the macOS 26 SDK when present: the 27 SDK turns SwiftUI property wrappers
# into macros (SwiftUIMacros plugin) that the Command Line Tools cannot load yet.
PINNED_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    SDK="$(xcrun --show-sdk-path)"
elif [[ -d "$PINNED_SDK" ]]; then
    SDK="$PINNED_SDK"
else
    SDK="$(xcrun --show-sdk-path)"
fi
SDK_COMPAT_FLAGS=()
VM_STATISTICS_COMPAT_FLAGS=(-I Sources/VMStatisticsCompat)
HID_EVENT_SYSTEM_FLAGS=(-I Sources/HIDEventSystem)
if [[ "$SDK" == "$PINNED_SDK" ]]; then
    # Swift 6.4 can read the SDK 26 interfaces when given their compiler version.
    SDK_COMPAT_FLAGS=(-Xfrontend -interface-compiler-version -Xfrontend 6.3.2)
fi

# The defaults migrations under test need a real UserDefaults suite, and every
# suite leaves an empty plist in ~/Library/Preferences. The tests already clear
# the domains, but cfprefsd writes the emptied file back out around the time the
# process that owned it exits, so only a caller that outlives the run can remove
# them. `PreferenceNamespaceTests` scans every compiled Swift test file against
# these namespaces, which keeps this sweep complete without a second list.
discard_test_preferences() {
    local preferences="${1:-$HOME/Library/Preferences}" name attempt
    local survivors=0 quiet_passes=0
    # cfprefsd can recreate an emptied domain after the first removal. Require
    # two quiet checks, but keep a hard limit so persistent failures still fail CI.
    for attempt in {1..10}; do
        for name in "vorss.tests." "com.vorkraft.tests."; do
            rm -f "$preferences"/$name*.plist(N)
        done
        rm -f "$preferences/metrics-tests.plist"
        sleep 0.2
        survivors=$(find "$preferences" -maxdepth 1 \
            \( -name "vorss.tests.*.plist" -o -name "com.vorkraft.tests.*.plist" \
               -o -name "metrics-tests.plist" \) 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$survivors" == "0" ]]; then
            quiet_passes=$((quiet_passes + 1))
            if (( quiet_passes == 2 )); then return 0; fi
        else
            quiet_passes=0
        fi
    done
    echo "✗ test preferences did not settle in $preferences ($survivors remaining)" >&2
    return 1
}

# Standalone automated tests: pure contracts plus isolated disk, subprocess,
# keyboard-data and media fixtures. No application windows or device capture.
if (( TEST )); then
    python3 Tests/generate_sources.py
    TEST_OBJECT_DIR="build/objects/tests"
    mkdir -p "$TEST_OBJECT_DIR"
    TEST_SOURCES=(
        Sources/Vorkraft/Services/Media/MediaSupport.swift
        Sources/Vorkraft/Core/QuitProtectionSupport.swift
        Sources/Vorkraft/Core/QuitProtectionStrings.swift
        Sources/Vorkraft/Core/Defaults.swift
        Sources/Vorkraft/Core/NotchStrings.swift
        Sources/Vorkraft/Core/NotchTourStrings.swift
        Sources/Vorkraft/Core/NotchEditorStrings.swift
        Sources/Vorkraft/UI/Settings/NotchSettingsTabRow.swift
        Sources/Vorkraft/Core/NotchActivityStrings.swift
        Sources/Vorkraft/Services/Notch/NotchTimerSupport.swift
        Sources/Vorkraft/Services/Notch/NotchTimerAlert.swift
        Sources/Vorkraft/Services/Notch/NotchAccessorySupport.swift
        Sources/Vorkraft/Services/QuickTools/CameraPreviewSupport.swift
        Sources/Vorkraft/Core/NotchMusicExtrasStrings.swift
        Sources/Vorkraft/Services/Notch/NotchLyricsSupport.swift
        Sources/Vorkraft/Services/Notch/NotchQueueSupport.swift
        Sources/Vorkraft/Core/NotchFilesStrings.swift
        Sources/Vorkraft/Services/Notch/NotchFileToolsSupport.swift
        Sources/Vorkraft/Services/Notch/NotchDownloadSupport.swift
        Sources/Vorkraft/Services/Notch/NotchDownloadProgressObserver.swift
        Sources/Vorkraft/Core/NotchCalendarStrings.swift
        Sources/Vorkraft/Core/NotchNotificationStrings.swift
        Sources/Vorkraft/Core/NotchGestureStrings.swift
        Sources/Vorkraft/Core/NotchAgentStrings.swift
        Sources/Vorkraft/Services/Notch/NotchAgentSupport.swift
        Sources/Vorkraft/Services/AgentUsage/AgentUsageModels.swift
        Sources/Vorkraft/Services/AgentUsage/AgentPricing.swift
        Sources/Vorkraft/Services/AgentUsage/AgentLogParser.swift
        Sources/Vorkraft/Services/AgentUsage/AgentUsageSummary.swift
        Sources/Vorkraft/Services/AgentUsage/AgentUsageStore.swift
        Sources/Vorkraft/Services/AgentUsage/AgentClaudeAppUsage.swift
        Sources/Vorkraft/Services/Notch/NotchGestureSupport.swift
        Sources/Vorkraft/Services/Notch/NotchSectionPaging.swift
        Sources/Vorkraft/Services/Notch/NotchSliderEditing.swift
        Sources/Vorkraft/Services/Notch/NotchNotificationSupport.swift
        Sources/Vorkraft/Services/Notch/NotchNotificationReaderCore.swift
        Sources/Vorkraft/Services/Notch/NotchCalendarSupport.swift
        Sources/Vorkraft/Services/Notch/NotchSupport.swift
        Sources/Vorkraft/Services/Notch/NotchAudioLevelSupport.swift
        Sources/Vorkraft/Services/Notch/NotchVolumeKeyGate.swift
        Sources/Vorkraft/Services/Notch/NotchMusicSupport.swift
        Sources/Vorkraft/UI/Notch/NotchEqualizerBars.swift
        Sources/Vorkraft/UI/Notch/NotchAgentAnimationView.swift
        Sources/Vorkraft/UI/WindowVisibilityReader.swift
        Sources/Vorkraft/Services/Notch/NotchMusicAutomationSupport.swift
        Sources/Vorkraft/Services/Notch/NotchMusicAutomation.swift
        Sources/Vorkraft/Services/Notch/NotchPlaybackSource.swift
        Sources/Vorkraft/Services/Notch/NotchPlaybackCommand.swift
        Sources/Vorkraft/Services/Notch/NotchMusicCommandWriter.swift
        Sources/Vorkraft/Core/FeatureCatalog.swift
        Sources/Vorkraft/Core/FeaturePresets.swift
        Sources/Vorkraft/Core/FeatureHubStrings.swift
        Sources/Vorkraft/Core/ShortcutSettingsStrings.swift
        Sources/Vorkraft/Core/SettingsBackupSupport.swift
        Sources/Vorkraft/Core/BackupStrings.swift
        Sources/Vorkraft/Core/SnippetStrings.swift
        Sources/Vorkraft/Core/AlertSoundStrings.swift
        Sources/Vorkraft/Core/BrightnessStrings.swift
        Sources/Vorkraft/Core/MediaImageStrings.swift
        Sources/Vorkraft/Core/QuickToggleStrings.swift
        Sources/Vorkraft/Core/ScreenshotStrings.swift
        Sources/Vorkraft/Core/RecentCaptureStrings.swift
        Sources/Vorkraft/Core/RecorderStrings.swift
        Sources/Vorkraft/Core/RecorderShareStrings.swift
        Sources/Vorkraft/Core/CameraPreviewStrings.swift
        Sources/Vorkraft/Core/WallpaperStrings.swift
        Sources/Vorkraft/Services/Wallpaper/WallpaperSupport.swift
        Sources/Vorkraft/Core/ScratchpadStrings.swift
        Sources/Vorkraft/Core/FinderRenameStrings.swift
        Sources/Vorkraft/Core/CommandBarStrings.swift
        Sources/Vorkraft/Core/FeedbackStrings.swift
        Sources/Vorkraft/Core/RadialMenuStrings.swift
        Sources/Vorkraft/Core/MenuBarAppearanceStrings.swift
        Sources/Vorkraft/Core/AppAppearance.swift
        Sources/Vorkraft/Core/AppearanceStrings.swift
        Sources/Vorkraft/Core/GeneralSettingsStrings.swift
        Sources/Vorkraft/Core/SettingsPageStrings.swift
        Sources/Vorkraft/Core/BatteryTimeStrings.swift
        Sources/Vorkraft/Core/KeepAwakeStrings.swift
        Sources/Vorkraft/Core/BluetoothSleepStrings.swift
        Sources/Vorkraft/Core/PermissionGuideStrings.swift
        Sources/Vorkraft/Core/FanControlStrings.swift
        Sources/Vorkraft/Core/ConnectedDevicesStrings.swift
        Sources/Vorkraft/Services/FanControl/FanControlSupport.swift
        Sources/Vorkraft/Services/FanControl/FanControlResumeSupport.swift
        Sources/Vorkraft/Services/Snippets/TextSnippetSupport.swift
        Sources/Vorkraft/Services/RadialMenu/RadialMenuSupport.swift
        Sources/Vorkraft/Services/QuickTools/ScratchpadSupport.swift
        Sources/Vorkraft/Services/QuickTools/ScratchpadStore.swift
        Sources/Vorkraft/Services/KillProcess/KillProcessSupport.swift
        Sources/Vorkraft/Services/Recorder/RecorderSupport.swift
        Sources/Vorkraft/Services/Recorder/RecorderSampleTiming.swift
        Sources/Vorkraft/Services/Recorder/RecorderWriter.swift
        Sources/Vorkraft/Services/Recorder/RecorderCaptureEngine.swift
        Sources/Vorkraft/Core/RecorderExportStrings.swift
        Sources/Vorkraft/Services/Recorder/RecorderComposer.swift
        Sources/Vorkraft/Services/Recorder/RecorderComposerPlan.swift
        Sources/Vorkraft/Services/Recorder/RecorderCursorSprite.swift
        Sources/Vorkraft/Services/Recorder/RecorderTextRenderer.swift
        Sources/Vorkraft/Services/Recorder/RecorderImageRenderer.swift
        Sources/Vorkraft/Services/Recorder/RecorderExporter.swift
        Sources/Vorkraft/Services/Recorder/RecorderComposition.swift
        Sources/Vorkraft/Services/Recorder/RecordingSharingSupport.swift
        Sources/Vorkraft/Services/PrivateFileStore.swift
        Sources/Vorkraft/Services/Recorder/RecorderTakeStore.swift
        Sources/Vorkraft/Services/Recorder/RecorderPresetImageStore.swift
        Sources/Vorkraft/Services/Recorder/RecorderMotion.swift
        Sources/Vorkraft/Services/Recorder/RecorderPointerTrack.swift
        Sources/Vorkraft/Services/Recorder/RecorderTypingTrack.swift
        Sources/Vorkraft/Services/Recorder/RecorderTimeline.swift
        Sources/Vorkraft/Services/Recorder/RecorderTextOverlay.swift
        Sources/Vorkraft/Services/Recorder/RecorderImageOverlay.swift
        Sources/Vorkraft/Services/Recorder/RecorderBlurRegion.swift
        Sources/Vorkraft/Services/Recorder/RecorderEditDocument.swift
        Sources/Vorkraft/Core/AppInfo.swift
        Sources/Vorkraft/Core/GlobalShortcut.swift
        Sources/Vorkraft/Core/SymbolicHotKeys.swift
        Sources/Vorkraft/Services/SystemShortcutTakeoverSupport.swift
        Sources/Vorkraft/Core/Localization.swift
        Sources/Vorkraft/Core/Localizations/Strings+*.swift
        Sources/Vorkraft/Core/FeatureStrings.swift
        Sources/Vorkraft/Core/KillProcessStrings.swift
        Sources/Vorkraft/Core/PortManagerStrings.swift
        Sources/Vorkraft/Core/WhatsAppDownloadStrings.swift
        Sources/Vorkraft/Core/WhatsAppOrganizerStrings.swift
        Sources/Vorkraft/Core/ReleaseNotes.swift
        Sources/Vorkraft/Core/URLCleaning.swift
        Sources/Vorkraft/Services/GeneralPasteboardAccess.swift
        Sources/Vorkraft/Services/Clipboard/ClipboardHistoryWrite.swift
        Sources/Vorkraft/Services/Audio/MixerRoutingSupport.swift
        Sources/Vorkraft/Services/Audio/MusicLaunchSupport.swift
        Sources/Vorkraft/Services/Bluetooth/BluetoothSleepSupport.swift
        Sources/Vorkraft/UI/MenuPanel/MixerPercentNativeTextField.swift
        Sources/Vorkraft/UI/MenuPanel/MixerAppDragSource.swift
        Sources/Vorkraft/Services/Audio/BoostLimiter.swift
        Sources/Vorkraft/Services/Audio/MixerRender.swift
        Sources/Vorkraft/Services/Audio/PreciseVolumeRollerSupport.swift
        Sources/Vorkraft/Services/DockPreview/DockPreviewSupport.swift
        Sources/Vorkraft/Services/DockPreview/DockAutohideHold.swift
        Sources/Vorkraft/Services/Homebrew/HomebrewSupport.swift
        Sources/Vorkraft/Services/Homebrew/HomebrewEnvironment.swift
        Sources/Vorkraft/Services/AppUpdates/AppUpdatesSupport.swift
        Sources/Vorkraft/Services/AppUpdates/AppUpdateFeedSupport.swift
        Sources/Vorkraft/Core/AppUpdateStrings.swift
        Sources/Vorkraft/Core/DiskImageInstallerStrings.swift
        Sources/Vorkraft/Services/DiskImageInstaller/DiskImageInstallerSupport.swift
        Sources/Vorkraft/UI/NonModalAlert.swift
        Sources/Vorkraft/Services/Clipboard/ClipboardHistorySupport.swift
        Sources/Vorkraft/Services/Clipboard/ClipboardAutoClearSupport.swift
        Sources/Vorkraft/Services/AutoQuit/AutoQuitSupport.swift
        Sources/Vorkraft/Services/Shelf/ShelfSupport.swift
        Sources/Vorkraft/Services/Shelf/ShelfFilePromiseTransfer.swift
        Sources/Vorkraft/Core/ShelfPromiseDeliveryStrings.swift
        Sources/Vorkraft/Services/Finder/FinderRenameSupport.swift
        Sources/Vorkraft/Services/Update/UpdateInstallerSupport.swift
        Sources/Vorkraft/Services/Update/UpdateServiceSupport.swift
        Sources/Vorkraft/Services/InstalledApps.swift
        Sources/Vorkraft/Services/LaunchAtLoginSupport.swift
        Sources/Vorkraft/UI/Settings/SettingsSearchSupport.swift
        Sources/Vorkraft/UI/Settings/SettingsSidebarSupport.swift
        Sources/Vorkraft/UI/Settings/FeatureVisibilitySupport.swift
        Sources/Vorkraft/UI/Settings/SettingsWindow.swift
        Sources/Vorkraft/Core/SettingsNavigationStrings.swift
        Sources/Vorkraft/App/MenuBarSpacingSupport.swift
        Sources/Vorkraft/App/MenuBarAllowanceSupport.swift
        Sources/Vorkraft/App/StatusItemAnchorSupport.swift
        Sources/Vorkraft/Services/DockClick/DockClickSupport.swift
        Sources/Vorkraft/Services/Finder/CutPasteProgressSupport.swift
        Sources/Vorkraft/Services/Finder/CutPastePrivilegeSupport.swift
        Sources/Vorkraft/Services/Finder/FinderPasteImageSupport.swift
        Sources/Vorkraft/Services/MiddleClick/MiddleClickSupport.swift
        Sources/Vorkraft/Services/MouseNavigation/MouseNavigationSupport.swift
        Sources/Vorkraft/Services/MouseButtons/MouseButtonShortcutSupport.swift
        Sources/Vorkraft/Services/MouseButtons/MouseSpacesGestureSupport.swift
        Sources/Vorkraft/Services/MouseClickDebounce/MouseClickDebounceSupport.swift
        Sources/Vorkraft/Services/MouseExceptions/MouseAppExceptionSupport.swift
        Sources/Vorkraft/Services/MouseExceptions/MouseAppExceptions.swift
        Sources/Vorkraft/Services/WindowServerSupport.swift
        Sources/Vorkraft/Services/WindowMaximizerSupport.swift
        Sources/Vorkraft/Core/MouseButtonStrings.swift
        Sources/Vorkraft/Core/MouseClickDebounceStrings.swift
        Sources/Vorkraft/Core/MouseExceptionStrings.swift
        Sources/Vorkraft/Core/ClipboardIgnoredAppsStrings.swift
        Sources/Vorkraft/Core/WindowLayoutIgnoredAppsStrings.swift
        Sources/Vorkraft/Services/WindowLayout/WindowLayoutIgnoredApps.swift
        Sources/Vorkraft/Core/WindowPreviewExclusionStrings.swift
        Sources/Vorkraft/Core/WindowMaximizerExclusionStrings.swift
        Sources/Vorkraft/Core/DiskExclusionStrings.swift
        Sources/Vorkraft/Core/SwitcherAppRulesStrings.swift
        Sources/Vorkraft/Services/QuickTools/QuickToolsSupport.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarSupport.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarPreferences.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarMath.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarUnits.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarEmoji.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarLinks.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarDates.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarRowShortcuts.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarSystemSettingsSupport.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarFileSearchSupport.swift
        Sources/Vorkraft/Services/CommandBar/CommandBarQueryMemory.swift
        Sources/Vorkraft/Services/SpotlightNamesSupport.swift
        Sources/Vorkraft/Services/QuickTools/MicMuteSupport.swift
        Sources/Vorkraft/Services/QuickTools/QuickTogglesSupport.swift
        Sources/Vorkraft/Services/QuickTools/ScreenshotCapturePolicy.swift
        Sources/Vorkraft/Services/QuickTools/ScreenshotSupport.swift
        Sources/Vorkraft/UI/Settings/ScreenCaptureToolPicker.swift
        Sources/Vorkraft/Services/QuickTools/ScreenshotRenderer.swift
        Sources/Vorkraft/Services/QuickTools/RecentCaptureStore.swift
        Sources/Vorkraft/Services/QuickTools/ScreenshotSharingSupport.swift
        Sources/Vorkraft/Services/QuickTools/WindowActivationPolicy.swift
        Sources/Vorkraft/Services/KeyboardDebounce/KeyboardDebounceSupport.swift
        Sources/Vorkraft/Services/SuperKey/SuperKeySupport.swift
        Sources/Vorkraft/Services/SuperKey/SuperKeyMappingGuard.swift
        Sources/Vorkraft/Core/SuperKeyStrings.swift
        Sources/Vorkraft/Core/InputSourceSelection.swift
        Sources/Vorkraft/Services/SessionActivity.swift
        Sources/Vorkraft/Services/SessionActivitySupport.swift
        Sources/Vorkraft/Services/EventTimestamp.swift
        Sources/Vorkraft/Services/OwnKeyEvent.swift
        Sources/Vorkraft/Services/ScrollWheelSupport.swift
        Sources/Vorkraft/Services/HorizontalWheelScrolling.swift
        Sources/Vorkraft/Services/SmoothScrollSupport.swift
        Sources/Vorkraft/Services/MouseAcceleration/MouseAccelerationSupport.swift
        Sources/Vorkraft/Services/FocusFollowsMouse/FocusFollowsMouseSupport.swift
        Sources/Vorkraft/Services/AssistiveKeyboard.swift
        Sources/Vorkraft/Services/Switcher/SwitcherModels.swift
        Sources/Vorkraft/Services/Switcher/WindowServerCaptureQueue.swift
        Sources/Vorkraft/Services/Switcher/SwitcherSupport.swift
        Sources/Vorkraft/Services/Switcher/SpaceHopSupport.swift
        Sources/Vorkraft/Services/Switcher/WindowUseOrder.swift
        Sources/Vorkraft/Services/Metrics/MetricFormat.swift
        Sources/Vorkraft/Services/Metrics/VMStatisticsDecoder.swift
        Sources/Vorkraft/Services/KeepAwakeAutomationSupport.swift
        Sources/Vorkraft/Services/SudoersSupport.swift
        Sources/Vorkraft/Services/Metrics/BatteryTimeSupport.swift
        Sources/Vorkraft/Services/BoundedProcessRunner.swift
        Sources/Vorkraft/Services/DetachedProcess.swift
        Sources/Vorkraft/Services/ShellSupport.swift
        Sources/Vorkraft/Services/PortManager/PortManagerSupport.swift
        Sources/Vorkraft/Services/Metrics/NetworkProcessSupport.swift
        Sources/Vorkraft/Services/Metrics/NetworkSampler.swift
        Sources/Vorkraft/Services/Metrics/NetworkAddressService.swift
        Sources/Vorkraft/Services/Metrics/SpeedTest.swift
        Sources/Vorkraft/Services/Metrics/PeripheralBatterySampler.swift
        Sources/Vorkraft/Services/Metrics/PeripheralBatterySupport.swift
        Sources/Vorkraft/Services/Metrics/DiskSupport.swift
        Sources/Vorkraft/Services/Metrics/MonitorSamplingPolicy.swift
        Sources/Vorkraft/Services/Metrics/USBDeviceSampler.swift
        Sources/Vorkraft/Services/Metrics/MaxCapacityProbe.swift
        Sources/Vorkraft/Services/Metrics/TemperatureSensorSelector.swift
        Sources/Vorkraft/Services/Metrics/SustainedAlertGate.swift
        Sources/Vorkraft/Services/WindowLayout/WindowLayoutSupport.swift
        Sources/Vorkraft/Services/WindowLayout/WindowGestureSupport.swift
        Sources/Vorkraft/Core/WindowDirectionalStrings.swift
        Sources/Vorkraft/Core/PointerDisplayStrings.swift
        Sources/Vorkraft/Services/CleaningMode/CleaningUnlockCounter.swift
        Sources/Vorkraft/Services/CleaningMode/CleaningMouseReleaseGate.swift
        Sources/Vorkraft/Services/Display/ExtraBrightnessSupport.swift
        Sources/Vorkraft/Services/Display/BrightnessSupport.swift
        Sources/Vorkraft/Services/Display/LidDimmingSupport.swift
        Sources/Vorkraft/Services/Cleaner/CleanerSupport.swift
        Sources/Vorkraft/Services/Cleaner/CleanerPolicy.swift
        Sources/Vorkraft/Services/Cleaner/CleanerSchedule.swift
        Sources/Vorkraft/Services/Uninstall/UninstallerSupport.swift
        Sources/Vorkraft/Services/ManagedDownloads/WhatsAppDownloadSupport.swift
        Sources/Vorkraft/Core/SecureInputSupport.swift
        Tests/*.swift
        build/generated-tests/*.swift
    )
    TEST_OUTPUT_FILE_MAP="$TEST_OBJECT_DIR/output-file-map.json"
    write_swift_output_file_map "$TEST_OUTPUT_FILE_MAP" "$TEST_OBJECT_DIR" "${TEST_SOURCES[@]}"
    echo "▸ Building & running tests against $(basename "$SDK")…"
    swiftc -Onone -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
        -module-name VorkraftTests -output-file-map "$TEST_OUTPUT_FILE_MAP" \
        -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" \
        "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${TEST_SOURCES[@]}" -o build/metrics-tests
    test_status=0
    ./build/metrics-tests "${TEST_ARGS[@]}" || test_status=$?
    if (( ${#TEST_ARGS} == 0 )); then
        ./Tests/PreferenceCleanupTests.sh || test_status=1
    fi
    discard_test_preferences || test_status=1
    exit $test_status
fi

echo "▸ Compiling ($BUILD_CONFIGURATION) against $(basename "$SDK")…"
APP_SOURCES=(Sources/Vorkraft/**/*.swift)
if (( ! DEV )); then
    # A release starts from an empty build directory, so nothing an earlier
    # build left behind (an old icon catalog, a staged bundle) can reach it.
    # Only the compiler's incremental records stay: they rebuild whatever
    # changed since, and a fresh checkout has none.
    find build -mindepth 1 -maxdepth 1 ! -name objects -exec rm -rf {} + 2>/dev/null || true
fi
APP_OBJECT_DIR="build/objects/$EXECUTABLE"
mkdir -p build "$APP_OBJECT_DIR"
APP_OUTPUT_FILE_MAP="$APP_OBJECT_DIR/output-file-map.json"
write_swift_output_file_map "$APP_OUTPUT_FILE_MAP" "$APP_OBJECT_DIR" "${APP_SOURCES[@]}"
# Without -j the driver compiles one file at a time, and without batch mode
# each file's compiler parses the whole module again: a clean release took a
# quarter of an hour. Batches share that work and run on every core, and the
# optimization stays per file, as before.
swiftc "${APP_OPTIMIZATION_FLAGS[@]}" -incremental -enable-batch-mode -j "$(sysctl -n hw.logicalcpu)" \
    -output-file-map "$APP_OUTPUT_FILE_MAP" \
    -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${VM_STATISTICS_COMPAT_FLAGS[@]}" "${HID_EVENT_SYSTEM_FLAGS[@]}" \
    "${BUILD_VARIANT_FLAGS[@]}" \
    "${APP_SOURCES[@]}" -o "build/$EXECUTABLE"

echo "▸ Compiling protected fan helper…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" "${BUILD_VARIANT_FLAGS[@]}" \
    Sources/Vorkraft/Services/FanControl/FanControlSupport.swift \
    Sources/Vorkraft/Services/FanControl/FanControlXPC.swift \
    Sources/Vorkraft/Services/SystemMonitor/SMCClient.swift \
    Sources/Vorkraft/Services/Metrics/TemperatureSensorSelector.swift \
    Sources/Vorkraft/Services/FanControl/FanControlHardware.swift \
    Sources/FanControlHelper/main.swift \
    -o "build/$FAN_HELPER_ID"
"build/$FAN_HELPER_ID" --selftest

echo "▸ Compiling Now Playing adapter…"
swiftc -O -target "$TARGET" -sdk "$SDK" "${SDK_COMPAT_FLAGS[@]}" -emit-library \
    -module-name VorkraftNowPlaying \
    Sources/NowPlayingAdapter/NowPlayingAdapter.swift \
    Sources/NowPlayingAdapter/NowPlayingQueue.swift \
    Sources/NowPlayingAdapter/NowPlayingSelection.swift \
    Sources/Vorkraft/Services/Notch/NotchPlaybackSource.swift \
    Sources/Vorkraft/Services/Notch/NotchPlaybackCommand.swift \
    -o "build/$NOW_PLAYING_ADAPTER"

echo "▸ Generating app icon…"
swift Tools/MakeIcon.swift build/AppIcon.iconset
xattr -c -r build/AppIcon.iconset build/AppIcon.icns build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png 2>/dev/null || true
# Vorkraft uses its own generated icon; never bundle the upstream adaptive catalog.
echo "▸ Assembling and signing bundle…"
STAGE_TMP="$(mktemp -d)"
STAGE="$STAGE_TMP/$APP_NAME.app"
mkdir -p "$STAGE/Contents/MacOS" "$STAGE/Contents/Resources" \
    "$STAGE/Contents/Library/LaunchDaemons" "$STAGE/Contents/Library/LaunchServices"
cp "build/$EXECUTABLE" "$STAGE/Contents/MacOS/$EXECUTABLE"
cp "build/$FAN_HELPER_ID" "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID"
mkdir -p "$STAGE/Contents/Frameworks"
cp "build/$NOW_PLAYING_ADAPTER" "$STAGE/Contents/Frameworks/$NOW_PLAYING_ADAPTER"
cp Resources/now-playing.pl "$STAGE/Contents/Resources/now-playing.pl"
cp Resources/agent-prices.json "$STAGE/Contents/Resources/agent-prices.json"
cp Resources/com.veloraapplabs.vorkraft.fan-control.plist \
    "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
cp Resources/Info.plist "$STAGE/Contents/Info.plist"
python3 Tools/stamp-source-revisions.py "$STAGE/Contents/Info.plist"
cp VORKRAFT_CHANGELOG.md "$STAGE/Contents/Resources/CHANGELOG.md"
for lproj in Resources/*.lproj(N); do
    cp -R "$lproj" "$STAGE/Contents/Resources/"
done
if (( DEV )); then
    # A distinct identity so the Developer build installs and runs next to the
    # official app, with its own permissions, preferences and login item.
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $APP_BUNDLE_ID" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $APP_NAME" "$STAGE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXECUTABLE" "$STAGE/Contents/Info.plist"
    FAN_PLIST="$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist"
    /usr/libexec/PlistBuddy -c "Set :Label $FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Set :BundleProgram Contents/Library/LaunchServices/$FAN_HELPER_ID" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Delete :MachServices:com.veloraapplabs.vorkraft.fan-control" "$FAN_PLIST"
    /usr/libexec/PlistBuddy -c "Add :MachServices:$FAN_HELPER_ID bool true" "$FAN_PLIST"
    # Stamp the source commit + build time so the running dev app shows (in About)
    # exactly which code it was compiled from. Lets you verify it matches HEAD before
    # testing, instead of unknowingly running a stale build. Dev-only; never shipped.
    SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
    [[ -n "$(git status --porcelain 2>/dev/null)" ]] && SHA="$SHA-dirty"
    /usr/libexec/PlistBuddy -c "Add :VorkraftBuildCommit string '$SHA · $(date '+%Y-%m-%d %H:%M')'" "$STAGE/Contents/Info.plist"
    echo "  stamped dev build: $SHA"
fi
FAN_HELPER_VERSION="$(
    export LC_ALL=C
    /usr/bin/shasum -a 256 \
        "$STAGE/Contents/Library/LaunchServices/$FAN_HELPER_ID" \
        "$STAGE/Contents/Library/LaunchDaemons/$FAN_HELPER_ID.plist" \
        | /usr/bin/awk '{print $1}' | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
)"
/usr/libexec/PlistBuddy -c "Add :VorkraftFanControlHelperVersion string '$FAN_HELPER_VERSION'" \
    "$STAGE/Contents/Info.plist"
printf 'APPL????' > "$STAGE/Contents/PkgInfo"
cp build/AppIcon.icns "$STAGE/Contents/Resources/AppIcon.icns"
cp build/MenuBarIcon.png build/MenuBarIcon@2x.png build/BrandMark.png "$STAGE/Contents/Resources/"
if [[ -f build/Assets.car ]]; then
    cp build/Assets.car "$STAGE/Contents/Resources/Assets.car"
fi
if [[ -d Resources/Gifs ]]; then
    mkdir -p "$STAGE/Contents/Resources/Gifs"
    cp Resources/Gifs/*.gif "$STAGE/Contents/Resources/Gifs/"
fi
if ! cmp -s Resources/Gifs/highlights-notch.gif "$STAGE/Contents/Resources/Gifs/highlights-notch.gif"; then
    echo "Dynamic Island tour GIF is missing or differs from the bundled copy" >&2
    exit 1
fi
if [[ -d Resources/Images ]]; then
    mkdir -p "$STAGE/Contents/Resources/Images"
    cp Resources/Images/* "$STAGE/Contents/Resources/Images/"
fi
xattr -c -r "$STAGE" 2>/dev/null || true

# Signing, in order of preference:
#   1. Developer ID Application — the real, Apple-issued identity used for
#      notarized releases. Signed with the hardened runtime (required for
#      notarization), the app's entitlements and a secure timestamp. Gives a
#      stable, team-based designated requirement, so permissions persist across
#      updates AND Gatekeeper shows no "unverified developer" warning.
#   2. "Vorkraft Utils Signing" — the legacy stable self-signed identity, kept
#      as a fallback so contributors without a Developer ID still get a constant
#      designated requirement across their local builds.
#   3. Ad-hoc — fresh clone with no identity at all.
DEVID="$(developer_id_identity)"
codesign_app() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --entitlements "$ENTITLEMENTS" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --sign - "$target"
    fi
}

codesign_fan_helper() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$FAN_HELPER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$FAN_HELPER_ID" --sign - "$target"
    fi
}

codesign_now_playing_adapter() {
    local target="$1"
    if [[ -n "$DEVID" ]]; then
        codesign_with_timestamp_retry --force --strip-disallowed-xattrs --options runtime --timestamp \
            --identifier "$NOW_PLAYING_ADAPTER_ID" --sign "$DEVID" "$target"
    elif legacy_identity_installed; then
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" \
            --sign "$LEGACY_IDENTITY" "$target"
    else
        codesign --force --strip-disallowed-xattrs --identifier "$NOW_PLAYING_ADAPTER_ID" --sign - "$target"
    fi
}

sign_bundle() {
    local bundle="$1"
    local executable="$bundle/Contents/MacOS/$EXECUTABLE"
    local helper="$bundle/Contents/Library/LaunchServices/$FAN_HELPER_ID"
    local adapter="$bundle/Contents/Frameworks/$NOW_PLAYING_ADAPTER"

    if [[ -n "$DEVID" ]]; then
        echo "  signing with Developer ID (hardened runtime): $DEVID"
    elif legacy_identity_installed; then
        echo "  signing with legacy self-signed identity: $LEGACY_IDENTITY"
    else
        echo "  signing ad-hoc (no identity installed — run Tools/setup-signing.sh)"
    fi
    [[ -f "$helper" ]] && codesign_fan_helper "$helper"
    [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
    codesign_app "$bundle"

    # If local filesystem metadata invalidates the first signature, sign once
    # more. The installed Developer bundle is signed again after the final copy.
    if ! codesign --verify --deep --strict "$bundle" >/dev/null 2>&1; then
        echo "  re-signing after filesystem metadata settled"
        xattr -c -r "$bundle" 2>/dev/null || true
        [[ -f "$helper" ]] && codesign_fan_helper "$helper"
        [[ -f "$adapter" ]] && codesign_now_playing_adapter "$adapter"
        codesign_app "$bundle"
    fi
    [[ -f "$executable" ]] && codesign --verify --strict "$executable"
    [[ -f "$helper" ]] && codesign --verify --strict "$helper"
    [[ -f "$adapter" ]] && codesign --verify --strict "$adapter"
    codesign --verify --deep --strict "$bundle"
}

sign_installed_bundle() {
    local bundle="$1"
    wait_for_install_metadata "$bundle"
    sign_bundle "$bundle"
}

sign_bundle "$STAGE"

process_is_running() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pgrep -f "/Contents/MacOS/$proc" >/dev/null 2>&1
    else
        pgrep -x "$proc" >/dev/null 2>&1
    fi
}

stop_process() {
    local proc="$1"
    if (( ${#proc} > 15 )); then
        pkill -f "/Contents/MacOS/$proc" 2>/dev/null || true
    else
        pkill -x "$proc" 2>/dev/null || true
    fi
    for _ in {1..50}; do
        if ! process_is_running "$proc"; then
            return 0
        fi
        sleep 0.1
    done
    echo "✗ $proc is still running — quit it and retry" >&2
    return 1
}

wait_for_install_metadata() {
    local bundle="$1"
    local missing
    for _ in {1..50}; do
        missing=0
        while IFS= read -r file; do
            if ! xattr -p com.apple.provenance "$file" >/dev/null 2>&1; then
                missing=1
                break
            fi
        done < <(find "$bundle/Contents" -type f ! -path "*/_CodeSignature/*")
        if (( missing == 0 )); then
            return 0
        fi
        sleep 0.1
    done
}

# Installed development builds only need the copy in /Applications. Retaining
# another app in each checkout pollutes application search with stale builds.
if (( DEV )); then
    for old_bundle in "build/stage/$APP_NAME.app" "build/stage.noindex/$APP_NAME.app"; do
        if [[ -d "$old_bundle" ]]; then
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
                -u "$PWD/$old_bundle" >/dev/null 2>&1 || true
            rm -rf "$old_bundle"
        fi
    done
fi

if (( !DEV || !INSTALL )); then
    STAGE_DIRECTORY="build/stage"
    (( DEV )) && STAGE_DIRECTORY="build/stage.noindex"
    mkdir -p "$STAGE_DIRECTORY"
    BUILD_STAGE="$STAGE_DIRECTORY/$APP_NAME.app"
    rm -rf "$BUILD_STAGE"
    ditto --noextattr --noqtn "$STAGE" "$BUILD_STAGE"
    xattr -c -r "$BUILD_STAGE" 2>/dev/null || true
    if ! codesign --verify --deep --strict "$BUILD_STAGE" >/dev/null 2>&1; then
        if xattr -lr "$BUILD_STAGE" 2>/dev/null | grep -Eq 'com\.apple\.(FinderInfo|ResourceFork|provenance|fileprovider)'; then
            echo "  staging copy has local filesystem metadata; temp bundle was verified"
        else
            codesign --verify --deep --strict "$BUILD_STAGE"
        fi
    fi
    echo "✓ Bundle ready: $BUILD_STAGE"
fi

if (( INSTALL )); then
    echo "▸ Installing into /Applications…"
    stop_process "$EXECUTABLE"
    INSTALL_DEST="/Applications/$APP_NAME.app"
    rm -rf "$INSTALL_DEST"
    ditto --noextattr --noqtn "$STAGE" "$INSTALL_DEST"
    sign_installed_bundle "$INSTALL_DEST"
    echo "✓ Installed: $INSTALL_DEST"
fi
