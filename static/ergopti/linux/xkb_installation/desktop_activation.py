"""Desktop-session activation shared by both Ergopti XKB installers.

Activation is the step that tells the running desktop to *use* the layout the
installer just wrote to disk. It is the part of the installation that cannot
run with elevated privileges: GNOME stores the layout list in the user's dconf
database and reaches it over the user's D-Bus session bus, so a process running
as root writes into root's dconf and silently changes nothing (issue #84).

The module therefore owns four responsibilities:

- refuse, or drop back to, the desktop user before touching any session state;
- apply the layout on the desktops that expose a documented setting
  (GNOME-based sessions through gsettings, KDE Plasma through kwriteconfig,
  X11 through setxkbmap) and report each outcome;
- print an exact, copy-pasteable instruction for every other session, because
  wlroots compositors (Sway, Hyprland, niri, river, …) have no shared setting
  and can only be configured from their own configuration file;
- prove, with libxkbcommon's own compiler, that the installed layout resolves
  and carries the custom key type, alone and next to another layout.

Everything here is best-effort by contract: a desktop we cannot reach is
reported to the user, never silently swallowed and never fatal.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from enum import Enum
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from layout_package import (  # noqa: E402
    LayoutSpec,
    format_gsettings_sources,
    format_kde_layouts,
    is_ergopti_source,
    is_ergopti_spec,
    merge_gsettings_source,
    merge_layout_specs,
    parse_gsettings_sources,
    parse_kde_layouts,
    remove_layout_specs,
)

ENV_USER_HOME = "ERGOPTI_XKB_USER_HOME"

GNOME_SCHEMA = "org.gnome.desktop.input-sources"
GNOME_KEY = "sources"
# gnome-shell activates the first entry of this list at login, not the first
# entry of ``sources``: a layout that is first in ``sources`` but absent from
# the most-recently-used list stays inactive until the user switches by hand.
GNOME_MRU_KEY = "mru-sources"

KDE_FILE = "kxkbrc"
KDE_GROUP = "Layout"
KDE_LAYOUTS_KEY = "LayoutList"
KDE_VARIANTS_KEY = "VariantList"
KDE_NAMES_KEY = "DisplayNames"
# Plasma only applies its own layout list when this key is true; otherwise the
# list is ignored and the system default layout stays active.
KDE_USE_KEY = "Use"

# Layout used as the companion when proving a multi-layout keymap still carries
# the custom type: ``us`` ships with every xkeyboard-config.
COMPANION_LAYOUT = LayoutSpec("us")

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


class CleanupStatus(Enum):
    ABSENT = "absent"
    CHANGED = "changed"
    FAILED = "failed"


class CommandCaptureStatus(Enum):
    ABSENT = "absent"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


# ---------------------------------------------------------------------------
# Compositor configuration snippets
# ---------------------------------------------------------------------------


def _hyprland_lines(spec: LayoutSpec) -> list[str]:
    lines = ["input {", f"    kb_layout = {spec.layout}"]
    if spec.variant:
        lines.append(f"    kb_variant = {spec.variant}")
    return lines + ["}"]


def _sway_lines(spec: LayoutSpec) -> list[str]:
    lines = ["input * {", f'    xkb_layout "{spec.layout}"']
    if spec.variant:
        lines.append(f'    xkb_variant "{spec.variant}"')
    return lines + ["}"]


def _niri_lines(spec: LayoutSpec) -> list[str]:
    lines = ["input {", "    keyboard {", "        xkb {", f'            layout "{spec.layout}"']
    if spec.variant:
        lines.append(f'            variant "{spec.variant}"')
    return lines + ["        }", "    }", "}"]


def _river_lines(spec: LayoutSpec) -> list[str]:
    if spec.variant:
        return [f"riverctl keyboard-layout -variant {spec.variant} {spec.layout}"]
    return [f"riverctl keyboard-layout {spec.layout}"]


def _wayfire_lines(spec: LayoutSpec) -> list[str]:
    lines = ["[input]", f"xkb_layout = {spec.layout}"]
    if spec.variant:
        lines.append(f"xkb_variant = {spec.variant}")
    return lines


def _environment_lines(spec: LayoutSpec) -> list[str]:
    lines = [f"XKB_DEFAULT_LAYOUT={spec.layout}"]
    if spec.variant:
        lines.append(f"XKB_DEFAULT_VARIANT={spec.variant}")
    return lines


# Compositors that own their keyboard configuration in their own file. The
# value is the configuration path and the builder of the exact snippet to add.
COMPOSITOR_INSTRUCTIONS: dict[str, tuple[str, Callable[[LayoutSpec], list[str]]]] = {
    "hyprland": ("~/.config/hypr/hyprland.conf", _hyprland_lines),
    "sway": ("~/.config/sway/config", _sway_lines),
    "niri": ("~/.config/niri/config.kdl", _niri_lines),
    "river": ("~/.config/river/init", _river_lines),
    "wayfire": ("~/.config/wayfire.ini", _wayfire_lines),
    "labwc": ("~/.config/labwc/environment", _environment_lines),
}

# Last-resort instruction for any Wayland session we do not recognise: every
# libxkbcommon-based compositor reads these variables at startup.
GENERIC_WAYLAND_FILE = "~/.config/environment.d/90-ergopti.conf"


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


def compositor_hint(tokens: set[str]) -> tuple[str, Callable[[LayoutSpec], list[str]]] | None:
    """Return the (configuration file, snippet builder) pair for a known compositor."""
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


def resolve_user_identity() -> tuple[Path, int | None, int | None]:
    """Return the desktop user's home and ownership, even under sudo or doas.

    The sandbox override wins so tests never touch a real home directory.
    """
    sandbox_home = os.environ.get(ENV_USER_HOME)
    if sandbox_home:
        return Path(sandbox_home), None, None
    user = desktop_user()
    if user:
        try:
            import pwd

            entry = pwd.getpwnam(user)
            return Path(entry.pw_dir), entry.pw_uid, entry.pw_gid
        except (ImportError, KeyError):
            pass
    uid_fn = getattr(os, "getuid", None)
    gid_fn = getattr(os, "getgid", None)
    uid = uid_fn() if callable(uid_fn) else None
    gid = gid_fn() if callable(gid_fn) else None
    return Path.home(), uid, gid


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


def build_drop_command(
    tool: str, user: str, environment: dict[str, str], argv: list[str]
) -> list[str]:
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
        for name in (
            "DISPLAY",
            "XAUTHORITY",
            "XDG_CURRENT_DESKTOP",
            "XDG_SESSION_TYPE",
            "WAYLAND_DISPLAY",
            "PATH",
        )
        if os.environ.get(name)
    }
    environment.update(session_bus_env(user))
    command = build_drop_command(tool, user, environment, argv)
    # Flush before spawning: the child writes to the same terminal, and an
    # unflushed parent buffer would print this line after the child's output.
    print(f"   ↩️  Activation relancée sans privilèges pour l'utilisateur {user}.", flush=True)
    try:
        return subprocess.run(command, check=False, timeout=180).returncode
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


def run_capture_status(command: list[str], timeout: int = 15) -> tuple[CommandCaptureStatus, str]:
    """Like ``run_capture`` but distinguishes an absent tool from a failure."""
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return CommandCaptureStatus.ABSENT, ""
    except (subprocess.TimeoutExpired, OSError):
        return CommandCaptureStatus.FAILED, ""
    if result.returncode != 0:
        return CommandCaptureStatus.FAILED, ""
    return CommandCaptureStatus.SUCCEEDED, result.stdout


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
# GNOME
# ---------------------------------------------------------------------------


def _gnome_get(key: str) -> list[tuple[str, str]] | None:
    raw = run_capture(["gsettings", "get", GNOME_SCHEMA, key])
    if raw is None:
        return None
    return parse_gsettings_sources(raw)


def _gnome_set(key: str, pairs: list[tuple[str, str]], label: str) -> bool:
    return run_reported(
        ["gsettings", "set", GNOME_SCHEMA, key, format_gsettings_sources(pairs)], label
    )


def apply_gnome(specs: list[LayoutSpec], tokens: set[str]) -> bool:
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
    wanted = [("xkb", spec.gnome_id) for spec in specs]
    merged, changed = merge_gsettings_source(current_sources, wanted, make_primary=True)
    if changed:
        if not _gnome_set(GNOME_KEY, merged, "GNOME : disposition placée en tête de vos sources"):
            return False
        readback = parse_gsettings_sources(
            run_capture(["gsettings", "get", GNOME_SCHEMA, GNOME_KEY]) or ""
        )
        if readback != merged:
            print(
                "   ❌ GNOME : la valeur n'a pas été enregistrée (relue : "
                f"{format_gsettings_sources(readback or [])}). Lancez l'activation "
                "depuis votre session graphique, sans sudo."
            )
            return False
        print(f"   ✅ GNOME : valeur confirmée {format_gsettings_sources(readback)}.")
    else:
        print("   ✅ GNOME : la disposition est déjà en première position.")
    _gnome_make_most_recent(wanted, changed)
    return True


def _gnome_make_most_recent(wanted: list[tuple[str, str]], sources_changed: bool) -> None:
    """Make the layout the most recently used one so it is active at login."""
    if sources_changed:
        # Give gnome-shell a moment to react to the sources change, otherwise
        # its own MRU rewrite can land after ours and undo it.
        time.sleep(1.0)
    current = _gnome_get(GNOME_MRU_KEY)
    if current is None:
        print("   ℹ️  GNOME : liste des dispositions récentes illisible, étape ignorée.")
        return
    merged, changed = merge_gsettings_source(current, wanted, make_primary=True)
    if not changed:
        print("   ✅ GNOME : déjà la disposition la plus récente.")
        return
    _gnome_set(GNOME_MRU_KEY, merged, "GNOME : disposition marquée comme la plus récente")


# ---------------------------------------------------------------------------
# KDE Plasma
# ---------------------------------------------------------------------------


def _kde_reader() -> str | None:
    return next((name for name in ("kreadconfig6", "kreadconfig5") if shutil.which(name)), None)


def _kde_writer() -> str | None:
    return next((name for name in ("kwriteconfig6", "kwriteconfig5") if shutil.which(name)), None)


def _kde_read(reader: str, key: str) -> tuple[CommandCaptureStatus, str]:
    status, value = run_capture_status(
        [reader, "--file", KDE_FILE, "--group", KDE_GROUP, "--key", key]
    )
    return status, value.strip()


def _kde_write(writer: str, key: str, value: str, label: str) -> bool:
    return run_reported(
        [writer, "--file", KDE_FILE, "--group", KDE_GROUP, "--key", key, value], label
    )


def _kde_display_names(
    previous: list[LayoutSpec], names_value: str, merged: list[LayoutSpec]
) -> str | None:
    """Realign the optional ``DisplayNames`` list with the new layout order."""
    if not names_value:
        return None
    names = names_value.split(",")
    by_spec = {spec: names[index] if index < len(names) else "" for index, spec in enumerate(previous)}
    return ",".join(by_spec.get(spec, "") for spec in merged)


def _kde_reload() -> None:
    """Tell the keyboard daemon (X11) and KWin (Wayland) to reread kxkbrc."""
    if shutil.which("dbus-send"):
        run_reported(
            ["dbus-send", "--session", "--type=signal", "/Layouts", "org.kde.keyboard.reloadConfig"],
            "KDE : rechargement de la configuration clavier",
        )
    reconfigure = next(
        (name for name in ("qdbus6", "qdbus-qt6", "qdbus") if shutil.which(name)), None
    )
    if reconfigure:
        run_reported(
            [reconfigure, "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"],
            "KDE : reconfiguration de KWin",
        )


def apply_kde(specs: list[LayoutSpec], tokens: set[str]) -> bool:
    """Put the layout first in Plasma's layout list and make Plasma apply it.

    Plasma keeps the layout and the variant in two index-aligned lists and only
    honours them when ``Use=true``; writing ``LayoutList`` alone leaves the
    system default active.
    """
    reader = _kde_reader()
    if reader is None:
        if is_kde_session(tokens):
            print("   ⚠️  KDE détecté mais kreadconfig est introuvable : étape ignorée.")
        else:
            print("   ℹ️  kreadconfig absent : étape KDE ignorée.")
        return False
    layouts_status, layouts_value = _kde_read(reader, KDE_LAYOUTS_KEY)
    if layouts_status is CommandCaptureStatus.FAILED:
        print("   ⚠️  KDE : lecture de kxkbrc impossible, étape ignorée.")
        return False
    _, variants_value = _kde_read(reader, KDE_VARIANTS_KEY)
    _, names_value = _kde_read(reader, KDE_NAMES_KEY)
    _, use_value = _kde_read(reader, KDE_USE_KEY)
    current = parse_kde_layouts(layouts_value, variants_value)
    merged, changed = merge_layout_specs(current, specs)
    writer = _kde_writer()
    if writer is None:
        print("   ⚠️  KDE : kwriteconfig introuvable, la liste n'a pas été modifiée.")
        return False
    applied = True
    if changed:
        layout_list, variant_list = format_kde_layouts(merged)
        applied = _kde_write(writer, KDE_LAYOUTS_KEY, layout_list, "KDE : dispositions") and _kde_write(
            writer, KDE_VARIANTS_KEY, variant_list, "KDE : variantes"
        )
        names = _kde_display_names(current, names_value, merged)
        if names is not None:
            applied = _kde_write(writer, KDE_NAMES_KEY, names, "KDE : noms affichés") and applied
    else:
        print("   ✅ KDE : la disposition est déjà en première position.")
    if use_value.lower() != "true":
        applied = _kde_write(writer, KDE_USE_KEY, "true", "KDE : liste de dispositions activée") and applied
    if applied:
        _kde_reload()
    return applied


# ---------------------------------------------------------------------------
# X11
# ---------------------------------------------------------------------------


def setxkbmap_arguments(spec: LayoutSpec) -> list[str]:
    arguments = ["-layout", spec.layout]
    if spec.variant:
        arguments += ["-variant", spec.variant]
    return arguments


def apply_x11(spec: LayoutSpec, environ: dict[str, str] | None = None) -> bool:
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
        ["setxkbmap", *setxkbmap_arguments(spec)], "X11 : disposition appliquée immédiatement"
    )


# ---------------------------------------------------------------------------
# Manual instructions
# ---------------------------------------------------------------------------


def manual_instructions(spec: LayoutSpec, tokens: set[str], kind: str) -> list[str]:
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
            f'"[(\'xkb\', \'{spec.gnome_id}\')]"',
        ]
    if is_kde_session(tokens):
        return [
            "   ℹ️  Ajoutez la disposition depuis Configuration › Clavier › "
            "Dispositions, ou en ligne de commande :",
            f"        kwriteconfig6 --file {KDE_FILE} --group {KDE_GROUP} --key {KDE_LAYOUTS_KEY} {spec.layout}",
            f"        kwriteconfig6 --file {KDE_FILE} --group {KDE_GROUP} --key {KDE_VARIANTS_KEY} {spec.variant}",
            f"        kwriteconfig6 --file {KDE_FILE} --group {KDE_GROUP} --key {KDE_USE_KEY} true",
        ]
    hint = compositor_hint(tokens)
    if hint is None and kind != "wayland":
        return []
    path, builder = hint if hint is not None else (GENERIC_WAYLAND_FILE, _environment_lines)
    lines = [
        "   ℹ️  Votre session gère elle-même sa disposition clavier.",
        f"      Ajoutez ceci dans {path} :",
    ]
    lines.extend(f"        {line}" for line in builder(spec))
    lines.append("      Puis reconnectez-vous.")
    return lines


def persistence_instructions(spec: LayoutSpec) -> list[str]:
    """Tell an X11 session without a layout manager how to keep the layout.

    ``setxkbmap`` only lasts until logout; the system default read by Xorg and
    by every display manager lives in ``xorg.conf.d``. Changing it silently
    would affect the login screen of every account, so it stays a printed
    instruction.
    """
    lines = ["   ℹ️  Pour conserver la disposition après déconnexion :"]
    if shutil.which("localectl"):
        command = f"sudo localectl set-x11-keymap {spec.layout} pc105"
        if spec.variant:
            command += f" {spec.variant}"
        lines.append(f"        {command}")
        return lines
    lines.append("        (dans /etc/X11/xorg.conf.d/00-keyboard.conf)")
    lines.extend(
        [
            '        Section "InputClass"',
            '            Identifier "system-keyboard"',
            '            MatchIsKeyboard "on"',
            f'            Option "XkbLayout" "{spec.layout}"',
        ]
    )
    if spec.variant:
        lines.append(f'            Option "XkbVariant" "{spec.variant}"')
    lines.append("        EndSection")
    return lines


# ---------------------------------------------------------------------------
# Keymap verification
# ---------------------------------------------------------------------------


def rmlvo_arguments(layouts: list[LayoutSpec]) -> list[str]:
    """Render the ``--layout``/``--variant`` pair for a list of layouts."""
    return [
        "--layout",
        ",".join(spec.layout for spec in layouts),
        "--variant",
        ",".join(spec.variant for spec in layouts),
    ]


def compile_rmlvo(
    xkbcli: str,
    layouts: list[LayoutSpec],
    include_roots: list[Path] | None = None,
    extensions_root: Path | None = None,
) -> str | None:
    """Compile a keymap with libxkbcommon's own compiler; ``None`` on failure.

    ``include_roots`` are searched before the default paths, which is how a
    sandboxed system tree shadows the host's. ``extensions_root`` replaces the
    default XKB extensions directories, which is how a staged clean package is
    proven before it is committed.
    """
    command = [xkbcli, "compile-keymap", "--rules", "evdev", "--model", "pc105"]
    command += rmlvo_arguments(layouts)
    for root in include_roots or []:
        command += ["--include", str(root)]
    if include_roots:
        command.append("--include-defaults")
    env = None
    if extensions_root is not None:
        env = {
            "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(extensions_root),
            # Keep the versioned path out of the way so the staging tree is authoritative.
            "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH": "",
        }
    return run_capture(command, timeout=60, env=env)


def keymap_has_type(keymap: str, type_name: str) -> bool:
    return f'type "{type_name}"' in keymap


def describe_rmlvo(layouts: list[LayoutSpec]) -> str:
    return ",".join(spec.gnome_id for spec in layouts)


def verify_keymap(
    spec: LayoutSpec,
    required_type: str,
    include_roots: list[Path] | None = None,
    extensions_root: Path | None = None,
) -> bool | None:
    """Prove the installed layout resolves and carries the custom types.

    The check compiles the layout exactly as a compositor would, alone and
    next to a companion layout in both orders, because rules that only match
    single-layout configurations are the failure that killed the Shift and
    AltGr layers for every user who kept a second keyboard (issue #84). A pass
    with a dead Shift key then means the session is not using the layout; a
    failure means the package itself is wrong.

    Returns ``None`` when libxkbcommon's compiler is not installed, so callers
    can distinguish "unverified" from "broken".
    """
    xkbcli = shutil.which("xkbcli")
    if not xkbcli:
        print("   ℹ️  xkbcli absent : vérification de la keymap impossible.")
        return None
    cases = [[spec], [spec, COMPANION_LAYOUT], [COMPANION_LAYOUT, spec]]
    for layouts in cases:
        label = describe_rmlvo(layouts)
        keymap = compile_rmlvo(xkbcli, layouts, include_roots, extensions_root)
        if keymap is None:
            print(
                f"   ❌ La configuration « {label} » ne compile pas : la disposition "
                "n'est pas visible par libxkbcommon."
            )
            return False
        if not keymap_has_type(keymap, required_type):
            print(
                f"   ❌ « {label} » compile mais sans le type {required_type} : "
                "les couches Maj et AltGr resteraient mortes."
            )
            return False
    print(
        f"   ✅ Keymap vérifiée : « {spec.gnome_id} » compile avec {required_type}, "
        "seule et à côté d'une autre disposition."
    )
    return True


# ---------------------------------------------------------------------------
# Deactivation
# ---------------------------------------------------------------------------


def deactivate_layouts(owned: Callable[[LayoutSpec], bool] = is_ergopti_spec) -> CleanupStatus:
    """Remove every Ergopti desktop entry and preserve all the others.

    Runs unprivileged for the same reason as activation: the entries live in
    the user's dconf and Plasma configuration, which root cannot reach.
    """
    changed = False
    failed = False

    gnome_status, current_raw = run_capture_status(
        ["gsettings", "get", GNOME_SCHEMA, GNOME_KEY]
    )
    if gnome_status is CommandCaptureStatus.FAILED:
        failed = True
    elif gnome_status is CommandCaptureStatus.SUCCEEDED:
        current_sources = parse_gsettings_sources(current_raw)
        if current_sources is None:
            failed = True
        else:
            kept = [
                pair
                for pair in current_sources
                if not (pair[0] == "xkb" and owned(LayoutSpec.parse(pair[1])))
            ]
            if kept != current_sources:
                if _gnome_set(GNOME_KEY, kept, "GNOME : sources Ergopti retirées"):
                    changed = True
                else:
                    failed = True
            mru = _gnome_get(GNOME_MRU_KEY)
            if mru:
                kept_mru = [
                    pair
                    for pair in mru
                    if not (pair[0] == "xkb" and owned(LayoutSpec.parse(pair[1])))
                ]
                if kept_mru != mru:
                    _gnome_set(GNOME_MRU_KEY, kept_mru, "GNOME : dispositions récentes nettoyées")

    reader = _kde_reader()
    if reader is not None:
        layouts_status, layouts_value = _kde_read(reader, KDE_LAYOUTS_KEY)
        if layouts_status is CommandCaptureStatus.FAILED:
            failed = True
        elif layouts_status is CommandCaptureStatus.SUCCEEDED:
            _, variants_value = _kde_read(reader, KDE_VARIANTS_KEY)
            _, names_value = _kde_read(reader, KDE_NAMES_KEY)
            current = parse_kde_layouts(layouts_value, variants_value)
            kept, removed = remove_layout_specs(current, owned)
            if removed:
                writer = _kde_writer()
                layout_list, variant_list = format_kde_layouts(kept)
                if writer and _kde_write(
                    writer, KDE_LAYOUTS_KEY, layout_list, "KDE : dispositions Ergopti retirées"
                ) and _kde_write(writer, KDE_VARIANTS_KEY, variant_list, "KDE : variantes"):
                    names = _kde_display_names(current, names_value, kept)
                    if names is not None:
                        _kde_write(writer, KDE_NAMES_KEY, names, "KDE : noms affichés")
                    changed = True
                    _kde_reload()
                else:
                    failed = True
    if failed:
        return CleanupStatus.FAILED
    return CleanupStatus.CHANGED if changed else CleanupStatus.ABSENT


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def activate_layout(specs: list[LayoutSpec], environ: dict[str, str] | None = None) -> bool:
    """Activate the layout in the current desktop session.

    ``specs`` is ordered by preference; the first one becomes the active
    layout. Returns True when at least one desktop accepted the change.
    """
    if not specs:
        raise ValueError("activate_layout requires at least one layout")
    primary = specs[0]
    tokens = desktop_tokens(environ)
    kind = session_type(environ)
    print(f"🚀 Activation de « {primary.gnome_id} » ({describe_session(environ)})…")
    if running_as_root():
        print(
            "   ⚠️  Activation lancée en root : dconf et D-Bus appartiennent à "
            "votre session utilisateur, l'écriture serait sans effet."
        )
        return False
    gnome_applied = apply_gnome(specs, tokens)
    kde_applied = apply_kde(specs, tokens)
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
    if x11_applied and not (is_gnome_session(tokens) or is_kde_session(tokens)):
        for line in persistence_instructions(primary):
            print(line)
    print(
        "   ℹ️  Déconnectez-vous/reconnectez-vous si la disposition "
        "n'est pas active."
    )
    return gnome_applied or kde_applied or x11_applied
