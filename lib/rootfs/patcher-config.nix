{ lib, guestSystem ? null }:

let
  defaultStrictScanRoots = [
    "/bin"
    "/sbin"
    "/usr/bin"
    "/usr/sbin"
  ];

  defaultWarnScanRoots = [
    "/lib"
    "/lib64"
    "/usr/lib"
    "/usr/lib64"
    "/usr/libexec"
    "/usr/share"
    "/etc"
  ];

  defaultIgnoreGlobs = [
    "/usr/share/terminfo/**"
    "/usr/share/zoneinfo/**"
    "/usr/share/keymaps/**"
    "/usr/share/icons/**"
    "/usr/share/fonts/**"
    "/usr/share/man/**"
    "/usr/share/doc/**"
    "/lib/modules/*"
    "/usr/lib/modules/*"
  ];

  defaultIgnorePaths = [
    "/lib/modules"
    "/usr/lib/modules"
  ];

  defaultIgnoreExtensions = [
    "png"
    "jpg"
    "jpeg"
    "gif"
    "svg"
    "ico"
    "ttf"
    "otf"
    "woff"
    "woff2"
    "mp3"
    "ogg"
    "wav"
    "mp4"
    "webm"
    "zip"
    "gz"
    "xz"
    "bz2"
    "a"
    "la"
  ];

  defaultAutoPatch = {
    break_hardlinks = true;
    patch_shebangs = true;
    patch_elfs = true;
    synthesize_glibc_compat_symlinks = true;
    normalize_absolute_needed = true;
    rewrite_embedded_store_paths = true;
    minimize_rpath_from_graph = false;
    default_interpreter = null;
    default_rpath = "/lib:/usr/lib:/lib64:/usr/lib64";
    patchelf_bin = null;
  };

  defaultRuntimeLayout = {
    normalize_runtime_layout = true;
    detect_interpreter_from = [
      "/sbin/init"
      "/bin/sh"
      "/bin/bash"
      "/usr/bin/env"
      "/bin/busybox"
      "/usr/bin/busybox"
    ];
    interpreter_fallback_scan_roots = [
      "/bin"
      "/sbin"
      "/usr/bin"
      "/usr/sbin"
    ];
    lib_roots = [
      "/usr/lib"
    ];
    lib64_roots = [
      "/usr/lib64"
    ];
    install_detected_interpreter_to = "/lib64";
  };

  defaultOpaqueData = {
    policy = "deterministic_tiers";
    shared_root = "/usr/share/antinix/vendor";
    fallback_root = "/usr/lib/antinix/store";
  };

  defaultValidation = {
    forbid_absolute_store_symlinks = true;
    forbid_absolute_internal_symlinks = true;
    absolute_internal_symlink_scan_roots = [
      "/bin"
      "/sbin"
    ];
    expected_interpreter = null;
    interpreter_scan_roots = [
      "/bin"
      "/sbin"
      "/usr/bin"
      "/usr/sbin"
    ];
  };

  defaultChmod = {
    make_executable = [
    ];
  };

  defaultDebug = {
    generate_artifacts = false;
  };

  mergeUnique = a: b: lib.unique (a ++ b);

  normalizePatchList =
    patches:
    map (
      patch:
      {
        from = patch.from;
        to = patch.to;
        require_target_exists = patch.requireTargetExists or false;
        target_kind = patch.targetKind or null;
      }
      // lib.optionalAttrs (patch ? file && patch.file != null) {
        file = patch.file;
      }
    ) patches;

  attrTextRewritesToList =
    rewrites:
    map (from: {
      inherit from;
      to = rewrites.${from};
      require_target_exists = false;
      target_kind = null;
    }) (builtins.attrNames rewrites);

  directoryKeys = dirs: builtins.attrNames dirs;

  interpreterForGuestSystem =
    system:
    if system == null then
      null
    else if system == "x86_64-linux" then
      "ld-linux-x86-64.so.2"
    else if system == "aarch64-linux" then
      "ld-linux-aarch64.so.1"
    else if system == "riscv64-linux" then
      "ld-linux-riscv64-lp64d.so.1"
    else
      null;

  chooseExpectedInterpreter =
    runtimeLayout:
    let
      installDir = runtimeLayout.install_detected_interpreter_to or null;
      loaderName = interpreterForGuestSystem guestSystem;
    in
    if installDir == null || loaderName == null then
      null
    else
      "${installDir}/${loaderName}";

