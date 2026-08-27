"""Desktop-session activation shared by both Ergopti XKB installers.

Activation is the step that tells the running desktop to *use* the layout the
installer just wrote to disk. It is the part of the installation that cannot
run with elevated privileges: GNOME stores the layout list in the user's dconf
database and reaches it over the user's D-Bus session bus, so a process running
as root writes into root's dconf and silently changes nothing (issue #84).

The module therefore owns three responsibilities:

- refuse, or drop back to, the desktop user before touching any session state;
- apply the layout on the desktops that expose a documented setting
  (GNOME-based sessions through gsettings, KDE Plasma through kwriteconfig,
  X11 through setxkbmap) and report each outcome;
- print an exact, copy-pasteable instruction for every other session, because
  wlroots compositors (Sway, Hyprland, niri, river, …) have no shared setting
  and can only be configured from their own configuration file.

Everything here is best-effort by contract: a desktop we cannot reach is
reported to the user, never silently swallowed and never fatal.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from layout_package import (  # noqa: E402
    format_gsettings_sources,
    merge_gsettings_source,
    merge_kde_layout_list,
    parse_gsettings_sources,
    parse_kde_layout_list,
)

GNOME_SCHEMA = "org.gnome.desktop.input-sources"
GNOME_KEY = "sources"

# Desktops whose keyboard layout list lives in the GNOME input-sources schema.
GNOME_DESKTOP_TOKENS = frozenset(
    {
        "gnome",
        "gnome-classic",
        "gnome-flashback",
        "budgie",
        "budgie-desktop",
        "unity",
        "ubuntu",
        "pantheon",
        "pop",
        "zorin",
    }
)
KDE_DESKTOP_TOKENS = frozenset({"kde", "plasma", "kde-plasma"})

# Compositors that own their keyboard configuration in their own file. The
# value is the configuration path and the exact snippet to add, with the layout
# identifier substituted at print time.
COMPOSITOR_INSTRUCTIONS: dict[str, tuple[str, str]] = {
    "hyprland": (
        "~/.config/hypr/hyprland.conf",
        "input {{\n    kb_layout = {layout}\n}}",
    ),
    "sway": (
        "~/.config/sway/config",
        'input * {{\n    xkb_layout "{layout}"\n}}',
    ),
    "niri": (
        "~/.config/niri/config.kdl",
        'input {{\n    keyboard {{\n        xkb {{\n            layout "{layout}"\n'
        "        }}\n    }}\n}}",
    ),
    "river": (
        "~/.config/river/init",
        "riverctl keyboard-layout {layout}",
    ),
    "wayfire": (
        "~/.config/wayfire.ini",
        "[input]\nxkb_layout = {layout}",
    ),
    "labwc": (
        "~/.config/labwc/environment",
        "XKB_DEFAULT_LAYOUT={layout}",
    ),
}

# Last-resort instruction for any Wayland session we do not recognise: every
# libxkbcommon-based compositor reads these variables at startup.
GENERIC_WAYLAND_FILE = "~/.config/environment.d/90-ergopti.conf"
GENERIC_WAYLAND_SNIPPET = "XKB_DEFAULT_LAYOUT={layout}"


# ---------------------------------------------------------------------------
# Session description
# ---------------------------------------------------------------------------


def desktop_tokens(environ: dict[str, str] | None = None) -> set[str]:
    """Return the lowercase desktop identifiers advertised by the session.

    ``XDG_CURRENT_DESKTOP`` is colon-separated and may hold several names
    (``ubuntu:GNOME``); the two fallbacks cover display managers that only set
    one of the three variables.
    """
    env = os.environ if environ is None else environ
    tokens: set[str] = set()
    for name in ("XDG_CURRENT_DESKTOP", "XDG_SESSION_DESKTOP", "DESKTOP_SESSION"):
        raw = env.get(name, "")
        for token in raw.replace(";", ":").split(":"):
            token = token.strip().lower()
            if token:
                tokens.add(token)
    return tokens


def session_type(environ: dict[str, str] | None = None) -> str:
    """Return ``wayland``, ``x11`` or ``unknown`` for the current session."""
    env = os.environ if environ is None else environ
    declared = env.get("XDG_SESSION_TYPE", "").strip().lower()
    if declared in ("wayland", "x11"):
        return declared
    if env.get("WAYLAND_DISPLAY"):
        return "wayland"
    if env.get("DISPLAY"):
        return "x11"
    return "unknown"


def is_gnome_session(tokens: set[str]) -> bool:
    return bool(tokens & GNOME_DESKTOP_TOKENS)


def is_kde_session(tokens: set[str]) -> bool:
    return bool(tokens & KDE_DESKTOP_TOKENS)


def compositor_hint(tokens: set[str]) -> tuple[str, str] | None:
    """Return the (configuration file, snippet) pair for a known compositor."""
    for token in sorted(tokens):
        if token in COMPOSITOR_INSTRUCTIONS:
            return COMPOSITOR_INSTRUCTIONS[token]
    return None


def describe_session(environ: dict[str, str] | None = None) -> str:
    """One-line human description used in every activation report."""
    env = os.environ if environ is None else environ
    desktop = env.get("XDG_CURRENT_DESKTOP") or "<inconnu>"
    return f"session {session_type(env)}, bureau {desktop}"


# ---------------------------------------------------------------------------
# Privilege handling
# ---------------------------------------------------------------------------


def running_as_root() -> bool:
    geteuid = getattr(os, "geteuid", None)
    return bool(callable(geteuid) and geteuid() == 0)


def desktop_user() -> str | None:
    """Return the unprivileged user owning the desktop session, if known."""
    for name in ("SUDO_USER", "DOAS_USER"):
        value = os.environ.get(name, "").strip()
        if value and value != "root":
            return value
    uid = os.environ.get("PKEXEC_UID", "").strip()
    if uid:
        try:
            import pwd

            name = pwd.getpwuid(int(uid)).pw_name
        except (ImportError, KeyError, ValueError):
            return None
        if name != "root":
            return name
    return None


def session_bus_env(user: str) -> dict[str, str]:
    """Rebuild the environment needed to reach a user's session bus.

    ``sudo`` strips ``DBUS_SESSION_BUS_ADDRESS`` on most distributions, and the
    per-user bus is never reachable through root's own environment. Both values
    are derived from the target uid, which is how systemd names the runtime
    directory on every systemd distribution.
    """
    try:
        import pwd

        uid = pwd.getpwnam(user).pw_uid
    except (ImportError, KeyError):
        return {}
    runtime_dir = f"/run/user/{uid}"
    if not Path(runtime_dir).is_dir():
        return {}
    return {
        "XDG_RUNTIME_DIR": runtime_dir,
        "DBUS_SESSION_BUS_ADDRESS": f"unix:path={runtime_dir}/bus",
    }


def shell_quote(value: str) -> str:
    """Quote one argument for a POSIX shell command line."""
    return "'" + value.replace("'", "'\\''") + "'"


def build_drop_command(tool: str, user: str, environment: dict[str, str], argv: list[str]) -> list[str]:
    """Build the command that re-runs ``argv`` as ``user`` with ``environment``."""
    env_prefix = ["env"] + [f"{key}={value}" for key, value in sorted(environment.items())]
    if tool == "runuser":
        return ["runuser", "-u", user, "--", *env_prefix, *argv]
    if tool == "sudo":
        return ["sudo", "-u", user, *env_prefix, *argv]
    quoted = " ".join(shell_quote(part) for part in (*env_prefix, *argv))
    return ["su", user, "-c", quoted]


def rerun_unprivileged(argv: list[str]) -> int | None:
    """Re-run ``argv`` as the desktop user; return its exit code, or ``None``.

    ``None`` means no privilege drop could be attempted and the caller must
    decide what to do. Returning the child's exit code keeps a failure visible
    instead of pretending the activation happened.
    """
    user = desktop_user()
    if not user:
        return None
    tool = next((name for name in ("runuser", "sudo", "su") if shutil.which(name)), None)
    if tool is None:
        return None
    environment = {
        name: os.environ[name]
        for name in ("DISPLAY", "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "WAYLAND_DISPLAY")
        if os.environ.get(name)
    }
    environment.update(session_bus_env(user))
    command = build_drop_command(tool, user, environment, argv)
    # Flush before spawning: the child writes to the same terminal, and an
    # unflushed parent buffer would print this line after the child's output.
    print(f"   ↩️  Activation relancée sans privilèges pour l'utilisateur {user}.", flush=True)
    try:
        return subprocess.run(command, check=False, timeout=120).returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"   ⚠️  Relance sans privilèges impossible ({error}).")
        return None


# ---------------------------------------------------------------------------
# Command helpers
# ---------------------------------------------------------------------------


def run_capture(
    command: list[str], timeout: int = 15, env: dict[str, str] | None = None
) -> str | None:
    """Run a read-only command; ``None`` when it is absent or fails."""
    try:
        result = subprocess.run(
            command,
            env=None if env is None else {**os.environ, **env},
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 else None


def run_reported(command: list[str], label: str, timeout: int = 30) -> bool:
    """Run a best-effort command and report its outcome; never raise."""
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"   ⚠️  {label} : impossible de lancer la commande ({error}).")
        return False
    if result.returncode == 0:
        print(f"   ✅ {label}.")
        return True
    print(f"   ⚠️  {label} : échec (code {result.returncode}).")
    for line in (result.stdout or "").strip().splitlines()[:10]:
        print(f"      {line}")
    return False


# ---------------------------------------------------------------------------
# Per-desktop activation
# ---------------------------------------------------------------------------


def apply_gnome(layout_ids: list[str], tokens: set[str]) -> bool:
    """Put the layout first in the GNOME input-source list.

    Returns True when the setting now holds the layout. The list is read back
    after the write: dconf reports success even when the value did not change,
    for instance when the process cannot reach the user's session bus, and a
    silent no-op is exactly the failure this whole module exists to prevent.
    """
    current_raw = run_capture(["gsettings", "get", GNOME_SCHEMA, GNOME_KEY])
    if current_raw is None:
        if is_gnome_session(tokens):
            print(
                "   ⚠️  GNOME détecté mais gsettings est injoignable : la "
                "disposition n'a pas pu être activée automatiquement."
            )
        else:
            print("   ℹ️  Schéma GNOME absent : étape GNOME ignorée.")
        return False
    current_sources = parse_gsettings_sources(current_raw)
    if current_sources is None:
        print(
            "   ⚠️  Valeur gsettings illisible : elle est laissée intacte "
            f"({current_raw.strip()})."
        )
        return False
    wanted = [("xkb", layout_id) for layout_id in layout_ids]
    merged, changed = merge_gsettings_source(current_sources, wanted, make_primary=True)
    if not changed:
        print("   ✅ GNOME : la disposition est déjà en première position.")
        return True
    if not run_reported(
        ["gsettings", "set", GNOME_SCHEMA, GNOME_KEY, format_gsettings_sources(merged)],
        "GNOME : disposition placée en tête de vos sources",
    ):
        return False
    verified = run_capture(["gsettings", "get", GNOME_SCHEMA, GNOME_KEY])
    readback = parse_gsettings_sources(verified or "")
    if readback == merged:
        print(f"   ✅ GNOME : valeur confirmée {format_gsettings_sources(readback)}.")
        return True
    print(
        "   ❌ GNOME : la valeur n'a pas été enregistrée (relue : "
        f"{(verified or '<vide>').strip()}). Lancez l'activation depuis votre "
        "session graphique, sans sudo."
    )
    return False


def apply_kde(layout_ids: list[str], tokens: set[str]) -> bool:
    """Add the layout to the KDE Plasma list and reconfigure KWin."""
    current_list = None
    for reader in ("kreadconfig6", "kreadconfig5"):
        current_list = run_capture(
            [reader, "--file", "kxkbrc", "--group", "Layout", "--key", "LayoutList"]
        )
        if current_list is not None:
            break
    if current_list is None:
        if is_kde_session(tokens):
            print("   ⚠️  KDE détecté mais kreadconfig est injoignable : étape ignorée.")
        else:
            print("   ℹ️  kreadconfig absent : étape KDE ignorée.")
        return False
    merged, changed = merge_kde_layout_list(parse_kde_layout_list(current_list), layout_ids)
    applied = True
    if changed:
        writer = "kwriteconfig6" if shutil.which("kwriteconfig6") else "kwriteconfig5"
        applied = run_reported(
            [
                writer,
                "--file",
                "kxkbrc",
                "--group",
                "Layout",
                "--key",
                "LayoutList",
                ",".join(merged),
            ],
            "KDE : disposition ajoutée à votre liste",
        )
    else:
        print("   ✅ KDE : déjà présente dans votre liste, rien à changer.")
    reconfigure = next(
        (name for name in ("qdbus6", "qdbus-qt6", "qdbus") if shutil.which(name)), None
    )
    if reconfigure:
        run_reported(
            [reconfigure, "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"],
            "KDE : reconfiguration de KWin",
        )
    return applied


def apply_x11(layout_id: str, environ: dict[str, str] | None = None) -> bool:
    """Switch the running X11 session immediately.

    Skipped under Wayland: ``setxkbmap`` only reaches the Xwayland compatibility
    server there, which the compositor overwrites with its own keymap.
    """
    if session_type(environ) != "x11":
        return False
    if not shutil.which("setxkbmap"):
        print("   ℹ️  setxkbmap absent : application immédiate X11 ignorée.")
        return False
    return run_reported(
        ["setxkbmap", layout_id], "X11 : disposition appliquée immédiatement"
    )


def manual_instructions(layout_id: str, tokens: set[str], kind: str) -> list[str]:
    """Build the manual configuration lines for a session we could not drive.

    Three cases, in order of usefulness: a GNOME or KDE session whose settings
    we failed to write gets the command to retry by hand, a known wlroots
    compositor gets its own configuration snippet, and anything else on Wayland
    gets the ``environment.d`` fallback that every libxkbcommon-based
    compositor honours at startup. An X11 session we could not drive gets
    nothing here: ``setxkbmap`` already reported why.
    """
    if is_gnome_session(tokens):
        return [
            "   ℹ️  Réessayez depuis votre session graphique, sans sudo :",
            f"        gsettings set {GNOME_SCHEMA} {GNOME_KEY} "
            f'"[(\'xkb\', \'{layout_id}\')]"',
        ]
    if is_kde_session(tokens):
        return [
            "   ℹ️  Ajoutez la disposition depuis Configuration › Clavier › "
            "Dispositions, ou en ligne de commande :",
            f"        kwriteconfig6 --file kxkbrc --group Layout --key LayoutList {layout_id}",
        ]
    hint = compositor_hint(tokens)
    if hint is None and kind != "wayland":
        return []
    path, snippet = (
        hint if hint is not None else (GENERIC_WAYLAND_FILE, GENERIC_WAYLAND_SNIPPET)
    )
    lines = [
        "   ℹ️  Votre session gère elle-même sa disposition clavier.",
        f"      Ajoutez ceci dans {path} :",
    ]
    lines.extend(f"        {line}" for line in snippet.format(layout=layout_id).splitlines())
    lines.append("      Puis reconnectez-vous.")
    return lines


def verify_keymap(
    layout_id: str, required_type: str, extensions_root: Path | None = None
) -> bool:
    """Prove the installed package resolves and carries the custom types.

    This is the only check that does not depend on the desktop: it compiles the
    layout exactly as a compositor would and looks for the type that owns the
    Shift and AltGr layers. A pass here with a dead Shift key means the session
    is not using the layout; a failure means the package itself is not visible.

    ``extensions_root`` is passed only by the sandboxed test runs. A real
    installation deliberately leaves it unset so the check resolves through the
    distribution's own search path: overriding it would prove the files exist
    while the session still cannot find them.
    """
    xkbcli = shutil.which("xkbcli")
    if not xkbcli:
        print("   ℹ️  xkbcli absent : vérification de la keymap impossible.")
        return False
    env = None
    if extensions_root is not None:
        env = {
            "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(extensions_root),
            "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH": "",
        }
    keymap = run_capture(
        [xkbcli, "compile-keymap", "--rules", "evdev", "--layout", layout_id],
        timeout=60,
        env=env,
    )
    if keymap is None:
        print(
            f"   ❌ La disposition « {layout_id} » ne compile pas : le paquet "
            "n'est pas visible par libxkbcommon."
        )
        return False
    if required_type not in keymap:
        print(
            f"   ❌ La keymap compile mais le type {required_type} est absent : "
            "les couches Shift et AltGr resteraient mortes."
        )
        return False
    print(
        f"   ✅ Keymap vérifiée : « {layout_id} » compile et "
        f"contient {required_type}."
    )
    return True


def activate_layout(layout_ids: list[str], environ: dict[str, str] | None = None) -> bool:
    """Activate the layout in the current desktop session.

    ``layout_ids`` is ordered by preference; the first one becomes the active
    layout. Returns True when at least one desktop accepted the change.
    """
    if not layout_ids:
        raise ValueError("activate_layout requires at least one layout id")
    primary = layout_ids[0]
    tokens = desktop_tokens(environ)
    kind = session_type(environ)
    print(f"🚀 Activation ({describe_session(environ)})…")
    if running_as_root():
        print(
            "   ⚠️  Activation lancée en root : dconf et D-Bus appartiennent à "
            "votre session utilisateur, l'écriture serait sans effet."
        )
        return False
    gnome_applied = apply_gnome(layout_ids, tokens)
    kde_applied = apply_kde(layout_ids, tokens)
    x11_applied = apply_x11(primary, environ)
    # A successful write only counts when the desktop that owns the setting is
    # the one running: gsettings and kwriteconfig succeed on compositors that
    # never read them, and treating that as success is how a layout silently
    # stays inactive.
    handled = (
        (gnome_applied and is_gnome_session(tokens))
        or (kde_applied and is_kde_session(tokens))
        or x11_applied
    )
    if not handled:
        for line in manual_instructions(primary, tokens, kind):
            print(line)
    applied = gnome_applied or kde_applied or x11_applied
    print(
        "   ℹ️  Déconnectez-vous/reconnectez-vous si la disposition "
        "n'est pas active."
    )
    return applied
