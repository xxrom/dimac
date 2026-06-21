# Attribution

Dimac relies on the following external tools and platform components:

- `m1ddc` for DDC-based control of supported external displays
- `brightness` for hardware brightness discovery and CLI fallback control
- Apple's private `DisplayServices.framework` for built-in display brightness access

`m1ddc` and `brightness` are not bundled in this repository. Users install them separately and should review their own licenses and redistribution terms when packaging Dimac for others.
