{
  pkgs,
  schema,
  merge,
}:

let
  runtime = pkgs.callPackage ./runtime.nix {
    inherit schema merge;
  };

  sessions = pkgs.callPackage ./sessions.nix {
    inherit schema merge;
  };

  vm = pkgs.callPackage ./vm.nix {
    inherit
      merge
      runtime
      ;
  };
in
{
  ##@ name: runtime
  ##@ path: lib.profiles.runtime
  ##@ kind: module
  ##@ summary: Reusable runtime fragments such as udev and graphical base config.
  ##@ returns: Attrset exposing runtime-oriented profile helpers.
  runtime = runtime;

  ##@ name: sessions
  ##@ path: lib.profiles.sessions
  ##@ kind: module
  ##@ summary: Reusable session fragments for runtime directories, tty autologin, and shell launch hooks.
  ##@ returns: Attrset exposing session-oriented profile helpers.
  sessions = sessions;

  ##@ name: graphical
  ##@ path: lib.profiles.graphical
  ##@ kind: module
  ##@ summary: Higher-level graphical session profiles built from the runtime and session helpers.
  ##@ returns: Attrset exposing graphical profile helpers such as labwcVm.
  graphical = pkgs.callPackage ./graphical.nix {
    inherit
      schema
      merge
      runtime
      sessions
      ;
  };

  ##@ name: vm
  ##@ path: lib.profiles.vm
  ##@ kind: module
  ##@ summary: Guest-side virtualization profiles for QEMU-oriented system defaults.
  ##@ returns: Attrset exposing VM-oriented profile helpers such as qemuGuest.
  vm = vm;
}
