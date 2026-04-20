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

    # Debug and tracing controls used by the rootfs builders.
    debug = {
      # Emit phase checkpoint files such as /debug/phase-pre-process.txt.
      tracePhases = false;
      # Let the Rust rootfs patcher write its own debug artifacts under /debug.
      generatePatcherArtifacts = false;
      # Paths to inspect automatically at each traced phase.
      watchPaths = [ ];
    };

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
  ##@ path: lib.schema.mkFile
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
  ##@ path: lib.schema.mkDirectory
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
  ##@ path: lib.schema.mkImport
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
  ##@ path: lib.schema.mkUser
  ##@ kind: helper
  ##@ summary: Define a system user.
  ##@ param: isNormalUser bool Whether user is a normal account.
  ##@ param: uid int? User ID.
  ##@ param: group string? Primary group.
  ##@ param: extraGroups list Supplementary groups.
  ##@ param: home string? Home directory.
  ##@ param: shell string Login shell.
  ##@ param: password string? Plain-text password for generated account data.
  ##@ param: hashedPassword string? Pre-hashed password.
  ##@ param: createHome bool Whether the home directory should be created.
  ##@ param: description string Account description or gecos field.
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
  ##@ path: lib.schema.mkGroup
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

  ##@ name: mkService
  ##@ path: lib.schema.mkService
  ##@ kind: helper
  ##@ summary: Define a declarative service for mkSystem.
  ##@ param: enable bool Whether the service should be rendered for the selected init.
  ##@ param: description string? Optional service description.
  ##@ param: command list Command and arguments to execute.
  ##@ param: environment attrset Environment variables exported before exec.
  ##@ param: dependsOn list Other service names required before startup.
  ##@ param: wantedBy list Activation targets. Currently supports "default".
  ##@ param: runAs string Runtime user. Root-only in the current implementation.
  ##@ param: oneShot bool Whether the service should run once and exit.
  ##@ param: restart string Restart policy: none, on-failure, or always.
  ##@ param: init attrset Init-specific override namespace reserved for backend-specific extensions.
  ##@ returns: attrset describing a service entry.

  mkService =
    {
      enable ? true,
      description ? null,
      command,
      environment ? { },
      dependsOn ? [ ],
      wantedBy ? [ "default" ],
      runAs ? "root",
      oneShot ? false,
      restart ? if oneShot then "none" else "always",
      init ? { },
    }:
    {
      inherit
        enable
        description
        command
        environment
        dependsOn
        wantedBy
        runAs
        oneShot
        restart
        init
        ;
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
  ##@ name: defaults
  ##@ path: lib.schema.defaults
  ##@ kind: module
  ##@ summary: Default fragment shape used as the baseline for consumer-authored system specifications.
  ##@ returns: Attrset of default values for packages, files, users, runtime, patching, validation, and metadata.
  inherit
    defaults
    mkFile
    mkDirectory
    mkImport
    mkUser
    mkGroup
    mkService
    mkTextPatch
    mkBinaryPatch
    mkElfPatch
    isFragment
    ;

  ##@ name: mkTextPatch
  ##@ path: lib.schema.mkTextPatch
  ##@ kind: helper
  ##@ summary: Define a text rewrite rule for the rootfs patcher.
  ##@ param: from string Source text to replace.
  ##@ param: to string Replacement text.
  ##@ param: file string? Optional file path restriction.
  ##@ param: requireTargetExists bool? Require the rewritten target to exist in the rootfs.
  ##@ param: targetKind string? Optional target kind restriction.
  ##@ returns: attrset describing a text rewrite rule.

  ##@ name: mkBinaryPatch
  ##@ path: lib.schema.mkBinaryPatch
  ##@ kind: helper
  ##@ summary: Define a binary rewrite rule for the rootfs patcher.
  ##@ param: from string Source bytes or string to replace.
  ##@ param: to string Replacement bytes or string.
  ##@ param: file string? Optional file path restriction.
  ##@ param: requireTargetExists bool? Require the rewritten target to exist in the rootfs.
  ##@ param: targetKind string? Optional target kind restriction.
  ##@ returns: attrset describing a binary rewrite rule.

  ##@ name: mkElfPatch
  ##@ path: lib.schema.mkElfPatch
  ##@ kind: helper
  ##@ summary: Define an ELF patch rule for the rootfs patcher.
  ##@ param: from string Original value or interpreter marker to replace.
  ##@ param: to string Replacement value.
  ##@ param: file string? Optional file path restriction.
  ##@ param: requireTargetExists bool? Require the rewritten target to exist in the rootfs.
  ##@ param: targetKind string? Optional target kind restriction.
  ##@ returns: attrset describing an ELF patch rule.

  ##@ name: isFragment
  ##@ path: lib.schema.isFragment
  ##@ kind: helper
  ##@ summary: Predicate that reports whether a value is fragment-shaped.
  ##@ param: value any Value to test.
  ##@ returns: Boolean indicating whether the value is an attrset fragment.
}
