{ lib }:

let
  allowedServiceKeys = [
    "enable"
    "description"
    "command"
    "environment"
    "dependsOn"
    "wantedBy"
    "runAs"
    "oneShot"
    "restart"
    "init"
  ];

  supportedWantedBy = [ "default" ];
  supportedInitNames = [
    "busybox"
    "dinit"
    "openrc"
    "runit"
    "s6"
    "simple"
  ];

  defaultService =
    service:
    let
      oneShot = service.oneShot or false;
    in
    {
      enable = true;
      description = null;
      command = null;
      environment = { };
      dependsOn = [ ];
      wantedBy = [ "default" ];
      runAs = "root";
      inherit oneShot;
      restart = if oneShot then "none" else "always";
      init = { };
    };

  forceChecks = checks: value: lib.foldl' (acc: check: builtins.seq check acc) value checks;

  unknownKeys =
    allowed: attrs:
    builtins.filter (key: !(builtins.elem key allowed)) (builtins.attrNames attrs);

  throwUnknownKeys =
    prefix: allowed: attrs:
    let
      extras = unknownKeys allowed attrs;
    in
    if extras == [ ] then
      null
    else
      throw "${prefix}: unsupported keys: ${lib.concatStringsSep ", " extras}";

  normalizeCommand =
    name: command:
    if command == null then
      null
    else if builtins.isList command then
      map builtins.toString command
    else
      throw "services.${name}.command must be a list of command arguments";

  normalizeService =
    name: service:
    let
      _ = if !(builtins.isAttrs service) then throw "services.${name} must be an attrset" else null;
      _name =
        if builtins.match "^[A-Za-z0-9][A-Za-z0-9@._-]*$" name != null then
          null
        else
          throw "services.${name}: service names must match ^[A-Za-z0-9][A-Za-z0-9@._-]*$";
      _unknown = throwUnknownKeys "services.${name}" allowedServiceKeys service;
      merged = (defaultService service) // service;
      _command =
        if merged.enable && merged.command == null then
          throw "services.${name}.command is required when the service is enabled"
        else
          null;
      _restart =
        if builtins.elem merged.restart [
          "none"
          "on-failure"
          "always"
        ] then
          null
        else
          throw "services.${name}.restart must be one of none, on-failure, or always";
      _init =
        if !(builtins.isAttrs merged.init) then
          throw "services.${name}.init must be an attrset"
        else
          null;
      _unknownInits = throwUnknownKeys "services.${name}.init" supportedInitNames merged.init;
    in
    forceChecks [
      _
      _name
      _unknown
      _command
      _restart
      _init
      _unknownInits
    ] (
      merged
      // {
        command = normalizeCommand name merged.command;
        environment = lib.mapAttrs (_: value: builtins.toString value) (merged.environment or { });
        dependsOn = lib.unique (map builtins.toString (merged.dependsOn or [ ]));
        wantedBy = lib.unique (map builtins.toString (merged.wantedBy or [ ]));
        runAs = builtins.toString merged.runAs;
        init = merged.init or { };
      }
    );

  normalizeServices = services: lib.mapAttrs normalizeService services;

  validateServiceGraph =
    services:
    let
      enabledNames = builtins.attrNames (lib.filterAttrs (_: service: service.enable) services);
      validateOne =
        name: service:
        let
          _emptyCommand =
            if service.enable && service.command == [ ] then
              throw "services.${name}.command must not be empty"
            else
              null;
          missingDeps = builtins.filter (dep: !(builtins.elem dep enabledNames)) service.dependsOn;
          unsupportedTargets = builtins.filter (target: !(builtins.elem target supportedWantedBy)) service.wantedBy;
        in
        if missingDeps != [ ] then
          throw "services.${name}.dependsOn references unknown or disabled services: ${lib.concatStringsSep ", " missingDeps}"
        else if unsupportedTargets != [ ] then
          throw "services.${name}.wantedBy only supports: ${lib.concatStringsSep ", " supportedWantedBy}"
        else
          null;
    in
    forceChecks (lib.mapAttrsToList validateOne services) services;

  envExports =
    environment:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") environment
    );

  commandLine = command: lib.concatStringsSep " " (map lib.escapeShellArg command);

  wrapperPath = name: "/etc/antinix/services/${name}/run";

  mkWrapperFile =
    name: service:
    {
      name = wrapperPath name;
      value = {
        text = ''
          #!/bin/sh
          set -eu
          export PATH=/bin:/usr/bin:/sbin:/usr/sbin
          ${envExports service.environment}
          exec ${commandLine service.command}
        '';
        mode = "0755";
      };
    };

  mkRunitRunFile =
    name: service:
    let
      restartMode = service.restart;
    in
    {
      name = "/etc/sv/${name}/run";
      value = {
        text = ''
          #!/bin/sh
          set -eu
          export PATH=/bin:/usr/bin:/sbin:/usr/sbin
          ${envExports service.environment}

          while :; do
            ${commandLine service.command}
            status="$?"
            case ${lib.escapeShellArg restartMode} in
              none)
                exit "$status"
                ;;
              on-failure)
                if [ "$status" -eq 0 ]; then
                  exit 0
                fi
                ;;
              always)
                :
                ;;
            esac
            sleep 1
          done
        '';
        mode = "0755";
      };
    };

  renderOpenrc =
    name: service:
    let
      _runAs =
        if service.runAs == "root" then
          null
        else
          throw "services.${name}.runAs is not yet supported for init=openrc";
      _restart =
        if service.restart == "none" then
          null
        else
          throw "services.${name}.restart=${service.restart} is not yet supported for init=openrc";
      dependLines =
        if service.dependsOn == [ ] then
          ""
        else
          "  need ${lib.concatStringsSep " " service.dependsOn}\n";
      serviceText = ''
        #!/sbin/openrc-run
        description=${lib.escapeShellArg (service.description or "Antinix service ${name}")}
        command=${lib.escapeShellArg (wrapperPath name)}
        ${lib.optionalString (!service.oneShot) ''
        command_background=true
        pidfile=/run/${name}.pid
        ''}

        depend() {
        ${dependLines}  after localmount
        }
      '';
      files = [
        (mkWrapperFile name service)
        {
          name = "/etc/init.d/${name}";
          value = {
            text = serviceText;
            mode = "0755";
          };
        }
      ];
      symlinks =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/etc/runlevels/default/${name}" = "/etc/init.d/${name}";
        };
    in
    forceChecks [
      _runAs
      _restart
    ] {
      files = builtins.listToAttrs files;
      symlinks = symlinks;
    };

  renderRunit =
    name: service:
    let
      _runAs =
        if service.runAs == "root" then
          null
        else
          throw "services.${name}.runAs is not yet supported for init=runit";
      _depends =
        if service.dependsOn == [ ] then
          null
        else
          throw "services.${name}.dependsOn is not yet supported for init=runit";
      _oneShot =
        if service.oneShot then
          throw "services.${name}.oneShot is not yet supported for init=runit"
        else
          null;
      symlinks =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/etc/service/${name}" = "/etc/sv/${name}";
        };
    in
    forceChecks [
      _runAs
      _depends
      _oneShot
    ] {
      files = builtins.listToAttrs [ (mkRunitRunFile name service) ];
      symlinks = symlinks;
    };

  renderDinit =
    name: service:
    let
      _runAs =
        if service.runAs == "root" then
          null
        else
          throw "services.${name}.runAs is not yet supported for init=dinit";
      _oneShot =
        if service.oneShot then
          throw "services.${name}.oneShot is not yet supported for init=dinit"
        else
          null;
      _restart =
        if builtins.elem service.restart [
          "none"
          "always"
        ] then
          null
        else
          throw "services.${name}.restart=${service.restart} is not yet supported for init=dinit";
      depLines = lib.concatMapStringsSep "\n" (dep: "depends-on = ${dep}") service.dependsOn;
      files = builtins.listToAttrs [
        (mkWrapperFile name service)
        {
          name = "/etc/dinit.d/${name}";
          value = {
            text = ''
              type = process
              command = ${wrapperPath name}
              ${lib.optionalString (service.restart == "always") "smooth-recovery = true"}
              ${depLines}
            '';
            mode = "0644";
          };
        }
      ];
      symlinks =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/etc/dinit.d/boot.d/${name}" = "/etc/dinit.d/${name}";
        };
      directories =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/etc/dinit.d/boot.d" = { };
        };
    in
    forceChecks [
      _runAs
      _oneShot
      _restart
    ] {
      inherit files symlinks directories;
    };

  renderS6 =
    name: service:
    let
      _runAs =
        if service.runAs == "root" then
          null
        else
          throw "services.${name}.runAs is not yet supported for init=s6";
      _depends =
        if service.dependsOn == [ ] then
          null
        else
          throw "services.${name}.dependsOn is not yet supported for init=s6";
      _oneShot =
        if service.oneShot then
          throw "services.${name}.oneShot is not yet supported for init=s6"
        else
          null;
      _restart =
        if service.restart == "always" then
          null
        else
          throw "services.${name}.restart=${service.restart} is not yet supported for init=s6";
      files = builtins.listToAttrs [
        {
          name = "/etc/s6/sv/${name}/run";
          value = {
            text = ''
              #!/bin/sh
              set -eu
              export PATH=/command:/bin:/usr/bin:/sbin:/usr/sbin
              ${envExports service.environment}
              exec ${commandLine service.command}
            '';
            mode = "0755";
          };
        }
        {
          name = "/etc/s6/sv/${name}/finish";
          value = {
            text = ''
              #!/bin/sh
              exit 0
            '';
            mode = "0755";
          };
        }
      ];
      symlinks =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/service/${name}" = "/etc/s6/sv/${name}";
        };
      directories =
        lib.optionalAttrs (builtins.elem "default" service.wantedBy) {
          "/service" = { };
        };
    in
    forceChecks [
      _runAs
      _depends
      _oneShot
      _restart
    ] {
      inherit files symlinks directories;
    };

  renderUnsupported =
    init: services:
    let
      names = builtins.attrNames (lib.filterAttrs (_: service: service.enable) services);
    in
    if names == [ ] then
      { }
    else
      throw "init=${init} does not yet support user-defined services: ${lib.concatStringsSep ", " names}";

  mergeFragments =
    fragments:
    lib.foldl'
      (
        acc: fragment:
        {
          files = (acc.files or { }) // (fragment.files or { });
          directories = (acc.directories or { }) // (fragment.directories or { });
          symlinks = (acc.symlinks or { }) // (fragment.symlinks or { });
          imports = (acc.imports or { }) // (fragment.imports or { });
          postBuild = (acc.postBuild or [ ]) ++ (fragment.postBuild or [ ]);
          meta = (acc.meta or { }) // (fragment.meta or { });
        }
      )
      {
        files = { };
        directories = { };
        symlinks = { };
        imports = { };
        postBuild = [ ];
        meta = { };
      }
      fragments;

  renderService =
    init: name: service:
    if !service.enable then
      { }
    else
      if init == "openrc" then
        renderOpenrc name service
      else if init == "runit" then
        renderRunit name service
      else if init == "dinit" then
        renderDinit name service
      else if init == "s6" then
        renderS6 name service
      else
        throw "Unsupported init system for service rendering: ${init}";

in
{
  inherit normalizeServices;

  renderServices =
    {
      init,
      services,
    }:
    let
      normalized = validateServiceGraph (normalizeServices services);
      fragments =
        if builtins.elem init [
          "busybox"
          "simple"
        ] then
          [ (renderUnsupported init normalized) ]
        else if !(builtins.elem init supportedInitNames) then
          throw "Unsupported init system for service rendering: ${init}"
        else
          map (name: renderService init name normalized.${name}) (builtins.attrNames normalized);
    in
    {
      services = normalized;
      fragment = mergeFragments fragments;
    };
}
