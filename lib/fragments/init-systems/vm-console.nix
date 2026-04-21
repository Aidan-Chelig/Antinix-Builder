{ lib, pkgs }:

let
  defaultInputModules = [
    "virtio_gpu"
    "drm"
    "drm_kms_helper"
    "i8042"
    "atkbd"
    "psmouse"
    "evdev"
    "xhci_pci"
    "xhci_hcd"
    "usbhid"
    "hid_generic"
  ];
in
rec {
  normalize =
    {
      console,
      vmConsole ? { },
    }:
    let
      rootEnabled = if vmConsole ? enable then vmConsole.enable else true;

      serialOverride = vmConsole.serialGetty or { };
      graphicalOverride = vmConsole.graphicalGetty or { };
      switchOverride = vmConsole.switchToGraphicalVt or { };
      loadOverride = vmConsole.loadInputModules or { };

      serialGetty = {
        enable = if serialOverride ? enable then serialOverride.enable else rootEnabled;
        tty = if serialOverride ? tty then serialOverride.tty else console;
        baud = toString (if serialOverride ? baud then serialOverride.baud else 115200);
        term = if serialOverride ? term then serialOverride.term else "vt100";
        loginProgram =
          if serialOverride ? loginProgram then serialOverride.loginProgram else "/usr/bin/login";
        autologinUser =
          if serialOverride ? autologinUser then serialOverride.autologinUser else null;
        local = if serialOverride ? local then serialOverride.local else true;
      };

      graphicalGetty = {
        enable =
          if graphicalOverride ? enable then
            graphicalOverride.enable
          else
            rootEnabled && serialGetty.tty != (if graphicalOverride ? tty then graphicalOverride.tty else "tty1");
        tty = if graphicalOverride ? tty then graphicalOverride.tty else "tty1";
        baud = toString (if graphicalOverride ? baud then graphicalOverride.baud else 115200);
        term = if graphicalOverride ? term then graphicalOverride.term else "linux";
        loginProgram =
          if graphicalOverride ? loginProgram then graphicalOverride.loginProgram else "/usr/bin/login";
        autologinUser =
          if graphicalOverride ? autologinUser then graphicalOverride.autologinUser else null;
        local = if graphicalOverride ? local then graphicalOverride.local else false;
      };

      switchToGraphicalVt = {
        enable =
          if switchOverride ? enable then switchOverride.enable else graphicalGetty.enable;
        target = if switchOverride ? target then switchOverride.target else graphicalGetty.tty;
      };

      loadInputModules = {
        enable = if loadOverride ? enable then loadOverride.enable else rootEnabled;
        modules = if loadOverride ? modules then loadOverride.modules else defaultInputModules;
      };
    in
    if serialGetty.enable && graphicalGetty.enable && serialGetty.tty == graphicalGetty.tty then
      throw "vmConsole: serialGetty.tty and graphicalGetty.tty must differ when both gettys are enabled"
    else
      {
        inherit
          rootEnabled
          serialGetty
          graphicalGetty
          switchToGraphicalVt
          loadInputModules
          ;

        packages =
          lib.optionals loadInputModules.enable [ pkgs.kmod ]
          ++ lib.optionals switchToGraphicalVt.enable [ pkgs.kbd ];
      };

  gettyCommand =
    spec:
    let
      localFlag = lib.optionalString spec.local "-L ";
      autologinFlag = lib.optionalString (spec.autologinUser != null) "--autologin ${spec.autologinUser} ";
    in
    "/usr/bin/agetty ${localFlag}${autologinFlag}${spec.baud} ${spec.tty} ${spec.term} -l ${spec.loginProgram}";

  gettyOptions =
    spec:
    lib.concatStringsSep " " (
      lib.optional spec.local "-L"
      ++ lib.optional (spec.autologinUser != null) "--autologin ${spec.autologinUser}"
      ++ [ "-l ${spec.loginProgram}" ]
    );

  mountHelpers = ''
    is_mounted() {
      grep -qs " $1 " /proc/mounts
    }
  '';

  mountCommands = ''
    is_mounted /proc || mount -t proc proc /proc || true
    is_mounted /sys || mount -t sysfs sysfs /sys || true
    is_mounted /dev || mount -t devtmpfs devtmpfs /dev || true
    is_mounted /run || mount -t tmpfs tmpfs /run || true
  '';

  loadInputDrivers =
    cfg:
    lib.optionalString cfg.loadInputModules.enable ''
      for mod in ${lib.concatStringsSep " " cfg.loadInputModules.modules}; do
        modprobe "$mod" >/dev/null 2>&1 || true
      done
    '';

  switchToGraphicalVt =
    cfg:
    lib.optionalString cfg.switchToGraphicalVt.enable ''
      target_vt="${cfg.switchToGraphicalVt.target}"
      case "$target_vt" in
        tty[0-9]*) target_vt="''${target_vt#tty}" ;;
      esac
      /usr/bin/chvt "$target_vt" >/dev/null 2>&1 || true
    '';
}
