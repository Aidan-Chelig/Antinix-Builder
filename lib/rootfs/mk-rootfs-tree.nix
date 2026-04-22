{
  lib,
  pkgs,
  buildEnv,
  runCommand,
  writeText,
  writeShellApplication,
  accounts,
  overlay,
  patcherConfig,
  rootfsPatcher,
}:

spec:
let
  systemName = if spec.name != null then spec.name else "rootfs";
  dataDirs = [ "share" ];
  debug = spec.debug or { };
  tracePhases = debug.tracePhases or false;
  watchPaths = debug.watchPaths or [ ];
  phaseTracingEnabled = if tracePhases then "1" else "0";
  watchPathBlocks = lib.concatStringsSep "\n" (
    map (
      path: ''
        trace_path ${lib.escapeShellArg path} "$root"
      ''
    ) watchPaths
  );
  provenanceFile = writeText "${systemName}-build-provenance.txt" ''
    system_name=${systemName}
    selected_init=${toString (spec.meta.selectedInit or "")}
    selected_package_manager=${toString (spec.meta.selectedPackageManager or "")}
    kernel_version=${toString (spec.meta.kernelVersion or "")}
    include_kernel_modules=${if (spec.meta.includeKernelModules or false) then "true" else "false"}
    runtime_layout_enabled=${if (patcherConfigValue.runtime_layout.normalize_runtime_layout or false) then "true" else "false"}
    trace_phases=${if tracePhases then "true" else "false"}
    patcher_debug_artifacts=${if (debug.generatePatcherArtifacts or false) then "true" else "false"}
  '';

  accountData = accounts.build {
    users = spec.users or { };
    groups = spec.groups or { };
    hostname = spec.hostname or "localhost";
    profileExtraText = "";
  };

  generatedFiles = {
    "/etc/passwd" = {
      text = accountData.passwdText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/group" = {
      text = accountData.groupText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/shadow" = {
      text = accountData.shadowText;
      user = "root";
      group = "root";
      mode = "0600";
    };

    "/etc/profile" = {
      text = accountData.profileText;
      user = "root";
      group = "root";
      mode = "0644";
    };

    "/etc/hostname" = {
      text = "${spec.hostname or "localhost"}\n";
      user = "root";
      group = "root";
      mode = "0644";
    };
  };

  generatedDirectories = accountData.homeDirs;

  mergedFiles = generatedFiles // (spec.files or { });

  mergedDirectories = generatedDirectories // (spec.directories or { });

  baseTree = overlay.build {
    name = "${systemName}-base-tree";
    packagesEnv = null;
    files = mergedFiles;
    directories = mergedDirectories;
    symlinks = spec.symlinks or { };
    imports = spec.imports or { };
  };

  packageClosure = pkgs.closureInfo {
    rootPaths = spec.packages or [ ];
  };

  closurePathsFile = "${packageClosure}/store-paths";

  patcherConfigValue = patcherConfig.build {
    inherit spec;
    rootfsPath = baseTree;
  };

  patcherConfigJson = writeText "${systemName}-rootfs-patcher-config.json" (
    builtins.toJSON patcherConfigValue
  );

  patcherCommand =
    subcommand: extraArgs:
    lib.escapeShellArgs (
      [
        "${rootfsPatcher}/bin/rootfs-patcher"
        subcommand
        "--dry-run"
        "--root"
        "${rootfsTree}"
        "--config"
        "${patcherConfigJson}"
      ]
      ++ extraArgs
    );

  patcherDryRunScript =
    {
      name,
      subcommand,
      extraArgs ? [ ],
    }:
    writeShellApplication {
      name = "${systemName}-${name}";
      runtimeInputs = [
        rootfsPatcher
        pkgs.coreutils
      ];
      text = ''
        set -euo pipefail
        cmd=(${patcherCommand subcommand extraArgs})
        printf 'PATCHER CMD: %q ' "''${cmd[@]}"
        printf '\n'
        exec "''${cmd[@]}"
      '';
    };

  rootfsTree =
    runCommand "${systemName}-rootfs-tree"
  {
    nativeBuildInputs = [
      rootfsPatcher
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
      pkgs.gnugrep
    ];
    passthru = {
      patcherDebug = {
        config = patcherConfigJson;
        allowedPrefixesFile = closurePathsFile;
        inherit closurePathsFile dataDirs;
        mergePlan = patcherDryRunScript {
          name = "rootfs-patcher-merge-plan";
          subcommand = "merge";
          extraArgs =
            [
              "--closure-paths-file"
              "${closurePathsFile}"
            ]
            ++ lib.concatMap (dir: [
              "--data-dir"
              dir
            ]) dataDirs;
        };
        rewritePlan = patcherDryRunScript {
          name = "rootfs-patcher-rewrite-plan";
          subcommand = "rewrite";
          extraArgs = [
            "--allowed-prefixes-file"
            "${closurePathsFile}"
          ];
        };
        processPlan = patcherDryRunScript {
          name = "rootfs-patcher-process-plan";
          subcommand = "process";
          extraArgs = [
            "--allowed-prefixes-file"
            "${closurePathsFile}"
          ];
        };
      };
    };
  }
  ''
        set -euo pipefail

        trace_path() {
          path="$1"
          full="$2$path"

          echo "$path"
          if [ -L "$full" ]; then
            echo "  kind=symlink"
            echo "  target=$(readlink "$full" 2>/dev/null || true)"
            return 0
          fi

          if [ -d "$full" ]; then
            echo "  kind=directory"
            find "$full" -maxdepth 2 -mindepth 0 2>/dev/null | sed "s#^$2##" | sort | sed 's/^/  entry=/' | head -n 40 || true
            return 0
          fi

          if [ -f "$full" ]; then
            echo "  kind=file"
            ls -ld "$full" 2>/dev/null | sed 's/^/  stat=/' || true
            return 0
          fi

          echo "  kind=missing"
        }

        write_phase() {
          phase="$1"
          root="$2"
          if [ "${phaseTracingEnabled}" != "1" ]; then
            return 0
          fi

          mkdir -p "$root/debug"
          {
            echo "[phase]"
            echo "name=$phase"
            echo
            echo "[watched]"
            ${watchPathBlocks}
          } > "$root/debug/phase-$phase.txt"
        }

        mkdir -p "$out"
        cp -a "${baseTree}/." "$out/"
        chmod u+w "$out"
        chmod -R u+w "$out" 2>/dev/null || true
        write_phase overlay "$out"

        if [ "${phaseTracingEnabled}" = "1" ]; then
          mkdir -p "$out/debug"
          cp "${provenanceFile}" "$out/debug/build-provenance.txt"
        fi

        write_phase pre-process "$out"

        "${rootfsPatcher}/bin/rootfs-patcher" merge \
          --root "$out" \
          --config "${patcherConfigJson}" \
          --closure-paths-file "${closurePathsFile}" \
          ${lib.concatMapStringsSep " " (dir: "--data-dir ${lib.escapeShellArg dir}") dataDirs}

        chmod u+w "$out"
        chmod -R u+w "$out" 2>/dev/null || true


        "${rootfsPatcher}/bin/rootfs-patcher" process \
          --root "$out" \
          --config "${patcherConfigJson}" \
          --allowed-prefixes-file "${closurePathsFile}"

        ${lib.concatStringsSep "\n" (spec.postBuild or [ ])}

        normalize_kernel_module_links() {
          for modules_root in "$out/lib/modules" "$out/usr/lib/modules"; do
            [ -d "$modules_root" ] || continue

            while IFS= read -r link; do
              target="$(readlink "$link" || true)"
              case "$target" in
                /nix/store/*)
                  rm -f "$link"
                  cp -a "$target" "$link"
                  ;;
              esac
            done < <(find "$modules_root" -type l -print 2>/dev/null || true)
          done
        }

        normalize_kernel_module_links

        bad_internal_links="$(
          find "$out"/bin "$out"/sbin "$out"/lib "$out"/lib64 "$out"/usr/bin "$out"/usr/sbin \
            -xtype l -printf '%P -> %l\n' 2>/dev/null || true
        )"

        if [ -n "$bad_internal_links" ]; then
          echo "broken symlinks detected after postBuild:" >&2
          printf '%s\n' "$bad_internal_links" >&2
          exit 1
        fi

        absolute_internal_links="$(
          find "$out"/bin "$out"/sbin "$out"/lib "$out"/lib64 "$out"/usr/bin "$out"/usr/sbin \
            -type l -printf '%p -> %l\n' 2>/dev/null | sed -n 's#^'"$out"'##p' | grep ' -> /' || true
        )"

        if [ -n "$absolute_internal_links" ]; then
          echo "absolute internal symlinks detected after postBuild:" >&2
          printf '%s\n' "$absolute_internal_links" >&2
          exit 1
        fi
        write_phase post-process "$out"
  '';
in
rootfsTree
