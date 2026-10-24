# Privacy

Dimac is a local macOS utility. It does not ship with analytics, telemetry, or network reporting.

## What The App Observes

- idle time from the local machine
- input activity events needed to restore brightness quickly
- connected display information needed to map per-display settings

Dimac uses activity signals only. It does not record key contents, mouse coordinates, or typed text.

## What The App Stores

- user preferences in `UserDefaults`
- the active brightness snapshot in `~/Library/Application Support/Dimac/active-snapshot.json`
- diagnostic logs in `~/Library/Logs/Dimac/diagnostics.jsonl` and two rotated files, limited to the latest five hours and about 15 MB total; expired entries are removed when logging runs, including on relaunch/wake (cleanup cannot run while the app is closed or the Mac is asleep)

The snapshot is used only to restore brightness after dimming or restart recovery.

Diagnostic logs include timestamps, process/session identifiers, display names and UUIDs, brightness requests and readings, idle-time observations, restore decisions, snapshot contents, helper paths/output, and app lifecycle events. They stay on this Mac and do not contain keystrokes, typed text, or mouse positions. They can be deleted after troubleshooting; logging recreates them while the app runs.

## What The App Shares

Nothing by default. Dimac does not include a backend service and does not send usage data off-device.
