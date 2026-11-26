# The saxo-sync binary: Go's standard library only, static
{ buildGoModule }:
buildGoModule {
  pname = "saxo-sync";
  version = "0.1.0";
  src = ./src;
  vendorHash = null;
  env.CGO_ENABLED = 0;
  ldflags = [
    "-s"
    "-w"
  ];
  meta.mainProgram = "saxo-sync";
}
