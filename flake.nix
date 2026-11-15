{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    flake-parts.follows = "baskingspot/flake-parts";
    baskingspot = {
      url = "github:baskingspot/nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      # imports and inputsFrom below mirror each other, including the
      # toolchain version. The library and the `tools/` package both build
      # with Zig 0.17: libvaxis, which `acviz` links, requires it.
      imports = with inputs.baskingspot.flakeModules; [
        base
        docs
        zig."0.17"
      ];

      perSystem =
        { pkgs, config, ... }:
        {
          devShells.default = pkgs.mkShell {
            inputsFrom = [
              config.devShells.base
              config.devShells.docs
              config.devShells."zig-0-17"
            ];
            packages = [ config.packages."ziglint-0-17" ];
          };
        };
    };
}
