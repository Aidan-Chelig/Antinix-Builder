{ lib }:

let
  sortNames = attrs:
    builtins.sort builtins.lessThan (builtins.attrNames attrs);

  normalizePasswordField =
    user:
    if user ? hashedPassword && user.hashedPassword != null then
      user.hashedPassword
    else if user ? password && user.password != null then
      user.password
    else
      "!";

  # Very small policy helper:
  # - root gets /root
  # - everyone else gets /home/<name> if not already normalized upstream
  normalizeHome =
    name: user:
    user.home or (if name == "root" then "/root" else "/home/${name}");

  normalizeShell =
    _name: user:
    user.shell or "/bin/sh";

  normalizeDescription =
    name: user:
    if (user.description or "") != "" then user.description else name;

  normalizePrimaryGroup =
    name: user:
    user.group or (if name == "root" then "root" else name);

  inferGroupGids =
    groups:
    let
      names = sortNames groups;
      step =
        state: name:
        let
          group = groups.${name};
          gid =
            if group.gid != null
            then group.gid
            else state.nextGid;
          nextGid =
            if group.gid != null
            then builtins.max state.nextGid (group.gid + 1)
            else state.nextGid + 1;
        in
        {
          nextGid = nextGid;
          gids = state.gids // {
            "${name}" = gid;
          };
        };
    in
    (lib.foldl' step { nextGid = 1000; gids = { root = 0; }; } names).gids;

  inferUserUids =
    users:
    let
      names = sortNames users;
      step =
        state: name:
        let
          user = users.${name};
          uid =
            if user.uid != null
            then user.uid
            else if name == "root"
            then 0
            else state.nextUid;
          nextUid =
            if user.uid != null
            then builtins.max state.nextUid (user.uid + 1)
            else if name == "root"
            then state.nextUid
            else state.nextUid + 1;
        in
        {
          nextUid = nextUid;
          uids = state.uids // {
            "${name}" = uid;
          };
        };
    in
    (lib.foldl' step { nextUid = 1000; uids = { root = 0; }; } names).uids;

  mkPasswdLine =
    {
      name,
      user,
      uid,
      gid,
    }:
    let
      description = normalizeDescription name user;
      home = normalizeHome name user;
      shell = normalizeShell name user;
    in
    "${name}:x:${toString uid}:${toString gid}:${description}:${home}:${shell}";

  mkGroupMembers =
    userName: user:
    user.extraGroups or [ ];

  invertExtraGroups =
    users:
    let
      names = sortNames users;
      step =
        acc: name:
        let
          memberships = mkGroupMembers name users.${name};
        in
        lib.foldl'
          (
            groupAcc: groupName:
            groupAcc // {
              ${groupName} = (groupAcc.${groupName} or [ ]) ++ [ name ];
            }
          )
          acc
          memberships;
    in
    lib.foldl' step { } names;

  mkGroupLine =
    {
      name,
      gid,
      members,
    }:
    "${name}:x:${toString gid}:${lib.concatStringsSep "," members}";

  mkShadowLine =
    {
      name,
      passwordField,
    }:
    # Fields:
    # login:passwd:lastchg:min:max:warn:inactive:expire:flag
    "${name}:${passwordField}:0:0:99999:7:::";

  mkProfileText =
    {
      hostname ? "localhost",
      extraText ? "",
    }:
    ''
      export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${"$"}{PATH:+:${"$"}PATH}"
      export HOSTNAME=${lib.escapeShellArg hostname}
    ''
    + lib.optionalString (extraText != "") ("\n${extraText}\n");

in
{
  build =
    {
      users,
      groups,
      hostname ? "localhost",
      profileExtraText ? "",
    }:
    let
      userNames = sortNames users;
      groupNames = sortNames groups;

      groupGids = inferGroupGids groups;
      userUids = inferUserUids users;

      extraGroupMembers = invertExtraGroups users;

      passwdLines =
        map
          (
            name:
            let
              user = users.${name};
              primaryGroup = normalizePrimaryGroup name user;
            in
            mkPasswdLine {
              inherit name user;
              uid = userUids.${name};
              gid = groupGids.${primaryGroup};
            }
          )
          userNames;

      groupLines =
        map
          (
            name:
            mkGroupLine {
              inherit name;
              gid = groupGids.${name};
              members = extraGroupMembers.${name} or [ ];
            }
          )
          groupNames;

      shadowLines =
        map
          (
            name:
            mkShadowLine {
              inherit name;
              passwordField = normalizePasswordField users.${name};
            }
          )
          userNames;

      homeDirs =
        builtins.listToAttrs (
          map
            (
              name:
              let
                user = users.${name};
              in
              {
                name = normalizeHome name user;
                value = {
                  user = name;
                  group = normalizePrimaryGroup name user;
                  mode =
                    if name == "root" then "0700" else "0755";
                };
              }
            )
            (
              builtins.filter
                (name: users.${name}.createHome or false)
                userNames
            )
        );
    in
    {
      passwdText = lib.concatStringsSep "\n" passwdLines + "\n";
      groupText = lib.concatStringsSep "\n" groupLines + "\n";
      shadowText = lib.concatStringsSep "\n" shadowLines + "\n";
      profileText = mkProfileText {
        inherit hostname;
        extraText = profileExtraText;
      };

      inherit homeDirs userUids groupGids;
    };
}
