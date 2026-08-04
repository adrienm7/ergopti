# NixOS / Home Manager

`install.sh` does not apply to a NixOS machine, and running it anyway produces
one that half-works until the next rebuild reverts it: the store is read-only,
groups and udev rules are declared rather than mutated, and `~/.local/bin` is
not where a NixOS user's binaries come from.

The flake here splits the install along the line NixOS already draws.

## System — what needs root

```nix
{
  inputs.ergopti.url = "github:adrienm7/ergopti?dir=tools/build/nix";

  outputs = { nixpkgs, ergopti, ... }: {
    nixosConfigurations.mymachine = nixpkgs.lib.nixosSystem {
      modules = [
        ergopti.nixosModules.ergopti
        {
          services.ergopti.enable = true;
          services.ergopti.users = [ "alice" ];
        }
      ];
    };
  };
}
```

This declares the `uinput` group, the udev rule with `static_node` (without
which the rule matches nothing on a fresh boot, because `/dev/uinput` does not
exist until the module is loaded), the kernel module, and the two group
memberships.

**What the `input` group means.** It grants the ability to read every keystroke
on the seat, including passwords typed into any application. A hotstring engine
cannot work without it, and kanata, keyd and xremap all require the same thing.
`uaccess` is deliberately not used: systemd's udev guidance forbids it for input
devices for exactly this reason.

## User — the daemon

```nix
{
  imports = [ ergopti.homeManagerModules.ergopti ];
  services.ergopti.enable = true;
}
```

This installs the package and a `systemd --user` unit bound to
`graphical-session.target`. The two halves are independent: a user without root
can take this one on a machine whose administrator has applied the first.

## The tray

`services.ergopti.tray` defaults to true and needs a StatusNotifierItem host.
KDE, XFCE, LXQt, COSMIC and most wlroots panels have one; **GNOME does not**, and
needs the AppIndicator extension — which this module cannot install for you, and
which is a property of GNOME rather than something the driver can work around.
