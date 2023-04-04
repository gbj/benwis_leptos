{
  description = "Build a cargo project while also compiling the standard library";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";
    
    cargo-leptos = {
      #url= "github:leptos-rs/cargo-leptos";
      url = "github:benwis/cargo-leptos";
      flake = false;
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay, ... } @inputs:
    let
      # Import from derivation has some issues in Nix 2.11 which were fixed with 2.12
      isValidNixVersion = (builtins.compareVersions builtins.nixVersion "2.12") >= 0;
      optionalList = cond: list: if cond then list else [ ];
    in
    flake-utils.lib.eachSystem (optionalList isValidNixVersion [ "x86_64-linux" ]) (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.selectLatestNightlyWith (toolchain: toolchain.default.override {
          extensions = [ "rust-src" "rust-analyzer" ];
          targets = [ "x86_64-unknown-linux-gnu" "wasm32-unknown-unknown" ];
        });

        # NB: we don't need to overlay our custom toolchain for the *entire*
        # pkgs (which would require rebuidling anything else which uses rust).
        # Instead, we just want to update the scope that crane will use by appending
        # our specific toolchain there.
        inherit (pkgs) lib;
        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        protoFilter = path: _type: builtins.match ".*proto$" path != null;
        sqlxFilter = path: _type: builtins.match ".*json$" path != null;
        sqlFilter = path: _type: builtins.match ".*sql$" path != null;
        cssFilter = path: _type: builtins.match ".*css$" path != null;
        ttfFilter = path: _type: builtins.match ".*ttf$" path != null;
        woff2Filter = path: _type: builtins.match ".*woff2$" path != null;
        webpFilter = path: _type: builtins.match ".*webp$" path != null;
        jpegFilter = path: _type: builtins.match ".*jpeg$" path != null;
        pngFilter = path: _type: builtins.match ".*png$" path != null;
        icoFilter = path: _type: builtins.match ".*ico$" path != null;
        protoOrCargo = path: type:
          (protoFilter path type) || (craneLib.filterCargoSources path type) || (sqlxFilter path type) || (sqlFilter path type) || (cssFilter path type) || (woff2Filter path type) || (ttfFilter path type) || (webpFilter path type) || (icoFilter path type) || (jpegFilter path type) || (pngFilter path type);
        # other attributes omitted

        # Include more types of files in our bundle
        src = lib.cleanSourceWith {
          src = ./.; # The original, unfiltered source
          filter = protoOrCargo;
        };

        benwis_leptos = craneLib.buildPackage {
          inherit src;
          pname = "benwis_leptos";

          cargoVendorDir = craneLib.vendorMultipleCargoDeps {
            inherit (craneLib.findCargoFiles src) cargoConfigs;
            cargoLockList = [
              ./Cargo.lock

              # Unfortunately this approach requires IFD (import-from-derivation)
              # otherwise Nix will refuse to read the Cargo.lock from our toolchain
              # (unless we build with `--impure`).
              #
              # Another way around this is to manually copy the rustlib `Cargo.lock`
              # to the repo and import it with `./path/to/rustlib/Cargo.lock` which
              # will avoid IFD entirely but will require manually keeping the file
              # up to date!
              "${rustToolchain.passthru.availableComponents.rust-src}/lib/rustlib/src/rust/Cargo.lock"
            ];
          };

          #cargoExtraArgs = "-Z build-std --target x86_64-unknown-linux-gnu";

          buildPhaseCargoCommand = "cargo leptos --manifest-path=./Cargo.toml build  --release -vv";
          installPhaseCommand = ''
          mkdir -p $out/bin
          cp target/server/release/benwis_leptos $out/bin/
          cp -r target/site $out/bin/
          '';

          # ALL CAPITAL derivations will get forwarded to mkDerivation and will set the env var during build
          SQLX_OFFLINE = "true";
          #LEPTOS_BIN_TARGET_TRIPLE = "x86_64-unknown-linux-gnu"; # Adding this allows -Zbuild-std to work and shave 100kb off the WASM
          APP_ENVIRONMENT = "production";

          buildInputs = [
            # Add additional build inputs here
              cargo-leptos
              pkgs.pkg-config
              pkgs.openssl
              pkgs.protobuf
              pkgs.binaryen
              pkgs.cargo-generate
          ];
        };

          cargo-leptos = pkgs.rustPlatform.buildRustPackage rec {
            pname = "cargo-leptos";
            #version = "0.1.7";
            version = "0.1.8.1";
            buildFeatures = ["no_downloads"]; # cargo-leptos will try to download Ruby and other things without this feature

            src = inputs.cargo-leptos; 

            # cargoSha256 = "";
            #cargoLock = {
            #  lockFile = ./Cargo.lock;
            #  outputHashes = {
            #    "leptos-0.2.5" = "sha256-Q+EfyHvOJFnsbmptWwRGzconTwGFM22/XqLPPr5tK/I=";
            #  };
            #};
            cargoHash="sha256-e6aXerO5uuUpJo2m9d5as/jh1S7sKvq3qss72Lr6iHs=";

            nativeBuildInputs = [pkgs.pkg-config pkgs.openssl];

            buildInputs = with pkgs;
              [openssl pkg-config]
              ++ lib.optionals stdenv.isDarwin [
              Security
            ];

            doCheck = false; # integration tests depend on changing cargo config

            meta = with lib; {
            description = "A build tool for the Leptos web framework";
            homepage = "https://github.com/leptos-rs/cargo-leptos";
            changelog = "https://github.com/leptos-rs/cargo-leptos/blob/v${version}/CHANGELOG.md";
            license = with licenses; [mit];
            maintainers = with maintainers; [benwis];
          };
        };

          flyConfig = ./fly.toml;

          # Deploy the image to Fly with our own bash script
          flyDeploy = pkgs.writeShellScriptBin "flyDeploy" ''
            OUT_PATH=$(nix build --print-out-paths .#container)
            HASH=$(echo $OUT_PATH | grep -Po "(?<=store\/)(.*?)(?=-)")
            ${pkgs.skopeo}/bin/skopeo --insecure-policy --debug copy docker-archive:"$OUT_PATH" docker://registry.fly.io/$FLY_PROJECT_NAME:$HASH --dest-creds x:"$FLY_AUTH_TOKEN" --format v2s2
            ${pkgs.flyctl}/bin/flyctl deploy -i registry.fly.io/$FLY_PROJECT_NAME:$HASH -c ${flyConfig} --remote-only
          '';
        
      in
      {
        checks = {
          inherit benwis_leptos;
        };

        packages.default = benwis_leptos;

        # Create an option to build a docker image from this package 
        packages.container = pkgs.dockerTools.buildImage {
          name = "benwis_leptos";
          #tag = "latest";
          created = "now";
          copyToRoot = pkgs.buildEnv {
            name = "image-root";
            paths = [ pkgs.cacert ./.  ];
            pathsToLink = [ "/bin" "/db" "/migrations" ];
          };
          config = {
            Env = [ "PATH=${benwis_leptos}/bin" "APP_ENVIRONMENT=production" "LEPTOS_OUTPUT_NAME=benwis_leptos" "LEPTOS_SITE_ADDR=0.0.0.0:3000" "LEPTOS_SITE_ROOT=${benwis_leptos}/bin/site" ];

            ExposedPorts = {
              "3000/tcp" = { };
            };

            Cmd = [ "${benwis_leptos}/bin/benwis_leptos" ];
          };

        };

        apps.flyDeploy = flake-utils.lib.mkApp {
          drv = flyDeploy;
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = builtins.attrValues self.checks.${system};

          # Extra inputs can be added here
          nativeBuildInputs = with pkgs; [
            rustToolchain
              openssl
              mysql80
              dive
              sqlx-cli
              wasm-pack
              pkg-config
              binaryen
              nodejs
              nodePackages.tailwindcss
              cargo-leptos
              protobuf
              skopeo
              flyctl
          ];
           RUST_SRC_PATH = "${rustToolchain}/lib/rustlib/src/rust/library";
        };
      });
}
