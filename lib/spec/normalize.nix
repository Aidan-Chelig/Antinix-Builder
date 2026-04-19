{ lib, schema }:

let
  inherit (schema) defaults;

  rootUserDefaults = {
    isNormalUser = false;
    uid = 0;
    group = "root";
    extraGroups = [ ];
    home = "/root";
    shell = "/bin/sh";
    createHome = true;
    description = "root";
  };

  normalUserDefaults = {
    isNormalUser = true;
    uid = null;
    group = null;
    extraGroups = [ ];
    home = null;
    shell = "/bin/sh";
    createHome = true;
    description = "";
  };

  groupDefaults = {
    gid = null;
  };

  fileDefaults = {
    mode = null;
    user = "root";
    group = "root";
  };

  directoryDefaults = {
    mode = "0755";
    user = "root";
    group = "root";
  };

  mkEnvProfileText =
    environment:
    let
      names = builtins.attrNames environment;
      lines = map
        (name:
          let
            value = builtins.toString environment.${name};
          in
          ''export ${name}=${lib.escapeShellArg value}''
        )
        names;
    in
    lib.concatStringsSep "\n" lines + lib.optionalString (lines != [ ]) "\n";

  normalizeUser =
    name: user:
    let
      base =
        if name == "root"
        then rootUserDefaults
        else normalUserDefaults;

      merged = base // user;

      finalGroup =
        if merged.group != null then merged.group else name;

      finalHome =
        if merged.home != null
        then merged.home
        else if name == "root"
        then "/root"
        else "/home/${name}";
    in
    merged // {
      group = finalGroup;
      home = finalHome;
      extraGroups = lib.unique (merged.extraGroups or [ ]);
    };

  normalizeUsers =
    users:
    lib.mapAttrs normalizeUser users;

  normalizeGroups =
    groups:
    lib.mapAttrs (_: group: groupDefaults // group) groups;

  groupsFromUsers =
    users:
    lib.mapAttrs'
      (name: user:
        lib.nameValuePair (user.group or name) { })
      users;

  normalizeFiles =
    files:
    lib.mapAttrs
      (_path: file:
        fileDefaults // file
      )
      files;

  normalizeDirectories =
    directories:
    lib.mapAttrs
      (_path: dir:
        directoryDefaults // dir
      )
      directories;

  motdFile =
    motd:
    if motd == null then { } else {
      "/etc/motd" = {
        text = motd;
        user = "root";
        group = "root";
        mode = "0644";
      };
    };

  environmentFiles =
    environment:
    let
      text = mkEnvProfileText environment;
    in
    if environment == { } then { } else {
      "/etc/profile.d/antinix-env.sh" = {
        inherit text;
        user = "root";
        group = "root";
        mode = "0644";
      };
    };

  runtimeDirectories =
    runtime:
    let
      mkDirSet = paths:
        builtins.listToAttrs (map (path: {
          name = path;
          value = { };
        }) paths);
    in
    mkDirSet (
      (runtime.tmpfsDirs or [ ])
      ++ (runtime.stateDirs or [ ])
      ++ (runtime.dataDirs or [ ])
    );

in
fragment:
let
  merged = defaults // fragment;

  normalizedUsers = normalizeUsers (merged.users or { });

  inferredGroups =
    groupsFromUsers normalizedUsers;

  normalizedGroups =
    normalizeGroups (
      inferredGroups // (merged.groups or { })
    );

normalizedFiles =
  normalizeFiles (
    (motdFile merged.motd)
    // (environmentFiles (merged.environment or { }))
    // (merged.files or { })
  );

  normalizedDirectories =
    normalizeDirectories (
      (runtimeDirectories (merged.runtime or { }))
      // (merged.directories or { })
    );
in
{
  inherit
    (merged)
    name
    hostname
    packages
    symlinks
    services
    runtime
    postBuild
    patching
    validation
    meta
    ;

  files = normalizedFiles;
  directories = normalizedDirectories;
  users = normalizedUsers;
  groups = normalizedGroups;
}
