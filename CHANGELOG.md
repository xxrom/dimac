# Changelog

## Unreleased

- No changes yet.

## 0.1.4 - 2026-11-15

- Fixed a "Dimac" tooltip that could stay stuck on screen until the menu bar icon was clicked. The icon no longer has a tooltip.
- Dimming never raises a display above the level it reads back. Monitors without brightness readback are still dimmed from the last level set in Dimac.
- A monitor unplugged or unreachable while dimmed no longer keeps the app in a "dimmed" state with endless retries; it is restored when it reconnects.
- When no display can be dimmed, Dimac waits a minute before trying again instead of launching `m1ddc` every few seconds.
- Fixed a second, stray popup that could appear when the menu bar icon was clicked while the popup was closing, and ignored reopen requests in the first seconds after launch.
- The timeout stepper no longer jumps from one minute to one second, and "0" or negative timeouts are rejected.
- Copy, paste and typing now work in the popup and settings window; the settings window sizes itself to its content.
- Launch at login shows when macOS approval is needed and opens Login Items to grant it.
- A helper tool that hangs can no longer block the app beyond its timeout, and a failed `m1ddc display list` is reported instead of being read as "no monitors".
- 0% is never saved as a monitor's normal brightness.
- A corrupt saved dim snapshot is set aside and reported instead of being silently ignored; one bad per-display setting no longer erases the others.
- Helper tool paths with stray spaces work; diagnostic log cleanup survives a damaged log line; local builds are stamped with their git revision.

## 0.1.3 - 2026-10-28

- Much lower idle CPU use: diagnostic log cleanup no longer rereads the whole log on every write, idle checks sleep until the timeout could elapse, and mouse movement is ignored unless dimmed.
- The settings window is released when closed, and the idle timer only updates while the UI is visible.
- Diagnostic logging is now an opt-in Advanced setting, off by default. Turning it off deletes the log files.

## 0.1.2 - 2026-10-25

- Redesigned popup: glass cards per display, full-width capsule sliders, colour-coded Advanced groups (Timing, System, Tools, Info).
- External monitor brightness is now saved per display and restored reliably after reconnecting or waking, with automatic retries and verification.
- Fixed an empty "Dimac" window that could appear.
- Advanced opens instantly; displays are rescanned every time the popup opens.

## 0.1.0 - 2026-06-21

First public source release.

- Menu bar app for Apple Silicon Macs that dims displays after inactivity and restores brightness on activity.
- Built-in display support through `DisplayServices.framework`, with `brightness` as the current CLI fallback and discovery helper.
- External display support through `m1ddc` for DDC-capable monitors.
- Per-display bright and dim preferences, plus cleaner Advanced settings and helper-path overrides.
- Open-source repo surface prepared with installation, privacy, contributing, security, and release documentation.
