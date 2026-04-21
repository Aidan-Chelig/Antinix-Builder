# Examples

- `minimal`: smallest runnable VM example, serial-only, `busybox` + `none`
- `basic`: normal service-oriented VM example, graphical + serial login, `openrc` + `xbps`
- `graphical`: graphical VM example built from `lib.profiles.graphical.labwcVm`

Run an example from the repo root with:

```bash
nix run ./examples/minimal
nix run ./examples/basic
nix run ./examples/graphical
```
