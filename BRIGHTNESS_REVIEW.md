# Brightness review — 2026-09-10

The reported stale restore was confirmed. AppModel captured a snapshot with hardware writes disabled, then applied persisted `normalPercent` values when activity resumed. Refresh and startup also applied those values. Separately, DimmerController replaced captured external brightness with configured preferences during hardware restoration.

## Changes

- One controller now owns snapshot, dim, and restore for manual actions, idle/activity, disable, sleep, wake, and quit. Display refresh only discovers displays.
- Actual brightness is captured immediately before dimming. Each dim target is capped at the captured value, including zero brightness.
- Settings store only dim targets. Legacy `normalPercent` fields are ignored. The new “Now” slider reads and adjusts current brightness directly, while “Dim” changes apply on the next idle cycle. Manual adjustments finish any active dim cycle before writing, so subsequent activity cannot undo the choice.
- Repeated dim calls retain the original snapshot. Displays without readable brightness are dimmed only after a successful manual app setting establishes a session baseline.
- Restore checks for brightness changes since dimming, preserving observable manual changes. Failed restores retain recovery data.
- CLI brightness uses display IDs and resolves current indexes before targeted writes. A disconnected display does not cause a write to another screen.
- Built-in DisplayServices bindings use integer return codes with zero indicating success. The previous Bool binding inverted success handling.
- Timeout input handles compound units and overflow and preserves seconds when formatted.

The DisplayServices correction is supported by the helper's [declarations](https://github.com/nriley/brightness/blob/master/brightness.c#L41-L46) and its [zero-success checks](https://github.com/nriley/brightness/blob/master/brightness.c#L111-L118). The helper documents indexed display output in its [usage examples](https://github.com/nriley/brightness#usage-examples).

## Regression coverage

Tests cover live restoration despite stale config, independent dim targets, already-dark screens, manual changes while dimmed, repeated dim requests, failed restoration, unreadable displays, CLI display reordering, disconnected/legacy display IDs, primary/CLI routing, app-level manual actions, deferred config changes, legacy settings migration, and timeout parsing.

## Local validation

- `swift build --disable-sandbox`: passed using temporary writable compiler caches.
- Eight standalone smoke scenarios linked against the built DimacCore code: passed (live restore, already-dark screen, manual override, repeated dim, retry, disable, restart/manual override, restart/restore).
- Five additional live-control integration scenarios linked against the built app/core code: passed (manual level becomes the next restore level without persisting it, adjustment during dimming, failed writes, DDC selector changes/ambiguous identity, and manual control when brightness reads fail).
- `git diff --check`: passed.
- `zsh scripts/test.sh`: blocked because the selected Command Line Tools installation lacks XCTest. The full regression suite must run with Xcode or in macOS CI.
- No brightness writes to physical monitors and no replacement of the installed application were performed.

## Physical checks still needed

Automated mocks cannot prove every monitor's DDC timing or macOS brightness-key ordering. Before replacing an installed app, check:

1. Set brightness with macOS or the monitor's controls, wait for idle dimming, then move the mouse. Repeat with a different starting brightness.
2. Change brightness while dimmed using a brightness key or monitor controls; verify the user-selected value survives activity.
3. Start below the configured dim target, including zero; idle must not brighten the screen.
4. Dim multiple screens, unplug one, restore, then reconnect it. Verify the other screens restore and that recovery targets the correct screen.
5. Exercise disable, sleep/wake, quit/relaunch, and helper failure during a dim cycle.
6. Check a CLI-controlled external Apple display and a DDC monitor together, including different dim targets.

## Remaining limitations and follow-ups

- DDC identity currently relies on a unique display name, not serial number/UUID. Anonymous or duplicate-name DDC displays need a stable identity implementation before they can be safely controlled. Replacing a display with another of the same name remains ambiguous.
- Manual brightness changes are inferred from observable values. A change equal to the dim target cannot be distinguished; read failures or brightness-key event ordering can also limit detection. Hardware readback/notification support would improve this.
- Legacy recovery snapshots may lack display identity or applied-target metadata. The original state cannot always be safely reconstructed from those files.
- If storage fails while reducing a partially restored snapshot, memory keeps only pending entries but the disk may retain older recovery data. A subsequent crash can therefore recover from outdated data.
- Helper commands run synchronously on the main actor. Slow or unavailable DDC monitors can delay the UI and restoration. A serialized asynchronous hardware worker is a useful next improvement.
- Screen preferences use CoreGraphics display IDs; stable hardware IDs would improve preference continuity across reconfiguration.
- The settings dictionary currently decodes as one unit. Per-entry recovery could preserve valid preferences if one stored entry is corrupted.

## External-control follow-up

The initial “Now” slider incorrectly required a successful brightness read before enabling manual writes. The connected MSI PS341WU was discoverable, but its DDC brightness-read command returned no value. Manual controls now remain enabled for matched displays even when reading fails; the UI distinguishes the last requested value from a confirmed reading. Automatic idle dimming now accepts the last successful manual app setting as a session baseline when live reads fail. Live reads take priority; failed manual writes never replace the baseline. Observed disconnection clears it, and it is not loaded from configuration after restart. An active dim snapshot remains recoverable after restart.


## TDD follow-up: write-capable monitors without read support

The earlier tests covered manual writes and skipped unreadable monitors separately, missing their combined idle/wake flow. The new app-level regression failed before the fix (43 remained 43 instead of dimming to 10). A second regression failed before disconnect invalidation was added.

The checked-in `scripts/test-clt.py` executes the actual synchronous test methods with assertion helpers, linking built production objects. All 48 scenarios pass on this CLT-only Mac. Full XCTest still requires Xcode. Coverage includes mixed internal/external cycles, 0/5/43/100 starting levels, independent targets, unknown baselines, live-read precedence, unsuccessful writes, adjustment during dimming, retry, restart recovery, disconnection, ambiguity, routing, and configuration behavior.

For a monitor without read support, successful writes are assumed to have applied. Physical monitor-button changes and disconnects missed between discovery calls cannot be detected. Hardware validation remains necessary.
