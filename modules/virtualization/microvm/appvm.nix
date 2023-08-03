# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  configHost = config;
  cfg = config.ghaf.virtualization.microvm.appvm;
  waypipe-ssh = pkgs.callPackage ../../../user-apps/waypipe-ssh {};

  makeVm = { vm, index }: let
      appvmConfiguration = {
        imports = [
          ({lib, config, ...}: {
            ghaf = {
              users.accounts.enable = lib.mkDefault configHost.ghaf.users.accounts.enable;
              profiles.graphics.enable = true;

              development = {
                # NOTE: SSH port also becomes accessible on the network interface
                #       that has been passed through to NetVM
                ssh.daemon.enable = lib.mkDefault configHost.ghaf.development.ssh.daemon.enable;
                debug.tools.enable = lib.mkDefault configHost.ghaf.development.debug.tools.enable;
              };
            };

            users.users.${configHost.ghaf.users.accounts.user}.openssh.authorizedKeys.keyFiles = ["${waypipe-ssh}/keys/waypipe-ssh.pub"];

            networking.hostName = vm.name;
            system.stateVersion = lib.trivial.release;

            nixpkgs.buildPlatform.system = configHost.nixpkgs.buildPlatform.system;
            nixpkgs.hostPlatform.system = configHost.nixpkgs.hostPlatform.system;

            networking = {
              enableIPv6 = false;
              interfaces.ethint0.useDHCP = false;
              firewall.allowedTCPPorts = [22];
              firewall.allowedUDPPorts = [67];
              useNetworkd = true;
            };

            microvm = {
              mem = 2048;
              hypervisor = "qemu";
              qemu.bios.enable = true;
              storeDiskType = "squashfs";
              interfaces = [{
                type = "tap";
                id = vm.name;
                mac = vm.macAddress;
              }];
            };

            networking.nat = {
              enable = true;
              internalInterfaces = ["ethint0"];
            };

            # Set internal network's interface name to ethint0
            systemd.network.links."10-ethint0" = {
              matchConfig.PermanentMACAddress = vm.macAddress;
              linkConfig.Name = "ethint0";
            };

            systemd.network = {
              enable = true;
              networks."10-ethint0" = {
                matchConfig.MACAddress = vm.macAddress;
                addresses = [
                  {
                    # IP-address for debugging subnet
                    addressConfig.Address = vm.ipAddress;
                  }
                ];
                routes = [
                  { routeConfig.Gateway = "192.168.101.1"; }
                ];
                linkConfig.RequiredForOnline = "routable";
                linkConfig.ActivationPolicy = "always-up";
              };
            };

            imports = import ../../module-list.nix;
          })
        ];
      };
    in
    {
      autostart = true;
      config = appvmConfiguration // { imports = appvmConfiguration.imports ++ cfg.extraModules ++ [{ environment.systemPackages = vm.packages; }]; };
      specialArgs = { inherit lib; };
    };
in
{
  options.ghaf.virtualization.microvm.appvm = with lib; {
    enable = lib.mkEnableOption "appvm";
    vms = with types; mkOption {
      type = lib.types.listOf (submodule {
        options = {
          name = mkOption { type = str; };
          packages = mkOption { type = types.listOf package; default = [ ]; };
          ipAddress = mkOption { type = str; };
          macAddress = mkOption { type = str; };
          ramMb = mkOption { type = int; };
        };
      });
      default = [ ];
    };

    extraModules = mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        appvm's NixOS configuration.
      '';
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms = (
      let vms = lib.imap0 (index: vm: { "appvm-${vm.name}" = makeVm { inherit vm index; }; }) cfg.vms;
      in lib.foldr lib.recursiveUpdate { } vms
    );
  };
}
