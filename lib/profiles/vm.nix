{ lib, merge, runtime }:

let
  maybe = enabled: fragment: if enabled then [ fragment ] else [ ];
in
rec {
  ##@ name: qemuGuest
  ##@ path: lib.profiles.vm.qemuGuest
  ##@ kind: function
  ##@ summary: Add guest-side QEMU defaults for console behavior, input module loading, and optional udev boot services.
  ##@ param: graphics bool? Enable graphical guest console defaults such as tty1, VT switching, and input module loading.
  ##@ param: serialConsole bool? Enable the serial getty on the primary console.
  ##@ param: graphicalTty string? TTY used for the graphical getty when graphics are enabled.
  ##@ param: loadInputModules bool? Load common QEMU graphics/input kernel modules during boot.
  ##@ param: switchToGraphicalVt bool? Switch to the configured graphical VT during boot.
  ##@ param: enableUdev bool? Add boot-time udev and coldplug services.
  ##@ param: descriptionPrefix string? Prefix used in generated udev service descriptions.
  ##@ returns: Fragment that composes vmConsole guest defaults and optional runtime.udev support for QEMU guests.
  ##@ example: antinixLib.profiles.vm.qemuGuest { graphics = true; enableUdev = true; }
  qemuGuest =
    {
      graphics ? true,
      serialConsole ? true,
      graphicalTty ? "tty1",
      loadInputModules ? graphics,
      switchToGraphicalVt ? graphics,
      enableUdev ? graphics,
      descriptionPrefix ? "QEMU guest",
    }:
    merge.mergeMany (
      [
        {
          vmConsole = {
            serialGetty.enable = serialConsole;
            graphicalGetty = {
              enable = graphics;
              tty = graphicalTty;
            };
            loadInputModules.enable = loadInputModules;
            switchToGraphicalVt = {
              enable = switchToGraphicalVt;
              target = graphicalTty;
            };
          };
        }
      ]
      ++ maybe enableUdev (runtime.udev {
        inherit descriptionPrefix;
      })
    );
}
