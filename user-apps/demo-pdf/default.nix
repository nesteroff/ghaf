# Copyright 2022-2023 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0
{
  stdenv,
  pkgs,
  lib,
  ...
}: stdenv.mkDerivation {
    name = "demo-pdf";

    src = ./Whitepaper.pdf;
    phases = [ "unpackPhase" ];

    unpackPhase = ''
      mkdir -p $out
      cp $src $out/
    '';

    meta = with lib; {
      description = "Demo PDF";
      platforms = [
        "x86_64-linux"
      ];
    };
  }
