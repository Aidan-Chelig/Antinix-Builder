
{
  lib,
  stdenv,
  fetchFromGitHub,
  meson,
  ninja,
  pkg-config,
  bash,
  audit,
  libcap,
  pam,
}:

stdenv.mkDerivation rec {
  pname = "openrc";
  version = "0.53";

  src = fetchFromGitHub {
    owner = "OpenRC";
    repo = "openrc";
    rev = version;
    hash = "sha256-hHfoAMoQ9FkOVPw1i+i6ZAGehfy3yOCFCLTZzEFwwEQ=";
  };

  nativeBuildInputs = [
    meson
    ninja
    pkg-config
  ];

  buildInputs = [
    bash
    libcap
    pam
    audit
  ];

  # OpenRC's Meson install layout wants real root-style paths like /lib and /sbin.
  # That fights the normal nixpkgs Meson hook, so do the phases manually with
  # prefix=/ and DESTDIR=$out.
  configurePhase = ''
    runHook preConfigure

    meson setup build \
      --prefix=/ \
      --bindir=/bin \
      --sbindir=/sbin \
      --libdir=/lib \
      --libexecdir=/lib \
      --sysconfdir=/etc \
      --localstatedir=/var \
      -Dos=Linux \
      -Dselinux=disabled \
      -Dpam=true \
      ${lib.optionalString (audit != null) "-Daudit=enabled"} \
      ${lib.optionalString (audit == null) "-Daudit=disabled"}

    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    ninja -C build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    DESTDIR="$out" meson install -C build --no-rebuild
    runHook postInstall
  '';

  meta = with lib; {
    description = "OpenRC init system";
    homepage = "https://github.com/OpenRC/openrc";
    license = licenses.bsd2;
    platforms = platforms.linux;
  };
}
