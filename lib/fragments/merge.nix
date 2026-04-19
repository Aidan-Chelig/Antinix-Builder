{ lib, schema }:

let
  inherit (schema) defaults;

  listKeys = [
    "packages"
    "postBuild"
  ];

  recursiveListKeys = [
    [ "runtime" "tmpfsDirs" ]
    [ "runtime" "stateDirs" ]
    [ "runtime" "dataDirs" ]

    [ "patching" "extraSearchPaths" ]
    [ "patching" "ignore" "paths" ]
    [ "patching" "ignore" "suffixes" ]
    [ "patching" "ignore" "extensions" ]
    [ "patching" "ignore" "globs" ]

    [ "patching" "textPatches" ]
    [ "patching" "binaryPatches" ]
    [ "patching" "elfPatches" ]
  ];

  scalarKeys = [
    "name"
    "hostname"
    "motd"
  ];

  recursiveAttrsMerge =
    a: b:
    lib.recursiveUpdate a b;

  getPathOr =
    path: fallback: set:
    lib.attrByPath path fallback set;

  setPath =
    path: value:
    lib.setAttrByPath path value;

  mergeListsAtPath =
    path: a: b:
    let
      av = getPathOr path [ ] a;
      bv = getPathOr path [ ] b;
    in
    setPath path (av ++ bv);

  mergeUsers =
    aUsers: bUsers:
    lib.zipAttrsWith
      (
        _name: vals:
        let
          merged = lib.foldl'
            (
              acc: v:
              recursiveAttrsMerge acc v
            )
            { }
            vals;

          mergedExtraGroups =
            lib.unique (lib.concatLists (map (v: v.extraGroups or [ ]) vals));
        in
        merged
        // lib.optionalAttrs (merged ? extraGroups) {
          extraGroups = mergedExtraGroups;
        }
      )
      [ aUsers bUsers ];

  mergeGroups =
    aGroups: bGroups:
    recursiveAttrsMerge aGroups bGroups;

  mergeScalarKeys =
    a: b:
    builtins.listToAttrs (
      map
        (
          key:
          {
            name = key;
            value =
              let
                bVal = b.${key} or null;
              in
              if bVal != null then bVal else (a.${key} or null);
          }
        )
        scalarKeys
    );

  mergeListKeys =
    a: b:
    builtins.listToAttrs (
      map
        (
          key:
          {
            name = key;
            value = (a.${key} or [ ]) ++ (b.${key} or [ ]);
          }
        )
        listKeys
    );

  mergeRecursiveListKeys =
    a: b:
    lib.foldl'
      (
        acc: path:
        recursiveAttrsMerge acc (mergeListsAtPath path a b)
      )
      { }
      recursiveListKeys;

  mergeTwo =
    a: b:
    let
      scalarPart = mergeScalarKeys a b;
      listPart = mergeListKeys a b;
      recursiveListPart = mergeRecursiveListKeys a b;
    in
    recursiveAttrsMerge
      (
        recursiveAttrsMerge
          (
            recursiveAttrsMerge
              (
                recursiveAttrsMerge
                  (
                    recursiveAttrsMerge
                      defaults
                      a
                  )
                  b
              )
              scalarPart
          )
          listPart
      )
      (
        recursiveAttrsMerge
          recursiveListPart
          {
            files = recursiveAttrsMerge (a.files or { }) (b.files or { });
            directories = recursiveAttrsMerge (a.directories or { }) (b.directories or { });
            symlinks = recursiveAttrsMerge (a.symlinks or { }) (b.symlinks or { });
            imports = recursiveAttrsMerge (a.imports or { }) (b.imports or { });
            users = mergeUsers (a.users or { }) (b.users or { });
            groups = mergeGroups (a.groups or { }) (b.groups or { });
          }
      );

  mergeMany =
    fragments:
    lib.foldl'
      mergeTwo
      defaults
      fragments;

in
{
  inherit mergeTwo mergeMany;
}
