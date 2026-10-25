{
  description = "NixOS on Raspberry Pi 4 (Model B) — headless, built and deployed from macOS";

  inputs = {
    # Recent nixpkgs. Commit `flake.lock` for reproducibility.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware = {
      url = "github:NixOS/nixos-hardware";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # `deploy` — push updates over SSH without re-flashing.
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # This repo is public: no real SSH key is committed. `keys/placeholder.pub`
    # is a tracked sentinel that fails the build; override it with your own
    # public key (a symlink-free path, e.g. a gitignored `keys/my.pub`):
    #   --override-input ssh-pubkey path:keys/my.pub
    ssh-pubkey = {
      url = "path:./keys/placeholder.pub";
      flake = false;
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixos-hardware,
      deploy-rs,
      ssh-pubkey,
      ...
    }:
    let
      # Single source of truth for the admin username (system + deploy target).
      user = "nixos";
      # The Pi's system; the Mac driving this is aarch64-darwin.
      targetSystem = "aarch64-linux";
      # `trim` (not removeSuffix "\n") also copes with CRLF key files.
      sshPublicKey = nixpkgs.lib.trim (builtins.readFile ssh-pubkey);

      systems = [
        "aarch64-darwin"
        targetSystem
      ];
      pkgsFor = system: nixpkgs.legacyPackages.${system};

      # Static guardrails ("tests" for a config repo). Each runs in the sandbox
      # and fails the build on a finding.
      lintChecks = pkgs: {
        formatting =
          pkgs.runCommand "nixfmt-check"
            {
              nativeBuildInputs = [
                pkgs.nixfmt
                pkgs.findutils
              ];
            }
            ''
              nixfmt --check $(find ${./.} -name '*.nix')
              touch $out
            '';
        statix = pkgs.runCommand "statix-check" { nativeBuildInputs = [ pkgs.statix ]; } ''
          statix check ${./.}
          touch $out
        '';
        deadnix = pkgs.runCommand "deadnix-check" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
          deadnix --fail ${./.}
          touch $out
        '';
        # `shellcheck` lets actionlint lint the `run:` blocks too.
        actionlint =
          pkgs.runCommand "actionlint-check"
            {
              nativeBuildInputs = [
                pkgs.actionlint
                pkgs.shellcheck
              ];
            }
            ''
              actionlint ${./.}/.github/workflows/*.yml
              touch $out
            '';
      };
    in
    {
      nixosConfigurations.pi4 = nixpkgs.lib.nixosSystem {
        system = targetSystem;
        specialArgs = { inherit user sshPublicKey; };
        modules = [
          # SD-card image builder (MBR: FAT firmware partition + ext4 root).
          # Provides `config.system.build.sdImage` and the disk layout.
          "${nixpkgs}/nixos/modules/installer/sd-card/sd-image-aarch64.nix"

          # Raspberry Pi 4 board profile: pinned downstream kernel, Wi-Fi/Bluetooth
          # firmware, device-tree filter, GRUB-off + extlinux-on, vc4-kms-v3d.
          nixos-hardware.nixosModules.raspberry-pi-4

          ./hardware-configuration.nix
          ./configuration.nix
        ];
      };

      # `nixfmt-tree` walks the tree; plain `nixfmt` would read stdin on `nix fmt`.
      formatter = nixpkgs.lib.genAttrs systems (system: (pkgsFor system).nixfmt-tree);

      devShells = nixpkgs.lib.genAttrs systems (system: {
        default = (pkgsFor system).mkShell {
          packages = with pkgsFor system; [
            nixfmt
            nixfmt-tree
            statix
            deadnix
            actionlint
            shellcheck
          ];
        };
      });

      # Pinned deploy-rs CLI: `nix run .#deploy -- .#pi4 ...`
      apps = nixpkgs.lib.genAttrs systems (system: {
        deploy = {
          type = "app";
          program = "${deploy-rs.packages.${system}.deploy-rs}/bin/deploy";
        };
      });

      checks = {
        aarch64-darwin = lintChecks (pkgsFor "aarch64-darwin");
        # Deploy checks are target-system derivations; expose them only for the
        # target so `nix flake check` on macOS skips instead of failing.
        ${targetSystem} =
          (lintChecks (pkgsFor targetSystem)) // (deploy-rs.lib.${targetSystem}.deployChecks self.deploy);
      };

      # deploy-rs target. `remoteBuild` makes the Pi compile its own closure
      # (native aarch64-linux), since the Mac cannot run Linux binaries.
      deploy.nodes.pi4 = {
        hostname = "pi4.local";
        sshUser = user;
        profiles.system = {
          user = "root";
          remoteBuild = true;
          # Use the TARGET system so the activation wrapper is built on the Pi;
          # a darwin wrapper cannot be built on an aarch64-linux host.
          path = deploy-rs.lib.${targetSystem}.activate.nixos self.nixosConfigurations.pi4;
        };
      };
    };
}
