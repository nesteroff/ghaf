# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
#
# Generic x86_64 computer -target
{
  self,
  lib,
  nixos-generators,
  nixos-hardware,
  microvm,
}: let
  name = "generic-x86_64";
  system = "x86_64-linux";
  formatModule = nixos-generators.nixosModules.raw-efi;
  generic-x86 = variant: extraModules: let
    netvmExtraModules = [
      {
        microvm.devices = [
          {
            bus = "pci";
            path = "0000:00:14.3";
          }
        ];

        # For WLAN firmwares
        hardware.enableRedistributableFirmware = true;

        networking.wireless = {
          enable = true;

          # networks."SSID_OF_NETWORK".psk = "WPA_PASSWORD";
        };
      }
    ];
    guivmExtraModules = [
      {
        microvm.qemu.extraArgs = [
          "-usb"
          "-device" "usb-host,vendorid=0x046d,productid=0xc534"
        ];
        microvm.devices = [
          {
            bus = "pci";
            path = "0000:00:02.0";
          }
        ];
      }
    ];
    appvmExtraModules = [{ }];
    hostConfiguration = lib.nixosSystem {
      inherit system;
      specialArgs = {inherit lib;};
      modules =
        [
          microvm.nixosModules.host
          ../modules/host
          ../modules/virtualization/microvm/microvm-host.nix
          ../modules/virtualization/microvm/netvm.nix
          ../modules/virtualization/microvm/guivm.nix
          ../modules/virtualization/microvm/appvm.nix
          ({ pkgs, ...}: {
            ghaf = {
              hardware.x86_64.common.enable = true;

              virtualization.microvm-host.enable = true;
              host.networking.enable = true;
              virtualization.microvm = {
                netvm = {
                  enable = true;
                  extraModules = netvmExtraModules;
                };
                guivm = {
                  enable = true;
                  extraModules = guivmExtraModules;
                };
                appvm = {
                  enable = true;
                  apps = with pkgs; [
                    chromium
                    (pkgs.callPackage ../user-apps/gala {})
                    zathura
                  ];
                  extraModules = appvmExtraModules;
                };
              };

              # Enable all the default UI applications
              profiles = {
                #TODO clean this up when the microvm is updated to latest
                release.enable = variant == "release";
                debug.enable = variant == "debug";
              };
            };
            # Group kvm needs to access to USB keyboard and mouse for guivm USB passthrough 
            services.udev.extraRules= "SUBSYSTEM==\"usb\",ATTR{idVendor}==\"046d\",ATTR{idProduct}==\"c534\",GROUP+=\"kvm\"";
          })

          formatModule

          #TODO: how to handle the majority of laptops that need a little
          # something extra?
          # SEE: https://github.com/NixOS/nixos-hardware/blob/master/flake.nix
          # nixos-hardware.nixosModules.lenovo-thinkpad-x1-10th-gen

          {
            boot.kernelParams = [
              "intel_iommu=on,igx_off,sm_on"
              "iommu=pt"

              # TODO: Change per your device
              # Passthrough Intel WiFi card 8086:02f0
              # Passthrough Intel Embedded GPU 8086:9b41
              "vfio-pci.ids=8086:02f0,8086:9b41"
            ];
          }
        ]
        ++ (import ../modules/module-list.nix)
        ++ extraModules;
    };
  in {
    inherit hostConfiguration;
    name = "${name}-${variant}";
    package = hostConfiguration.config.system.build.${hostConfiguration.config.formatAttr};
  };
  debugModules = [../modules/development/usb-serial.nix {ghaf.development.usb-serial.enable = true;}];
  targets = [
    (generic-x86 "debug" debugModules)
    (generic-x86 "release" [])
  ];
in {
  nixosConfigurations =
    builtins.listToAttrs (map (t: lib.nameValuePair t.name t.hostConfiguration) targets);
  packages = {
    x86_64-linux =
      builtins.listToAttrs (map (t: lib.nameValuePair t.name t.package) targets);
  };
}
