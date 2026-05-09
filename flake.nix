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
      apps = forSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.devbox-cli}/bin/devbox-cli";
        };
      });
    };
}
