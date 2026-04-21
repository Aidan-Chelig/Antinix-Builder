# Examples

- `minimal`: smallest runnable VM example, serial-only, `busybox` + `none`
- `basic`: normal service-oriented VM example, graphical + serial login, `openrc` + `xbps`
- `graphical`: graphical VM example with `labwc`, `foot`, `seatd`, and `dbus-run-session`

Run an example from the repo root with:

```bash
nix run ./examples/minimal
nix run ./examples/basic
nix run ./examples/graphical
```
