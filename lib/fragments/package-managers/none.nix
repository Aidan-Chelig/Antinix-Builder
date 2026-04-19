{ }:

{ }:
{
  name = "no-package-manager";

  packages = [ ];

  services = {
    packageManager.name = "none";
  };

  meta = {
    providesPackageManager = false;
  };
}