in
{
  build =
    {
      spec,
      rootfsPath ? null,
    }:
    let
      patching = spec.patching or { };
      validationIn = spec.validation or { };
      debugIn = spec.debug or { };

      ignore = patching.ignore or { };
      runtimeIn = patching.runtime or { };

      declaredDirectoryPaths = directoryKeys (spec.directories or { });

      strictScanRoots = mergeUnique defaultStrictScanRoots (
        (patching.strictScanRoots or [ ]) ++ (patching.extraSearchPaths or [ ])
      );

      warnScanRoots = mergeUnique defaultWarnScanRoots (
        (patching.warnScanRoots or [ ]) ++ declaredDirectoryPaths
      );

      autoPatch = defaultAutoPatch // {
        rewrite_embedded_store_paths =
          runtimeIn.normalizeStorePaths or defaultAutoPatch.rewrite_embedded_store_paths;

        default_interpreter = expectedInterpreter;
      };

      runtimeLayout = defaultRuntimeLayout // {
        detect_interpreter_from = mergeUnique defaultRuntimeLayout.detect_interpreter_from (
          (patching.detectInterpreterFrom or [ ]) ++ lib.optionals ((spec.files or { }) ? "/init") [ "/init" ]
        );

        interpreter_fallback_scan_roots = mergeUnique defaultRuntimeLayout.interpreter_fallback_scan_roots (
          patching.interpreterFallbackScanRoots or [ ]
        );

        lib_roots = mergeUnique defaultRuntimeLayout.lib_roots (patching.libRoots or [ ]);

        lib64_roots = mergeUnique defaultRuntimeLayout.lib64_roots (patching.lib64Roots or [ ]);

        install_detected_interpreter_to =
          patching.installDetectedInterpreterTo or defaultRuntimeLayout.install_detected_interpreter_to;

        normalize_runtime_layout = true;
      };

      opaqueData = defaultOpaqueData // {
        policy = patching.opaqueDataPolicy or defaultOpaqueData.policy;
        shared_root = patching.opaqueDataSharedRoot or defaultOpaqueData.shared_root;
        fallback_root = patching.opaqueDataFallbackRoot or defaultOpaqueData.fallback_root;
      };

      expectedInterpreter = validationIn.expectedInterpreter or (chooseExpectedInterpreter runtimeLayout);

      validation = defaultValidation // {
        interpreter_scan_roots = mergeUnique defaultValidation.interpreter_scan_roots (
          validationIn.interpreterScanRoots or [ ]
        );

        forbid_absolute_store_symlinks =
          validationIn.forbidAbsoluteStoreSymlinks or defaultValidation.forbid_absolute_store_symlinks;

        expected_interpreter = expectedInterpreter;
      };

      chmod = defaultChmod // {
        make_executable = mergeUnique defaultChmod.make_executable (patching.makeExecutable or [ ]);
      };

      debug = defaultDebug // {
        generate_artifacts = debugIn.generatePatcherArtifacts or false;
      };

      textRewrites =
        attrTextRewritesToList (patching.textRewrites or { })
        ++ normalizePatchList (patching.textPatches or [ ]);

      binaryRewrites = normalizePatchList (patching.binaryPatches or [ ]);

      elfPatches = map (patch: {
        file = patch.file;
        interpreter = patch.interpreter or null;
        rpath = patch.rpath or null;
      }) (patching.elfPatches or [ ]);

      ignorePaths = mergeUnique defaultIgnorePaths (ignore.paths or [ ]);
      ignoreGlobs = mergeUnique defaultIgnoreGlobs (ignore.globs or [ ]);

      ignoreExtensions = mergeUnique defaultIgnoreExtensions (ignore.extensions or [ ]);

      allowedStorePrefixes = lib.unique (patching.allowedStorePrefixes or [ ]);

      forbiddenStorePaths = lib.unique (patching.forbiddenStorePaths or [ ]);
    in
    {
      auto_patch = autoPatch;

      text_rewrites = textRewrites;
      binary_rewrites = binaryRewrites;
      elf_patches = elfPatches;

      strict_scan_roots = strictScanRoots;
      warn_scan_roots = warnScanRoots;

      ignore_paths = ignorePaths;
      ignore_globs = ignoreGlobs;
      ignore_extensions = ignoreExtensions;

      allowed_store_prefixes = allowedStorePrefixes;
      forbidden_store_paths = forbiddenStorePaths;

      runtime_layout = runtimeLayout;
      opaque_data = opaqueData;
      validation = validation;
      chmod = chmod;
      debug = debug;
    };
}
