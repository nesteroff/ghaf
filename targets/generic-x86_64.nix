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
          "-device" "usb-host,vendorid=0x046d,productid=0xc52b"
          "-device" "usb-host,vendorid=0x046d,productid=0xc328"
          "-device" "usb-host,vendorid=0x413c,productid=0x301a"
          "-device" "virtio-input-host-pci,evdev=/dev/input/by-path/platform-i8042-serio-0-event-kbd"
          "-device" "virtio-input-host-pci,evdev=/dev/input/by-path/platform-i8042-serio-1-event-mouse"
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
          ({ pkgs, ...}: let
            vsockproxy = pkgs.callPackage ../user-apps/vsockproxy {};
            in
            {
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
                  vms = with pkgs; [
                    {
                      name = "chromium";
                      packages = [ chromium ];
                      ipAddress = "192.168.101.5/24";
                      macAddress = "02:00:00:03:03:05";
                      ramMb = 3072;
                      cores = 4;
                      cid = 4;
                    }
                    {
                      name = "gala";
                      packages = [ (pkgs.callPackage ../user-apps/gala {}) ];
                      ipAddress = "192.168.101.6/24";
                      macAddress = "02:00:00:03:03:06";
                      ramMb = 1536;
                      cores = 2;
                      cid = 5;
                    }
                    {
                      name = "zathura";
                      packages = [ zathura (pkgs.callPackage ../user-apps/demo-pdf {}) ];
                      ipAddress = "192.168.101.7/24";
                      macAddress = "02:00:00:03:03:07";
                      ramMb = 512;
                      cores = 1;
                      cid = 6;
                    }
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
            services.udev.extraRules = ''
              # Logitech usb dongle
              SUBSYSTEM=="usb",ATTR{idVendor}=="046d",ATTR{idProduct}=="c52b",GROUP="kvm"
              # Logitech corded mouse
              SUBSYSTEM=="usb",ATTR{idVendor}=="046d",ATTR{idProduct}=="c328",GROUP="kvm"
              # Some keyboard
              SUBSYSTEM=="usb",ATTR{idVendor}=="413c",ATTR{idProduct}=="301a",GROUP="kvm"
              # Laptop keyboard
              SUBSYSTEM=="input",ATTRS{name}=="AT Translated Set 2 keyboard",GROUP="kvm"
              # Laptop touchpad
              SUBSYSTEM=="input",ATTRS{name}=="SynPS/2 Synaptics TouchPad",GROUP="kvm"
            '';

            # vsockproxy is needed for guest to guest communication over vsock
            # It listens for incoming connections from app vms on port 1100 (vsock)
            # and forwards data port 1101 of the guivm with cid 3 which is used by waypipe
            systemd.services.vsockproxy = {
              enable = true;
              description = "vsockproxy";
              unitConfig = {
                Type = "simple";
              };
              serviceConfig = {
                ExecStart = "${vsockproxy}/bin/vsockproxy 1100 3 1101";
              };
              wantedBy = [ "multi-user.target" ];
            };
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
              "vfio-pci.ids=8086:a0f0,8086:9a49"
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
