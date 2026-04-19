{
  lib,
  schema,
  merge,
  normalize,
  mkRootfsTree,
  mkRootfsTarball ? null,
  mkRootfsImage ? null,
  initSystems,
  packageManagers,
}:

let
  availableInitSystems = builtins.attrNames initSystems;
  availablePackageManagers = builtins.attrNames packageManagers;

  getInitFragment =
    init:
    initSystems.${init} or (throw ''
      Unknown init system: ${init}
      Available init systems: ${lib.concatStringsSep ", " availableInitSystems}
    '');

  getPackageManagerFragment =
    packageManager:
    packageManagers.${packageManager} or (throw ''
      Unknown package manager: ${packageManager}
      Available package managers: ${lib.concatStringsSep ", " availablePackageManagers}
    '');

  baseFragmentFromArgs =
    {
      name ? null,
      hostname ? "localhost",
      motd ? null,
      packages ? [ ],
      files ? { },
      directories ? { },
      symlinks ? { },
      environment ? { },
      users ? { },
      groups ? { },
      services ? { },
      runtime ? { },
      postBuild ? [ ],
      patching ? { },
      validation ? { },
      meta ? { },
    }:
    {
      inherit
        name
        hostname
        motd
        packages
        files
        directories
        symlinks
        environment
        users
        groups
        services
        runtime
        postBuild
        patching
        validation
        meta
        ;
    };

in
args@{
  name ? null,
  hostname ? "localhost",
  init ? "busybox",
  packageManager ? "none",

  fragments ? [ ],

  packages ? [ ],
  files ? { },
  directories ? { },
  symlinks ? { },
  environment ? { },
  motd ? null,
  users ? { },
  groups ? { },
  services ? { },
  runtime ? { },
  postBuild ? [ ],
  patching ? { },
  validation ? { },
  meta ? { },

  buildTarball ? false,
  buildImage ? false,

  ...
}:
let
  initFragment = getInitFragment init;
  packageManagerFragment = getPackageManagerFragment packageManager;

  userBaseFragment = baseFragmentFromArgs {
    inherit
      name
      hostname
      motd
      packages
      files
      directories
      symlinks
      environment
      users
      groups
      services
      runtime
      postBuild
      patching
      validation
      meta
      ;
  };

  mergedFragment =
    merge.mergeMany (
      [
        initFragment
        packageManagerFragment
      ]
      ++ fragments
      ++ [ userBaseFragment ]
    );

  normalizedSpec = normalize mergedFragment;

  systemName =
    if normalizedSpec.name != null then normalizedSpec.name else "rootfs";

  rootfs = mkRootfsTree normalizedSpec;

  tarball =
    if buildTarball && mkRootfsTarball != null
    then mkRootfsTarball {
      rootfs = rootfs;
      name = systemName;
      users = normalizedSpec.users or { };
      groups = normalizedSpec.groups or { };
    }
    else null;

  image =
    if buildImage && mkRootfsImage != null
    then mkRootfsImage {
      rootfsTarball =
        if tarball != null
        then tarball
        else mkRootfsTarball {
          rootfs = rootfs;
          name = systemName;
          users = normalizedSpec.users or { };
          groups = normalizedSpec.groups or { };
        };
      name = systemName;
      volumeLabel = systemName;
    }
    else null;
in
{
  inherit
    init
    packageManager
    mergedFragment
    normalizedSpec
    rootfs
    tarball
    image
    ;

  config = normalizedSpec;

  meta =
    (normalizedSpec.meta or { })
    // {
      systemName = systemName;
      selectedInit = init;
      selectedPackageManager = packageManager;
    };
}
