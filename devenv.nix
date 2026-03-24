{
  pkgs,
  lib,
  config,
  inputs,
  ...
}:
let
  computePort = path: basePort:
    basePort
    + lib.mod (lib.trivial.fromHexString (
      builtins.substring 0 4 (builtins.hashString "sha256" path)
    )) 100;

  port = computePort (toString ./.) 4000;
  cwd = toString ./.;

  devBucket = "dev";
  testBucket = "test";
in
{
  # ── Overlays ────────────────────────────────────────────────────────────
  # Erlang 28.2 + Elixir 1.19.4 to match .tool-versions

  overlays = [
    (final: prev: {
      rustfs = inputs.rustfs-flake.packages.${prev.stdenv.system}.default;
    })
  ];

  # overlays = [
  #   (final: prev: {
  #     erlang_28_2 = prev.callPackage (import
  #       "${prev.path}/pkgs/development/interpreters/erlang/generic-builder.nix"
  #       {
  #         version = "28.2";
  #         hash = "sha256-59IUTZrjDqmz3qVQOS3Ni35fD6TzosPnRSMsuR6vF4k=";
  #         systemdSupport = lib.meta.availableOn prev.stdenv.hostPlatform prev.systemd;
  #         wxSupport = true;
  #       }
  #     ) { };
  #
  #     elixir_1_19_4 = prev.callPackage (import
  #       "${prev.path}/pkgs/development/interpreters/elixir/generic-builder.nix"
  #       {
  #         version = "1.19.4";
  #         hash = "sha256-lJC/xXkVIsX6AgL3ynU6C9AncBDwHPsUGxyYlTRdaMY=";
  #         maximumOTPVersion = "28";
  #         minimumOTPVersion = "27";
  #       }
  #     ) { erlang = final.erlang_28_2; };
  #
  #     erlang = final.erlang_28_2;
  #     elixir = final.elixir_1_19_4;
  #     elixir-ls = prev.callPackage "${prev.path}/pkgs/development/beam-modules/elixir-ls" {
  #       elixir = final.elixir;
  #     };
  #   })
  # ];

  # ── Languages ───────────────────────────────────────────────────────────

  languages.elixir = {
    enable = true;
    package = pkgs.beamMinimal28Packages.elixir_1_19;
  };
  languages.erlang = {
    enable = true;
    package = pkgs.beamMinimal28Packages.erlang;
  };

  # ── Environment ─────────────────────────────────────────────────────────

  env.ELIXIR_ERL_OPTIONS = "-kernel shell_history enabled";
  env.PORT = toString port;
  env.MIX_OS_DEPS_COMPILE_PARTITION_COUNT = toString (builtins.div (lib.toInt (builtins.readFile (pkgs.runCommand "nproc" {} "${pkgs.toybox}/bin/nproc > $out"))) 2);

  # DATABASE_URL is not required for dev or test (configs use
  # individual params + PGHOST). Uncomment if needed for other tools:
  # env.DATABASE_URL = "postgresql:///dev?user=postgres";

  # https://devenv.sh/packages/
  packages =
    [ pkgs.jq ]
    ++ lib.optionals pkgs.stdenv.isLinux [
      pkgs.inotify-tools
      pkgs.chromedriver
      pkgs.chromium
    ]
    ++ lib.optionals pkgs.stdenv.isDarwin [
      pkgs.libiconv
    ];

  # ── Services ────────────────────────────────────────────────────────────

  services = {
    rustfs = {
      enable = !config.devenv.isTesting;
      package = pkgs.rustfs;
      accessKey = "rustfs";
      secretKey = "rustfs";
    };

    postgres = {
      enable = true;
      package = pkgs.postgresql_16_jit;
      initialScript = ''
        CREATE ROLE postgres WITH LOGIN SUPERUSER CREATEDB CREATEROLE PASSWORD 'postgres';
      '';
    };
  };

  enterTest = ''
     MIX_ENV=test mix ash_postgres.drop --force-drop --quiet
     mix test
  '';


  # ── Tasks ───────────────────────────────────────────────────────────────

  tasks = {

    "deps:get" = {
      after = [ "devenv:enterShell"];
      cwd = cwd;
      exec = "mix deps.get";
      execIfModified = [
        "mix.exs"
        "mix.lock"
        "deps"
      ];
    };

    "deps:compile:dev" = {
      cwd = cwd;
      # exec = "mix deps.compile";
      exec = "mix loadpaths"; # more effecient way of checking/compiling deps
      env.MIX_ENV = "dev";
      execIfModified = [ "deps"];
      after = lib.mkIf (!config.devenv.isTesting) [ "deps:get" ];
    };

    "compile:dev" = {
      after = ["deps:compile:dev"];
      cwd = cwd;
      exec = "mix compile";
      env.MIX_ENV = "dev";
      execIfModified = [ "lib" "_build/dev"];
    };

    "deps:compile:test" = {
      cwd = cwd;
      exec = "mix loadpaths"; # more effecient way of checking/compiling deps
      env.MIX_ENV = "test";
      execIfModified = [ "deps"];
      before = [ "devenv:enterTest" ];
    };

    "compile:test" = {
      after = ["deps:compile:test"];
      before = [ "api:test"];
      cwd = cwd;
      exec = "mix compile";
      env.MIX_ENV = "test";
      execIfModified = [ "lib" "_build/test"];
    };

    "db:preflight" = {
      cwd = cwd;
      env.MIX_ENV = "test";
      exec = "mix ecto.drop --force-drop --quiet";
      before = [ "api:test" ];
    };

    "api:test" = {
      cwd = cwd;
      exec = "mix test";
    };

    "api:test:integration" = {
      cwd = cwd;
      exec = "mix test --only integration";
    };

    "db:drop".exec = "mix ash_postgres.drop";

    "db:migrate" = {
      after = [ "api:codegen" ];
      cwd = cwd;
      execIfModified = [ "priv/repo/migrations/*" ];
      exec = "mix ecto.migrate";
    };

    "api:codegen" = {
      cwd = cwd;
      execIfModified = [ "lib/ht/api/*/resources/*.ex" ];
      exec = "mix ash_postgres.generate_migrations --check || mix ash.codegen --dev";
    };
  } // lib.optionalAttrs (!config.devenv.isTesting) {

    "db:setup" = {
      cwd = cwd;
      env.MIX_ENV = "dev";
      exec = "mix ecto.setup --quiet || (mix ecto.drop --force-drop --quiet 2>/dev/null; mix ecto.setup)";
      after = [ "devenv:processes:postgres" ];
    };
    "db:seed" = {
        cwd = cwd;
        env.MIX_ENV = "dev";
        exec = "mix seed.demo";
      };

    "devenv:processes:rustfs".before = ["devenv:processes:api"];
    "devenv:processes:postgres".before = ["devenv:processes:api"];

    "rustfs:buckets" = {
      after = [ "devenv:rustfs:setup" ];
      before = [ "devenv:processes:rustfs" ];
      exec = ''
        mkdir -p "$RUSTFS_DATA_DIR/${devBucket}"
        mkdir -p "$RUSTFS_DATA_DIR/${testBucket}"
      '';
    };

    "rustfs:clean" = {
      exec = ''
        for bucket in "$RUSTFS_DATA_DIR/${devBucket}" "$RUSTFS_DATA_DIR/${testBucket}"; do
          if [ -d "$bucket" ]; then
            rm -rf "$bucket"/*
            echo "Cleaned $bucket"
          fi
        done
      '';
    };
  };

  # ── Processes ───────────────────────────────────────────────────────────

  processes = lib.optionalAttrs (!config.devenv.isTesting) {

    api = {
      cwd = cwd;
      exec = "mix phx.server";
      after = ["db:setup"];
    };
  };
}
