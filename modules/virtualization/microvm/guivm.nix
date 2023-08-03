# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  configHost = config;
  waypipe-ssh = pkgs.callPackage ../../../user-apps/waypipe-ssh {};
  demo-pdf = (pkgs.callPackage ../../../user-apps/demo-pdf {});

  guivmBaseConfiguration = {
    imports = [
      ({lib, pkgs, ...}: {
        ghaf = {
          users.accounts.enable = lib.mkDefault configHost.ghaf.users.accounts.enable;
          profiles.graphics.enable = true;
          profiles.applications.enable = false;
          windows-launcher.enable = false;
          development = {
            # NOTE: SSH port also becomes accessible on the network interface
            #       that has been passed through to NetVM
            ssh.daemon.enable = lib.mkDefault configHost.ghaf.development.ssh.daemon.enable;
            debug.tools.enable = lib.mkDefault configHost.ghaf.development.debug.tools.enable;
          };
          graphics.weston.launchers = [
            {
              path = "${pkgs.waypipe}/bin/waypipe ssh -i ${waypipe-ssh}/keys/waypipe-ssh -o StrictHostKeyChecking=no 192.168.101.5 chromium --enable-features=UseOzonePlatform --ozone-platform=wayland";
              icon = "${pkgs.weston}/share/weston/icon_editor.png";
            }

            {
              path = "${pkgs.waypipe}/bin/waypipe ssh -i ${waypipe-ssh}/keys/waypipe-ssh -o StrictHostKeyChecking=no 192.168.101.6 gala --enable-features=UseOzonePlatform --ozone-platform=wayland";
              icon = "${pkgs.weston}/share/weston/icon_editor.png";
            }

            {
              path = "${pkgs.waypipe}/bin/waypipe ssh -i ${waypipe-ssh}/keys/waypipe-ssh -o StrictHostKeyChecking=no 192.168.101.7 zathura ${demo-pdf}/Whitepaper.pdf";
              icon = "${pkgs.weston}/share/weston/icon_editor.png";
            }
          ];
        };

        environment.etc = {
          "ssh/waypipe-ssh".source = "${waypipe-ssh}/keys/waypipe-ssh";
        };

        networking.hostName = "guivm";
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
          qemu.bios.enable = false;
          storeDiskType = "squashfs";
          interfaces = [{
            type = "tap";
            id = "vm-guivm";
            mac = "02:00:00:02:02:02";
          }];
        };

        networking.nat = {
          enable = true;
          internalInterfaces = ["ethint0"];
        };

        # Set internal network's interface name to ethint0
        systemd.network.links."10-ethint0" = {
          matchConfig.PermanentMACAddress = "02:00:00:02:02:02";
          linkConfig.Name = "ethint0";
        };

        systemd.network = {
          enable = true;
          networks."10-ethint0" = {
            matchConfig.MACAddress = "02:00:00:02:02:02";
            addresses = [
              {
                # IP-address for debugging subnet
                addressConfig.Address = "192.168.101.3/24";
              }
            ];
            routes =  [
              { routeConfig.Gateway = "192.168.101.1"; }
            ];
            linkConfig.RequiredForOnline = "routable";
            linkConfig.ActivationPolicy = "always-up";
          };
        };

        imports = import ../../module-list.nix;

        services.udev.extraRules = ''
          ACTION=="add",SUBSYSTEM=="backlight",KERNEL=="intel_backlight",RUN+="${pkgs.bash}/bin/sh -c '${pkgs.coreutils}/bin/echo 120000 > /sys/class/backlight/intel_backlight/brightness'"
        '';
      })
    ];
  };
  cfg = config.ghaf.virtualization.microvm.guivm;
in {
  options.ghaf.virtualization.microvm.guivm = {
    enable = lib.mkEnableOption "GUIVM";

    extraModules = lib.mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        GUIVM's NixOS configuration.
      '';
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms."guivm" = {
      autostart = true;
      config =
        guivmBaseConfiguration
        // {
          imports =
            guivmBaseConfiguration.imports
            ++ cfg.extraModules;
        };
      specialArgs = {inherit lib;};
    };
  };
}
