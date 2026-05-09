{
  nixpkgs,
  system,
  hypervisor ? "tart",
  vm ? { },
  modules ? [ ],
  specialArgs ? { },
}:
nixpkgs.lib.nixosSystem {
  inherit system specialArgs;
  modules = [
    ../modules
    {
      devbox.hypervisor = hypervisor;
      devbox.vm = vm;
    }
  ] ++ modules;
}
