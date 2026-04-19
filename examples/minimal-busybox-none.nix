{ pkgs, antinix }:

antinix.mkSystem {
  name = "minimal-busybox-none";
  hostname = "antinix";
  init = "busybox";
  packageManager = "none";

  buildTarball = true;
  buildImage = true;

  packages = [
    pkgs.busybox
  ];

  users = {
    root = antinix.schema.mkUser {
      isNormalUser = false;
      uid = 0;
      group = "root";
      home = "/root";
      shell = "/bin/sh";
      createHome = true;
      description = "root";
      hashedPassword = "$6$wP4WOkSH2cPLBH8w$jhyzYxkm5JHpO5x6vz8L5bbPXGLDAvixvJCSgq/YUlHPbIRPSHg45s3BlIk81prVwYp92sEpFuVh73oWt..jo0";
    };
  };

  groups = {
    root = antinix.schema.mkGroup {
      gid = 0;
    };
  };

  files."/etc/issue" = antinix.schema.mkFile {
    text = ''
      antinix
      minimal busybox system
    '';
    mode = "0644";
  };

  directories."/var/empty" = antinix.schema.mkDirectory {
    mode = "0755";
  };
}
