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
      lib = { };
      packages = forSystems (_: { });
      apps = forSystems (_: { });
    };
}
