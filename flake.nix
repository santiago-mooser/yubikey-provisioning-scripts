{
  description = "Provision a YubiKey OpenPGP applet (certify-only master + sign/encrypt/auth subkeys, moved to the card) using gpg batch interfaces and a status-fd responder. Based on drduh/YubiKey-Guide.";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Everything the scripts shell out to at runtime.
      runtimeDeps = pkgs: with pkgs; [
        gnupg # gpg, gpgconf
        yubikey-manager # ykman
        coreutils # od, tr, shred, mktemp, stty, uname, date, stat
        curl # keyserver upload (--upload)
        gnugrep
        gawk
        findutils
      ];

      mkPackage = pkgs:
        let
          # On Linux, ykman needs pcscd (PC/SC) and gpg's scdaemon then has to
          # use PC/SC too — otherwise its internal CCID driver and pcscd fight
          # over the reader. drduh's guide documents the same disable-ccid fix.
          # We ship a scdaemon.conf pointing at this closure's libpcsclite and
          # default YKPROV_SCDAEMON_CONF to it (overridable). Not applicable on
          # macOS, which uses the system PC/SC stack.
          scdaemonConf = pkgs.writeText "scdaemon.conf" ''
            disable-ccid
            pcsc-driver ${pkgs.pcsclite.lib}/lib/libpcsclite.so.1
          '';
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "yubikey-provisioning-scripts";
          version = "2.0.0";
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];
          dontConfigure = true;
          dontBuild = true;
          installPhase = ''
            runHook preInstall
            mkdir -p $out/libexec/yubikey-provisioning
            cp -r yubikey_provision.sh lib $out/libexec/yubikey-provisioning/
            chmod +x $out/libexec/yubikey-provisioning/yubikey_provision.sh
            makeWrapper $out/libexec/yubikey-provisioning/yubikey_provision.sh \
              $out/bin/yubikey-provision \
              --prefix PATH : ${pkgs.lib.makeBinPath (runtimeDeps pkgs)} \
              ${pkgs.lib.optionalString pkgs.stdenv.isLinux
                "--set-default YKPROV_SCDAEMON_CONF ${scdaemonConf}"}
            runHook postInstall
          '';
          meta = with pkgs.lib; {
            description = "Provision a YubiKey's OpenPGP applet with a fresh master key and subkeys";
            homepage = "https://github.com/santiago-mooser/yubikey-provisioning-scripts";
            license = licenses.gpl3Only;
            platforms = platforms.unix;
            mainProgram = "yubikey-provision";
          };
        };

      mkDevShell = pkgs: pkgs.mkShellNoCC {
        packages = (runtimeDeps pkgs) ++ (with pkgs; [
          shellcheck
          pcsclite # libpcsclite for gpg scdaemon / ykman
          bashInteractive
        ]);
        shellHook = ''
          echo "yubikey-provisioning dev shell."
          echo "  tests/run.sh                 # non-hardware suite (shellcheck + unit + integration)"
          echo "  tests/verify_hardware.sh     # destructive end-to-end (needs a connected YubiKey + pcscd)"
          echo "Linux: a running pcscd is required for ykman and gpg card access."
        '';
      };

      mkChecks = pkgs: {
        shellcheck = pkgs.runCommandNoCC "shellcheck"
          { nativeBuildInputs = [ pkgs.shellcheck ]; } ''
          cd ${self}
          shellcheck -x -S style yubikey_provision.sh lib/*.sh tests/*.sh tests/stubs/gpg
          touch $out
        '';

        # Non-hardware test suite (CLI/validation, real-gpg key integration,
        # fake-gpg responder). No smartcard involved.
        tests = pkgs.runCommandNoCC "tests"
          {
            nativeBuildInputs = with pkgs; [
              bashInteractive
              gnupg
              shellcheck
              coreutils
              gawk
              gnugrep
              findutils
            ];
          } ''
          cp -r ${self} src
          chmod -R u+w src
          cd src
          # The sandbox has no /usr/bin/env; rewrite the provisioner, tests and
          # fake-gpg stub shebangs to the sandbox bash. The source (and the
          # installed package) keep portable /usr/bin/env shebangs.
          patchShebangs .
          export HOME="$TMPDIR"
          bash tests/run.sh
          touch $out
        '';
      };
    in
    {
      packages = forAllSystems (pkgs: rec {
        yubikey-provisioning-scripts = mkPackage pkgs;
        default = yubikey-provisioning-scripts;
      });

      apps = forAllSystems (pkgs: rec {
        yubikey-provision = {
          type = "app";
          program = pkgs.lib.getExe (mkPackage pkgs);
        };
        default = yubikey-provision;
      });

      devShells = forAllSystems (pkgs: { default = mkDevShell pkgs; });

      checks = forAllSystems (pkgs: mkChecks pkgs);

      formatter = forAllSystems (pkgs: pkgs.nixpkgs-fmt);
    };
}
