# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  config,
  lib,
  pkgs,
  ...
}: let
  configHost = config;
  vmName = "virtgpu-vm";
  # The socket is created in /tmp because it is accessible to both microvm and ghaf users
  gpuSocket = "/tmp/crosvmgpu.sock";
  run-sommelier = with pkgs;
    writeScriptBin "run-sommelier" ''
      #!${runtimeShell} -e
      exec ${sommelier}/bin/sommelier --virtgpu-channel -- $@
    '';
  run-wayland-proxy = with pkgs;
    writeScriptBin "run-wayland-proxy" ''
      #!${runtimeShell} -e
      exec ${wayland-proxy-virtwl}/bin/wayland-proxy-virtwl --virtio-gpu -- $@
    '';
  run-waypipe = with pkgs;
    writeScriptBin "run-waypipe" ''
      #!${runtimeShell} -e
      exec ${waypipe}/bin/waypipe --vsock -s 2:6000 server $@
    '';
  virtgpuvmBaseConfiguration = {
    imports = [
      (import ./common/vm-networking.nix {
        inherit vmName;
        macAddress = "02:00:00:03:05:01";
      })
      ({
        lib,
        pkgs,
        ...
      }: {
        ghaf = {
          users.accounts.enable = lib.mkDefault configHost.ghaf.users.accounts.enable;

          development = {
            ssh.daemon.enable = lib.mkDefault configHost.ghaf.development.ssh.daemon.enable;
            debug.tools.enable = lib.mkDefault configHost.ghaf.development.debug.tools.enable;
            nix-setup.enable = lib.mkDefault configHost.ghaf.development.nix-setup.enable;
          };
        };

        # SSH is very picky about the file permissions and ownership and will
        # accept neither direct path inside /nix/store or symlink that points
        # there. Therefore we copy the file to /etc/ssh/get-auth-keys (by
        # setting mode), instead of symlinking it.
        environment.etc."ssh/get-auth-keys" = {
          source = let
            script = pkgs.writeShellScriptBin "get-auth-keys" ''
              [[ "$1" != "ghaf" ]] && exit 0
              ${pkgs.coreutils}/bin/cat /run/waypipe-ssh-public-key/id_ed25519.pub
            '';
          in "${script}/bin/get-auth-keys";
          mode = "0555";
        };
        services.openssh = {
          authorizedKeysCommand = "/etc/ssh/get-auth-keys";
          authorizedKeysCommandUser = "nobody";
        };

        system.stateVersion = lib.trivial.release;

        nixpkgs.buildPlatform.system = configHost.nixpkgs.buildPlatform.system;
        nixpkgs.hostPlatform.system = configHost.nixpkgs.hostPlatform.system;

        environment.systemPackages = [
          pkgs.sommelier
          pkgs.wayland-proxy-virtwl
          pkgs.waypipe
          run-sommelier
          run-wayland-proxy
          run-waypipe
          pkgs.zathura
          pkgs.chromium
          pkgs.firefox
        ];

        # DRM fbdev emulation is disabled to get rid of the popup console window that appears when running a VM with virtio-gpu device
        boot.kernelParams = ["drm_kms_helper.fbdev_emulation=false"];

        hardware.opengl.enable = true;

        microvm = {
          optimize.enable = false;
          mem = 4096;
          vcpu = 4;
          hypervisor = "crosvm";
          shares = [
            {
              tag = "waypipe-ssh-public-key";
              source = "/run/waypipe-ssh-public-key";
              mountPoint = "/run/waypipe-ssh-public-key";
              proto = "virtiofs";
            }
            {
              tag = "ro-store";
              source = "/nix/store";
              mountPoint = "/nix/.ro-store";
              proto = "virtiofs";
            }
          ];

          # GPU device is a separate service which is connected over vhost-user protocol
          crosvm.extraArgs = ["--vhost-user" "gpu,socket=${gpuSocket}"];

          # VSOCK is required for waypipe, 3 is the first available CID
          vsock.cid = 3;
        };
        fileSystems."/run/waypipe-ssh-public-key".options = ["ro"];

        imports = [../../../common];
      })
    ];
  };
  cfg = config.ghaf.virtualization.microvm.virtgpuvm;
in {
  options.ghaf.virtualization.microvm.virtgpuvm = {
    enable = lib.mkEnableOption "VirtgpuVM";

    extraModules = lib.mkOption {
      description = ''
        List of additional modules to be imported and evaluated as part of
        VirtgpuVM's NixOS configuration.
      '';
      default = [];
    };
  };

  config = lib.mkIf cfg.enable {
    microvm.vms."${vmName}" = {
      config = virtgpuvmBaseConfiguration // {imports = virtgpuvmBaseConfiguration.imports ++ cfg.extraModules;};
      specialArgs = {inherit lib;};
    };

    # This directory needs to be created before any of the microvms start.
    systemd.services."create-waypipe-ssh-public-key-directory" = let
      script = pkgs.writeShellScriptBin "create-waypipe-ssh-public-key-directory" ''
        mkdir -pv /run/waypipe-ssh-public-key
        chown -v microvm /run/waypipe-ssh-public-key
      '';
    in {
      enable = true;
      description = "Create shared directory on host";
      path = [];
      wantedBy = ["microvms.target"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal";
        StandardError = "journal";
        ExecStart = "${script}/bin/create-waypipe-ssh-public-key-directory";
      };
    };

    # Waypipe client service is needed for the run-waypipe script to work
    systemd.user.services.waypipe = {
      enable = true;
      description = "waypipe";
      after = ["weston.service" "labwc.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.waypipe}/bin/waypipe --vsock -s 6000 client";
        Restart = "always";
        RestartSec = "1";
      };
      startLimitIntervalSec = 0;
      wantedBy = ["ghaf-session.target"];
    };

    # This service creates a crosvm backend GPU device
    systemd.user.services.crosvmgpu = let
      startScript = pkgs.writeShellScriptBin "start-crosvmgpu" ''
        rm -f ${gpuSocket}
        ${pkgs.crosvm}/bin/crosvm device gpu --socket ${gpuSocket} --wayland-sock $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY --params '{"context-types":"virgl:virgl2:cross-domain","egl":true,"vulkan":true}'
      '';
      postStartScript = pkgs.writeShellScriptBin "poststart-crosvmgpu" ''
        while ! [ -S ${gpuSocket} ]; do
              sleep .1
        done
        chgrp video ${gpuSocket}
        chmod 775 ${gpuSocket}
      '';
    in {
      enable = true;
      description = "crosvm gpu device";
      after = ["weston.service" "labwc.service"];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${startScript}/bin/start-crosvmgpu";
        ExecStartPost = "${postStartScript}/bin/poststart-crosvmgpu";
        Restart = "always";
        RestartSec = "1";
      };
      startLimitIntervalSec = 0;
      wantedBy = ["ghaf-session.target"];
    };
    users.users."microvm".extraGroups = ["video"];
  };
}
