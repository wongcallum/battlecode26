{
  description = "Battlecode 2026 client (Electron)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          lib = pkgs.lib;
          electron = pkgs.electron;

          # Toolchains the in-app runner needs, provided the Nix way instead of by
          # probing the host filesystem. The engine requires a JDK >= 21.
          jdk = pkgs.jdk21;
          python = pkgs.python312;
          # The gradle wrapper (#!/bin/sh) shells out to these during a build.
          runnerTools = [
            pkgs.coreutils
            pkgs.gnused
            pkgs.findutils
          ];

          # Filtered copies of the two source trees we need, excluding any local
          # build artefacts so the derivation stays pure and small.
          clientSrc = builtins.path {
            name = "battlecode-client-src";
            path = ./client;
            filter =
              path: type:
              let
                b = baseNameOf path;
              in
              b != "node_modules" && b != "dist" && b != "packaged-client" && b != "packaged";
          };
          schemaSrc = builtins.path {
            name = "battlecode-schema-src";
            path = ./schema;
            filter = path: type: (baseNameOf path) != "node_modules";
          };

          # `client/package-lock.json` references the schema via `file:../schema`, so
          # both trees must sit next to each other at build time.
          combinedSrc = pkgs.runCommand "battlecode-client-combined" { } ''
            mkdir -p $out
            cp -r ${clientSrc} $out/client
            cp -r ${schemaSrc} $out/schema
          '';

          frontend = pkgs.buildNpmPackage {
            pname = "battlecode-client-2026";
            version = "26.0.0";

            src = combinedSrc;
            sourceRoot = "battlecode-client-combined/client";

            npmDepsHash = "sha256-bfMbZ+ks0b5yrfnyZfgJAblBqTH1QPJoaNTN6PKFLHs=";

            # No native addons are required for the web bundle; skipping lifecycle
            # scripts avoids any attempt to compile/download them.
            npmFlags = [ "--ignore-scripts" ];

            # Runs `npm run build` (webpack -> dist/) automatically; we only override
            # the install step to lay out the files Electron needs at runtime.
            dontNpmInstall = true;

            installPhase = ''
              runHook preInstall

              # Only the Electron main process needs runtime deps (electron-fetch,
              # electron-is-dev); drop dev-only tooling (webpack, electron-builder, ...).
              npm prune --omit=dev --ignore-scripts

              appdir=$out/share/battlecode-client
              mkdir -p $appdir
              cp -r dist src-electron icons package.json node_modules $appdir/

              # `battlecode-schema` is linked via `file:../schema`; the relative symlink
              # would dangle once copied, so replace it with the real (lean) package.
              rm -f $appdir/node_modules/battlecode-schema
              cp -r ../schema $appdir/node_modules/battlecode-schema
              chmod -R u+w $appdir/node_modules/battlecode-schema
              rm -f $appdir/node_modules/battlecode-schema/flatc-mac \
                    $appdir/node_modules/battlecode-schema/flatc-windows.exe

              runHook postInstall
            '';
          };

          battlecode-client = pkgs.writeShellApplication {
            name = "battlecode-client";
            runtimeInputs = [ electron jdk python ] ++ runnerTools;
            text = ''
              # Force Electron's "production" path so it loads the built bundle from
              # dist/ instead of expecting a webpack dev server on :3000.
              export ELECTRON_IS_DEV=0

              # Default the runner's scaffold to the directory `nix run` was invoked
              # from (typically the battlecode project checkout), so maps and bots are
              # discovered automatically. Override by picking a folder in the UI.
              export BC_SCAFFOLD="''${BC_SCAFFOLD:-$PWD}"

              # Hand the Nix-provided toolchains to the runner (see electron-main.js).
              export BC_JAVA_HOME=${jdk.home}
              export BC_JAVA_LABEL=${lib.escapeShellArg "Java ${jdk.version} (Nix)"}
              export BC_PYTHON=${python.interpreter}
              export BC_PYTHON_LABEL=${lib.escapeShellArg "Python ${python.version} (Nix)"}

              # Use native Wayland whenever a compositor socket is present, otherwise
              # X11. We key off WAYLAND_DISPLAY rather than --ozone-platform-hint=auto
              # because that hint only consults XDG_SESSION_TYPE, which some setups
              # leave unset. WaylandWindowDecorations draws a title bar on compositors
              # without server-side decorations (e.g. GNOME).
              flags=()
              if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
                flags+=(--ozone-platform=wayland --enable-features=WaylandWindowDecorations)
              fi

              # GPU acceleration is disabled by default because it crashes on headless
              # / VM GPUs; set BC_ENABLE_GPU=1 to use the hardware GPU on a real desktop.
              if [ -z "''${BC_ENABLE_GPU:-}" ]; then
                flags+=(--disable-gpu)
              fi

              exec electron ${frontend}/share/battlecode-client "''${flags[@]}" "$@"
            '';
          };
        in
        {
          inherit frontend;
          battlecode-client = battlecode-client;
          default = battlecode-client;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/battlecode-client";
        };
        battlecode-client = self.apps.${system}.default;
      });
    };
}
