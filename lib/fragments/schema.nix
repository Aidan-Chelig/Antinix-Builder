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
      tmpfsDirs = [ "/tmp" "/run" ];
      stateDirs = [ "/var/lib" "/var/log" ];
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
      inherit source text mode user group;
    };

  mkDirectory =
    {
      mode ? "0755",
      user ? "root",
      group ? "root",
    }:
    {
      inherit mode user group;
    };

  mkImport =
    {
      source,
      user ? "root",
      group ? "root",
    }:
    {
      inherit source user group;
    };

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
    assert ! (password != null && hashedPassword != null);
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
