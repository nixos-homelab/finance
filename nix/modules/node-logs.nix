# The console of the Actual Budget API's clients (the exporter, ghostbudget's sync): winston's `level: message {meta}`,
# bare lines, and objects console.log pretty-prints over several lines ([Breadcrumb] { ... }). Imported by their logs.nix;
# the key keeps it to one definition
{ inputs, ... }:
{ ... }:
{
  key = "${toString __curPos.file}#modules.nixos.node-logs";
  imports = [ inputs.homelab-monitoring.nixosModules.alloy ];
  config.homelab.alloy.logs.formats.actual-client = {
    # An object's indented lines and its closing brace belong to the line that opened it
    firstline = "^(?:\\x1b\\[[0-9;]*m)*[^\\s}]";
    decolorize = true;
    stages = ''
      stage.template {
        source   = "message"
        template = "{{ .Entry }}"
      }
      stage.regex {
        expression = "^(?P<level>error|warn|info|http|verbose|debug|silly): (?P<message>.*?)(?: \\{.*\\})?$"
      }
    '';
    levels.debug = [ "silly" ];
    levels.verbose = [ "http" ];
  };
}
