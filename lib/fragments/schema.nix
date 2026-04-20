{ lib }:

let
  defaults = {
    name = null;

    # Core content
    packages = [ ];
    files = { };
    directories = { };
    symlinks = { };
    imports = { };

    # System identity / defaults
    hostname = "localhost";
    motd = null;
    environment = { };

    # Users and groups
    users = { };
    groups = { };

    # Service-ish / boot-ish configuration
    services = { };
    runtime = {
      tmpfsDirs = [
        "/tmp"
        "/run"
      ];
      stateDirs = [
        "/var/lib"
        "/var/log"
      ];
      dataDirs = [ "/srv" ];
    };

    # Shell hooks or build hooks to be interpreted downstream
    postBuild = [ ];

    # Advanced escape hatches
    patching = {
      # Simple string-for-string text rewrites
      textRewrites = { };

      # Richer patch phases for compatibility with the older API
      textPatches = [ ];
      binaryPatches = [ ];
      elfPatches = [ ];

      extraSearchPaths = [ ];

      ignore = {
        paths = [ ];
        suffixes = [ ];
        extensions = [ ];
        globs = [ ];
      };

      runtime = {
        normalizeStorePaths = true;
        rewriteInterpreter = true;
      };
    };

    validation = {
      forbidStoreReferences = true;
      allowMissing = [ ];
      strict = true;
    };

    meta = { };
  };

  ##@ name: mkFile
  ##@ kind: helper
  ##@ summary: Define a file in the rootfs.
  ##@ param: source path? Source file to copy.
  ##@ param: text string? Inline file contents.
  ##@ param: mode string? File mode (e.g. "0644").
  ##@ param: user string Owner user.
  ##@ param: group string Owner group.
  ##@ returns: attrset describing a file entry.

  mkFile =
    {
      source ? null,
      text ? null,
      mode ? null,
      user ? "root",
      group ? "root",
    }:
    assert (source != null) != (text != null);
    {
      inherit
        source
        text
        mode
        user
        group
        ;
    };

  ##@ name: mkDirectory
  ##@ kind: helper
  ##@ summary: Define a directory in the rootfs.
  ##@ param: mode string? Directory mode.
  ##@ param: user string Owner user.
  ##@ param: group string Owner group.
  ##@ returns: attrset describing a directory.

  mkDirectory =
    {
      mode ? "0755",
      user ? "root",
      group ? "root",
    }:
    {
      inherit mode user group;
    };

  ##@ name: mkImport
  ##@ kind: helper
  ##@ summary: Import an existing filesystem tree into the rootfs.
  ##@ param: source path Source directory to copy.
  ##@ param: user string Owner user.
  ##@ param: group string Owner group.
  ##@ returns: attrset describing an import.

  mkImport =
    {
      source,
      user ? "root",
      group ? "root",
    }:
    {
      inherit source user group;
    };

  ##@ name: mkUser
  ##@ kind: helper
  ##@ summary: Define a system user.
  ##@ param: uid int? User ID.
  ##@ param: group string? Primary group.
  ##@ param: extraGroups list Supplementary groups.
  ##@ param: home string Home directory.
  ##@ param: shell string Login shell.
  ##@ param: hashedPassword string Pre-hashed password.
  ##@ param: isNormalUser bool Whether user is a normal account.
  ##@ returns: attrset describing a user.
  mkUser =
    {
      isNormalUser ? true,
      uid ? null,
      group ? null,
      extraGroups ? [ ],
      home ? null,
      shell ? "/bin/sh",
      password ? null,
      hashedPassword ? null,
      createHome ? true,
      description ? "",
    }:
    assert !(password != null && hashedPassword != null);
    {
      inherit
        isNormalUser
        uid
        group
        extraGroups
        home
        shell
        password
        hashedPassword
        createHome
        description
        ;
    };

  ##@ name: mkGroup
  ##@ kind: helper
  ##@ summary: Define a system group.
  ##@ param: gid int? Group ID.
  ##@ returns: attrset describing a group.

  mkGroup =
    {
      gid ? null,
    }:
    {
      inherit gid;
    };

  mkTextPatch =
    {
      from,
      to,
      file ? null,
      requireTargetExists ? false,
      targetKind ? null,
    }:
    {
      inherit
        from
        to
        file
        requireTargetExists
        targetKind
        ;
    };

  mkBinaryPatch =
    {
      from,
      to,
      file ? null,
      requireTargetExists ? false,
      targetKind ? null,
    }:
    {
      inherit
        from
        to
        file
        requireTargetExists
        targetKind
        ;
    };

  mkElfPatch =
    {
      from,
      to,
      file ? null,
      requireTargetExists ? false,
      targetKind ? null,
    }:
    {
      inherit
        from
        to
        file
        requireTargetExists
        targetKind
        ;
    };

  isFragment = value: lib.isAttrs value;

in
{
  inherit
    defaults
    mkFile
    mkDirectory
    mkImport
    mkUser
    mkGroup
    mkTextPatch
    mkBinaryPatch
    mkElfPatch
    isFragment
    ;
}
