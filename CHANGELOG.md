# Changelog

## Unreleased

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
