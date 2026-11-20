# The ghostfolio module's namespace in the `finance` area of the Home dashboard, whose CPU, memory and traffic graphs
# sum the containers by area
{ inputs, ... }:
{ config, lib, ... }:
{
  imports = [ inputs.homelab-monitoring.nixosModules.grafana ];
  config.homelab.grafana.home.areas.finance = {
    color = "#fade2a";
    namespaces = lib.mkIf config.homelab.ghostfolio.enable [ "ghostfolio" ];
  };
}
