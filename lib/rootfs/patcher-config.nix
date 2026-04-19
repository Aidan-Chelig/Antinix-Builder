{ lib }:

let
  defaultScanRoots = [
    "/bin"
    "/sbin"
    "/lib"
    "/lib64"
    "/usr"
    "/etc"
  ];

  defaultIgnore = {
    paths = [ ];
    suffixes = [
      ".la"
      ".a"
    ];
    extensions = [
      "png"
      "jpg"
      "jpeg"
      "gif"
      "svg"
      "ico"
      "ttf"
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
    ];
    globs = [ ];
  };

  defaultRuntime = {
    normalizeStorePaths = true;
    rewriteInterpreter = true;
  };

  defaultValidation = {
    forbidStoreReferences = true;
    allowMissing = [ ];
    strict = true;
  };

  normalizeIgnore =
    ignore:
    defaultIgnore // ignore // {
      paths = lib.unique ((defaultIgnore.paths or [ ]) ++ (ignore.paths or [ ]));
      suffixes = lib.unique ((defaultIgnore.suffixes or [ ]) ++ (ignore.suffixes or [ ]));
      extensions = lib.unique ((defaultIgnore.extensions or [ ]) ++ (ignore.extensions or [ ]));
      globs = lib.unique ((defaultIgnore.globs or [ ]) ++ (ignore.globs or [ ]));
    };

  normalizeRuntime =
    runtime:
    defaultRuntime // runtime;

  normalizeValidation =
    validation:
    defaultValidation // validation // {
      allowMissing =
        lib.unique ((defaultValidation.allowMissing or [ ]) ++ (validation.allowMissing or [ ]));
    };

  normalizeSimpleTextRewrites =
    rewrites:
    if rewrites == null then { } else rewrites;

  normalizePatchList =
    patches:
    map
      (patch:
        {
          from = patch.from;
          to = patch.to;
          requireTargetExists = patch.requireTargetExists or false;
          targetKind = patch.targetKind or null;
        }
        // lib.optionalAttrs (patch ? file && patch.file != null) {
          file = patch.file;
        })
      patches;

  directoryKeys =
    dirs:
    builtins.attrNames dirs;

in
{
  build =
    {
      spec,
      rootfsPath ? null,
    }:
    let
      patching = spec.patching or { };
      validation = spec.validation or { };

      ignore = normalizeIgnore (patching.ignore or { });
      runtime = normalizeRuntime (patching.runtime or { });
      validation' = normalizeValidation validation;

      declaredDirectoryPaths = directoryKeys (spec.directories or { });

      extraSearchPaths =
        lib.unique (
          (patching.extraSearchPaths or [ ])
          ++ declaredDirectoryPaths
        );

      scanRoots =
        lib.unique (defaultScanRoots ++ extraSearchPaths);

      textRewrites =
        normalizeSimpleTextRewrites (patching.textRewrites or { });

      textPatches =
        normalizePatchList (patching.textPatches or [ ]);

      binaryPatches =
        normalizePatchList (patching.binaryPatches or [ ]);

      elfPatches =
        normalizePatchList (patching.elfPatches or [ ]);
    in
    {
      version = 1;

      root =
        if rootfsPath == null then null else toString rootfsPath;

      scan = {
        roots = scanRoots;
        ignore = ignore;
      };

      rewrite = {
        text = textRewrites;
        runtime = runtime;
      };

      patches = {
        text = textPatches;
        binary = binaryPatches;
        elf = elfPatches;
      };

      validation = validation';
    };
}
