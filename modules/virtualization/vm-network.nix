# NAT network for the VMs on a bridge with no physical ports: NAT towards
# whatever interface the PC uses (Wi-Fi, cable, VPN); DHCP + DNS with dnsmasq.
{ config, lib, ... }:
let
  cfg = config.my.virtualization.vmNetwork;
  cidr = "${cfg.network}/${toString cfg.prefixLength}";
in
{
  options.my.virtualization.vmNetwork = {
    enable = lib.mkEnableOption "NAT network for the VMs";

    bridge = lib.mkOption { type = lib.types.str; default = "vmbr1"; };
    network = lib.mkOption { type = lib.types.str; default = "172.30.20.0"; };
    address = lib.mkOption {
      type = lib.types.str;
      default = "172.30.20.1";
      description = "Host IP on the bridge = gateway and DNS of the VMs.";
    };
    prefixLength = lib.mkOption { type = lib.types.int; default = 24; };
    domain = lib.mkOption { type = lib.types.str; default = "vm.lan"; };

    externalInterface = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "null = NAT towards any interface (ideal for laptops).";
    };

    trustVMs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "VMs can reach all host services (firewall open on the bridge).";
    };

    dhcp = {
      enable = lib.mkOption { type = lib.types.bool; default = true; };
      rangeStart = lib.mkOption { type = lib.types.str; default = "172.30.20.100"; };
      rangeEnd = lib.mkOption { type = lib.types.str; default = "172.30.20.250"; };
      leaseTime = lib.mkOption { type = lib.types.str; default = "12h"; };
      staticLeases = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            mac = lib.mkOption { type = lib.types.str; example = "BC:24:11:00:00:01"; };
            ip = lib.mkOption { type = lib.types.str; example = "172.30.20.10"; };
            name = lib.mkOption { type = lib.types.str; example = "win11"; };
          };
        });
        default = [ ];
        description = "Static IPs for the VMs (MAC shown in Proxmox > VM > Hardware > Network).";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    networking.bridges.${cfg.bridge}.interfaces = [ ];
    networking.interfaces.${cfg.bridge}.ipv4.addresses = [{
      address = cfg.address;
      prefixLength = cfg.prefixLength;
    }];

    # NetworkManager must not touch the bridge and the VM interfaces
    networking.networkmanager.unmanaged = [
      "interface-name:${cfg.bridge}"
      "interface-name:tap*"
      "interface-name:veth*"
      "interface-name:fwbr*"
      "interface-name:fwpr*"
      "interface-name:fwln*"
    ];

    networking.nat = {
      enable = true;
      internalInterfaces = [ cfg.bridge ];
      internalIPs = [ cidr ];
      externalInterface = cfg.externalInterface;
    };

    networking.firewall.trustedInterfaces = lib.optional cfg.trustVMs cfg.bridge;
    networking.firewall.interfaces.${cfg.bridge} = lib.mkIf (!cfg.trustVMs) {
      allowedUDPPorts = [ 53 67 ];
      allowedTCPPorts = [ 53 8006 ];
    };

    services.dnsmasq = lib.mkIf cfg.dhcp.enable {
      enable = true;
      # the host keeps using NetworkManager's DNS (important for AD)
      resolveLocalQueries = false;
      settings = {
        interface = cfg.bridge;
        bind-dynamic = true;
        except-interface = "lo";
        domain = cfg.domain;
        local = "/${cfg.domain}/";
        expand-hosts = true;
        dhcp-authoritative = true;
        dhcp-range = [ "${cfg.dhcp.rangeStart},${cfg.dhcp.rangeEnd},${cfg.dhcp.leaseTime}" ];
        dhcp-option = [
          "option:router,${cfg.address}"
          "option:dns-server,${cfg.address}"
        ];
        dhcp-host = map (l: "${l.mac},${l.ip},${l.name}") cfg.dhcp.staticLeases;
        address = [ "/host.${cfg.domain}/${cfg.address}" ];
      };
    };

    # dnsmasq must start after the bridge has its address
    systemd.services.dnsmasq = lib.mkIf cfg.dhcp.enable {
      after = [ "network-addresses-${cfg.bridge}.service" ];
      wants = [ "network-addresses-${cfg.bridge}.service" ];
    };
  };
}
