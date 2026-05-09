{
  description = "Build NixOS devbox VMs from a single workload module.";

  inputs = {
    nix-pins.url = "github:firefly-engineering/nix-pins";
    nixpkgs.follows = "nix-pins/nixpkgs-stable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.default = ./modules;
      lib = import ./lib;
      packages = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          devbox-cli = pkgs.callPackage ./pkgs/devbox-cli.nix { };
        in
        {
          inherit devbox-cli;
          default = devbox-cli;
        }
      );
      apps = forSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          cli = self.packages.${system}.devbox-cli;
          mkSubApp = sub: {
            type = "app";
            program = toString (
              pkgs.writeShellScript "devbox-cli-${sub}" ''
                exec ${cli}/bin/devbox-cli ${sub} "$@"
              ''
            );
          };
        in
        {
          default = {
            type = "app";
            program = "${cli}/bin/devbox-cli";
          };
          init = mkSubApp "init";
          update = mkSubApp "update";
          up = mkSubApp "up";
          down = mkSubApp "down";
          rm = mkSubApp "rm";
        }
      );
    };
}
