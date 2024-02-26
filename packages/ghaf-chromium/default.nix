# Copyright 2022-2024 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenvNoCC,
  pkgs,
  lib,
  ...
}: let
  # Disable chromium built-in PDF viewer to make it execute xdg-open
  initialPrefs = {
    plugins = {
      always_open_pdf_externally = true;
    };
  };
  initialPrefsFile = pkgs.writeText "initial_preferences" (builtins.toJSON initialPrefs);
in
  stdenvNoCC.mkDerivation {
    name = "ghaf-chromium";

    phases = ["installPhase"];

    installPhase = ''
      mkdir -p $out
      cp -R ${pkgs.chromium}/* $out/
      chmod +w $out/bin
      chmod +w $out/bin/chromium
      sed -i "s|${pkgs.chromium.passthru.browser}|$out/browser|g" $out/bin/chromium
      mkdir $out/browser
      cp -R ${pkgs.chromium.passthru.browser}/* $out/browser
      chmod +w $out/browser/libexec/chromium
      cp ${initialPrefsFile} $out/browser/libexec/chromium/initial_preferences
    '';

    meta = with lib; {
      description = "Ghaf Chromium Browser";
      platforms = [
        "x86_64-linux"
      ];
    };
  }
