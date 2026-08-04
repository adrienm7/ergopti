{
  # tools/build/nix/flake.nix
  #
  # NixOS and Home Manager modules for the Ergopti+ Linux daemon.
  #
  # WHY A FLAKE AND NOT install.sh:
  # install.sh writes to /etc/udev/rules.d, /etc/modules-load.d and
  # ~/.local/bin, adds the user to two groups, and assumes /usr/bin/env bash
  # resolves. None of that is how a NixOS machine is configured — the store is
  # read-only, groups and udev rules are declared rather than mutated, and a
  # `curl | sh` installer aimed at /usr is simply inapplicable. Telling a NixOS
  # user to run it anyway produces a machine that half-works until the next
  # rebuild reverts it.
  #
  # WHAT THE TWO MODULES SPLIT:
  #   nixosModules.ergopti      — the parts that need root and are system state:
  #                               the uinput group, the udev rule, the kernel
  #                               module. Mirrors what services.kanata declares.
  #   homeManagerModules.ergopti — the parts that are the user's: the daemon
  #                               itself, its systemd --user unit, its config.
  # Splitting them is not tidiness. A user without root can still take the
  # second half on a machine whose administrator has applied the first.

  description = "Ergopti+ — hotstring engine, keystroke metrics and keyboard remapping";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs, ... }:
    let
      forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];
    in
    {
      # ── The daemon itself ─────────────────────────────────────────────────
      packages = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = self.packages.${system}.ergopti;

          ergopti = pkgs.stdenv.mkDerivation {
            pname = "ergopti-plus";
            version = "dev";
            src = ../../..;

            nativeBuildInputs = [ pkgs.makeWrapper ];
            buildInputs = [ pkgs.luajit ];

            installPhase = ''
              runHook preInstall

              mkdir -p $out/lib/ergopti
              cp -r static/ergopti_plus/linux/. $out/lib/ergopti/
              mkdir -p $out/lib/ergopti/_shared
              cp -r static/ergopti_plus/_shared/. $out/lib/ergopti/_shared/

              # The shared tree is a SIBLING of the driver at runtime and the
              # daemon resolves it that way, so the layout above is part of the
              # contract rather than a convenience.
              mkdir -p $out/bin
              makeWrapper ${pkgs.luajit}/bin/luajit $out/bin/ergopti-hotstrings \
                --add-flags "$out/lib/ergopti/ergopti_hotstrings.lua" \
                --set LUA_PATH "$out/lib/ergopti/?.lua;$out/lib/ergopti/?/init.lua;$out/lib/ergopti/_shared/lua/?.lua;$out/lib/ergopti/_shared/lua/?/init.lua;;" \
                --prefix PATH : ${nixpkgs.lib.makeBinPath (with pkgs; [
                  xclip wl-clipboard xdotool libxkbcommon libnotify
                ])} \
                --prefix LD_LIBRARY_PATH : ${nixpkgs.lib.makeLibraryPath (with pkgs; [
                  libayatana-appindicator gtk3 glib libxkbcommon
                ])}

              runHook postInstall
            '';

            meta = with nixpkgs.lib; {
              description = "Ergonomic keyboard optimizer with a hotstring engine";
              platforms = platforms.linux;
              license = licenses.mit;
            };
          };
        });

      # ── System state: what needs root ─────────────────────────────────────
      nixosModules.ergopti = { config, lib, pkgs, ... }:
        let cfg = config.services.ergopti;
        in {
          options.services.ergopti = {
            enable = lib.mkEnableOption "Ergopti+ input device permissions";

            users = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ ];
              description = ''
                Users granted access to the input devices.

                Being in the `input` group means being able to read EVERY
                keystroke on the seat, including passwords typed into any
                application. That is what a hotstring engine requires, and it is
                what kanata, keyd and xremap require too — but it is stated here
                rather than granted quietly.

                `uaccess` is deliberately NOT used: systemd's own udev guidance
                forbids it for input devices, because it would make unprivileged
                keylogging trivial on any seat.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            users.groups.uinput = { };

            users.users = lib.genAttrs cfg.users (_: {
              extraGroups = [ "input" "uinput" ];
            });

            # The module must be loaded for /dev/uinput to exist at all; the
            # rule below matches nothing until it is.
            boot.kernelModules = [ "uinput" ];

            services.udev.extraRules = ''
              KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"
            '';
          };
        };

      # ── User state: the daemon and its unit ───────────────────────────────
      homeManagerModules.ergopti = { config, lib, pkgs, ... }:
        let cfg = config.services.ergopti;
        in {
          options.services.ergopti = {
            enable = lib.mkEnableOption "Ergopti+ hotstring daemon";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.ergopti;
              description = "The daemon package to run.";
            };

            tray = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Show the tray icon. Needs a StatusNotifierItem host: KDE, XFCE,
                LXQt, COSMIC and most wlroots panels have one natively; GNOME
                needs the AppIndicator extension, which is not something this
                module can install for you.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            systemd.user.services.ergopti-hotstrings = {
              Unit = {
                Description = "Ergopti — expansion de texte et métriques clavier";
                # PartOf as well as After: without it the daemon outlives the
                # session it probed at startup, and logging back in under the
                # other display server finds it holding a stale answer.
                After = [ "graphical-session.target" ];
                PartOf = [ "graphical-session.target" ];
              };

              Service = {
                Type = "simple";
                ExecStart = "${cfg.package}/bin/ergopti-hotstrings"
                  + lib.optionalString cfg.tray " --tray";
                Restart = "on-failure";
                RestartSec = 3;
                # No Environment=DISPLAY. The daemon probes the session at
                # runtime; a pinned value is wrong on a second seat and under
                # Wayland, and breaks the switch this unit exists to survive.
              };

              Install.WantedBy = [ "graphical-session.target" ];
            };
          };
        };
    };
}
