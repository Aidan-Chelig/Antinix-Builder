{
  lib,
  buildGoModule,
}:

buildGoModule {
  pname = "dracut-shell-parser";
  version = "0.1.0";

  src = ./dracut-shell-parser-src;
  goSum = ./dracut-shell-parser-src/go.sum;

  vendorHash = "sha256-96W+NipSuAERDcT5peWDkU96OmH4C1a5Yd38YaV/+8E=";

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
  ];

  meta = with lib; {
    description = "Shell AST command extractor for dracut scripts";
    license = licenses.mit;
    platforms = platforms.linux ++ platforms.darwin;
  };
}
