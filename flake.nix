{
  description = "Elixir development shell";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.beamMinimal28Packages.elixir_1_19
              pkgs.beamMinimal28Packages.erlang
              pkgs.elixir-ls
              pkgs.jq
            ]
            ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
              pkgs.inotify-tools
            ];

            ELIXIR_ERL_OPTIONS = "-kernel shell_history enabled";
          };
        });
    };
}
