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

The snapshot is used only to restore brightness after dimming or restart recovery.

## What The App Shares

Nothing by default. Dimac does not include a backend service and does not send usage data off-device.
