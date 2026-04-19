{ lib }:

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
    minimize_rpath_from_graph = true;
    default_interpreter = null;
    default_rpath = null;
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

  mergeUnique = a: b: lib.unique (a ++ b);

  normalizePatchList =
    patches:
    map
      (patch:
        {
          from = patch.from;
          to = patch.to;
          require_target_exists = patch.requireTargetExists or false;
          target_kind = patch.targetKind or null;
        }
        // lib.optionalAttrs (patch ? file && patch.file != null) {
          file = patch.file;
        })
      patches;

  attrTextRewritesToList =
    rewrites:
    map
      (from: {
        inherit from;
        to = rewrites.${from};
        require_target_exists = false;
        target_kind = null;
      })
      (builtins.attrNames rewrites);

  directoryKeys =
    dirs:
    builtins.attrNames dirs;

  chooseExpectedInterpreter =
    runtimeLayout:
    let
      installDir = runtimeLayout.install_detected_interpreter_to or null;
    in
    if installDir == null then
      null
    else if installDir == "/lib64" then
      "/lib64/ld-linux-x86-64.so.2"
    else if installDir == "/lib" then
      "/lib/ld-linux.so.2"
    else
      null;

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

      ignore = patching.ignore or { };
      runtimeIn = patching.runtime or { };

      declaredDirectoryPaths = directoryKeys (spec.directories or { });

      strictScanRoots =
        mergeUnique
          defaultStrictScanRoots
          (
            (patching.strictScanRoots or [ ])
            ++ (patching.extraSearchPaths or [ ])
          );

      warnScanRoots =
        mergeUnique
          defaultWarnScanRoots
          (
            (patching.warnScanRoots or [ ])
            ++ declaredDirectoryPaths
          );

      autoPatch =
        defaultAutoPatch
        // {
          rewrite_embedded_store_paths =
            runtimeIn.normalizeStorePaths or defaultAutoPatch.rewrite_embedded_store_paths;

          default_interpreter = expectedInterpreter;
        };

      runtimeLayout =
        defaultRuntimeLayout
        // {
          detect_interpreter_from =
            mergeUnique
              defaultRuntimeLayout.detect_interpreter_from
              (
                (patching.detectInterpreterFrom or [ ])
                ++ lib.optionals ((spec.files or { }) ? "/init") [ "/init" ]
              );

          interpreter_fallback_scan_roots =
            mergeUnique
              defaultRuntimeLayout.interpreter_fallback_scan_roots
              (patching.interpreterFallbackScanRoots or [ ]);

          lib_roots =
            mergeUnique
              defaultRuntimeLayout.lib_roots
              (patching.libRoots or [ ]);

          lib64_roots =
            mergeUnique
              defaultRuntimeLayout.lib64_roots
              (patching.lib64Roots or [ ]);

          install_detected_interpreter_to =
            patching.installDetectedInterpreterTo
            or defaultRuntimeLayout.install_detected_interpreter_to;

          normalize_runtime_layout = true;
        };

      expectedInterpreter =
        validationIn.expectedInterpreter
        or (chooseExpectedInterpreter runtimeLayout);

      validation =
        defaultValidation
        // {
          interpreter_scan_roots =
            mergeUnique
              defaultValidation.interpreter_scan_roots
              (validationIn.interpreterScanRoots or [ ]);

          forbid_absolute_store_symlinks =
            validationIn.forbidAbsoluteStoreSymlinks
            or defaultValidation.forbid_absolute_store_symlinks;

          expected_interpreter = expectedInterpreter;
        };

      chmod =
        defaultChmod
        // {
          make_executable =
            mergeUnique
              defaultChmod.make_executable
              (patching.makeExecutable or [ ]);
        };

      textRewrites =
        attrTextRewritesToList (patching.textRewrites or { })
        ++ normalizePatchList (patching.textPatches or [ ]);

      binaryRewrites =
        normalizePatchList (patching.binaryPatches or [ ]);

      elfPatches =
        map
          (patch:
            {
              file = patch.file;
              interpreter = patch.interpreter or null;
              rpath = patch.rpath or null;
            })
          (patching.elfPatches or [ ]);

      ignoreGlobs =
        mergeUnique
          defaultIgnoreGlobs
          (ignore.globs or [ ]);

      ignoreExtensions =
        mergeUnique
          defaultIgnoreExtensions
          (ignore.extensions or [ ]);

      allowedStorePrefixes =
        lib.unique (patching.allowedStorePrefixes or [ ]);

      forbiddenStorePaths =
        lib.unique (patching.forbiddenStorePaths or [ ]);
    in
    {
      auto_patch = autoPatch;

      text_rewrites = textRewrites;
      binary_rewrites = binaryRewrites;
      elf_patches = elfPatches;

      strict_scan_roots = strictScanRoots;
      warn_scan_roots = warnScanRoots;

      ignore_globs = ignoreGlobs;
      ignore_extensions = ignoreExtensions;

      allowed_store_prefixes = allowedStorePrefixes;
      forbidden_store_paths = forbiddenStorePaths;

      runtime_layout = runtimeLayout;
      validation = validation;
      chmod = chmod;
    };
}
