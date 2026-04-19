{
  lib,
  rustPlatform,
}:

rustPlatform.buildRustPackage {
  pname = "rootfs-patcher";
  version = "0.1.0";

  src = ./rootfs-patcher-src;

  cargoHash = "sha256-/of5VzkBXY5L31fdmC7NBYzwSQddP8MY+xFN6z0cyio=";

  meta = with lib; {
    description = "Rewrite, patch, and scan FHS rootfs trees for embedded /nix/store paths";
    license = licenses.mit;
    platforms = platforms.unix;
    mainProgram = "rootfs-patcher";
  };
}
