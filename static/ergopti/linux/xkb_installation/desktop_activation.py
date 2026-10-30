"""Desktop-session activation shared by both Ergopti XKB installers.

Activation is the step that tells the running desktop to *use* the layout the
installer just wrote to disk. It is the part of the installation that cannot
run with elevated privileges: GNOME stores the layout list in the user's dconf
database and reaches it over the user's D-Bus session bus, so a process running
as root writes into root's dconf and silently changes nothing (issue #84).

The module therefore owns four responsibilities:

- refuse, or drop back to, the desktop user before touching any session state;
- apply the layout on the desktop that owns the setting (GNOME-based sessions
  through gsettings, KDE Plasma through kwriteconfig, X11 through setxkbmap)
  and report each outcome, without pretending a write into a setting nobody
  reads is an activation;
- print an exact, copy-pasteable instruction for every other session, because
  wlroots compositors (Sway, Hyprland, niri, river, ...) have no shared setting
  and can only be configured from their own configuration file;
- prove, with the real compilers, that the installed layout resolves, binds
  the custom key type to its keys and carries the Ctrl level, alone and next
  to another layout; a compiler's own diagnostics are printed whenever a check
  fails so a bug report contains the cause and not just the symptom.

Activation is best-effort: an unreachable desktop receives manual instructions.
Deactivation must confirm removal before the installer deletes layout files;
an unreadable setting is not evidence that no reference remains. A keymap that
does not verify is a failed installation.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import traceback
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from layout_package import (  # noqa: E402
    EXIT_INSTALL_ABORTED,
    LayoutSpec,
    format_gsettings_sources,
    format_kde_layouts,
    is_ergopti_spec,
    keymap_defines_type,
    keymap_key_block,
    keymap_key_symbols,
    keymap_key_type,
    keymap_type_level,
    keymap_type_preserves,
    merge_gsettings_source,
    merge_layout_specs,
    parse_gsettings_sources,
    parse_kde_layouts,
    parse_version,
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

# Key used to prove that the compiled keymap really binds the custom type: it
# carries è on every Ergopti variant, ISO and ANSI alike, and its Ctrl level is
# what turns Ctrl+è into Ctrl+Z.
PROBE_KEY = "<AD01>"
# The modifier whose dedicated level is the "custom Ctrl layer" feature.
CONTROL_MODIFIER = "Control"

# libxkbcommon only prints fatal errors by default; these make it report every
# diagnostic on stderr so a failed check can be explained.
XKB_DIAGNOSTIC_ENV = {"XKB_LOG_LEVEL": "warning", "XKB_LOG_VERBOSITY": "10"}

# Compiler chatter that never explains a failure and would bury the real cause.
_DIAGNOSTIC_NOISE = (
    "multiple definitions of the",
    "earlier definition ignored",
    "deprecated keysym name",
    "are not supported by x",
)
# Words that mark a line worth showing even when it does not name the component.
_DIAGNOSTIC_SIGNALS = (
    "error",
    "can't",
    "cannot",
    "couldn't",
    "could not",
    "abandon",
    "exiting",
    "not defined",
    "no such",
)

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

# Package that provides ``xkbcli`` per distribution family (os-release ID or
# ID_LIKE token). Arch ships it inside libxkbcommon itself.
XKBCLI_PACKAGES = {
    "debian": "libxkbcommon-tools (apt)",
    "ubuntu": "libxkbcommon-tools (apt)",
    "fedora": "libxkbcommon-utils (dnf)",
    "rhel": "libxkbcommon-utils (dnf)",
    "centos": "libxkbcommon-utils (dnf)",
    "suse": "libxkbcommon-tools (zypper)",
    "opensuse": "libxkbcommon-tools (zypper)",
    "arch": "libxkbcommon (pacman)",
    "alpine": "libxkbcommon-tools (apk)",
    "void": "libxkbcommon (xbps)",
}


class CleanupStatus(Enum):
    ABSENT = "absent"
    CHANGED = "changed"
    FAILED = "failed"


class CommandCaptureStatus(Enum):
    ABSENT = "absent"
    SUCCEEDED = "succeeded"
    FAILED = "failed"


# ---------------------------------------------------------------------------
# Process-wide guards
# ---------------------------------------------------------------------------


def force_utf8_stdio() -> None:
    """Keep the CLI alive on consoles that cannot encode every glyph.

    The installers print progress glyphs; on a latin-1 terminal the default
    print encoding raises UnicodeEncodeError mid-install. Reconfigure both
    streams to UTF-8 with replacement characters so output degrades instead
    of crashing.
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            continue


def run_cli(main: Callable[[list[str]], int], argv: list[str]) -> int:
    """Run an installer entry point and turn any crash into a usable report.

    A Python traceback on its own is what users paste into bug reports; the
    trailer adds the interpreter and host so the report is reproducible.
    """
    force_utf8_stdio()
    try:
        return main(argv)
    except KeyboardInterrupt:
        print("\n⚠️  Interrompu par l'utilisateur.", file=sys.stderr)
        return 130
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001 - last-resort report for the bug tracker
        print(
            "\n❌ Erreur interne de l'installeur. Copiez le bloc ci-dessous dans le rapport de bug :",
            file=sys.stderr,
        )
        traceback.print_exc()
        print(
            f"   Python {platform.python_version()} ({sys.executable}) sur {platform.platform()}",
            file=sys.stderr,
        )
        return EXIT_INSTALL_ABORTED


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


def owning_desktop(tokens: set[str]) -> str | None:
    """Name the component that owns the keyboard setting, when the session says.

    ``gnome`` and ``kde`` expose a setting the installer can write; a
    ``compositor`` keeps its own configuration file; ``None`` means the session
    did not identify itself, in which case every writable setting is tried.
    """
    if is_gnome_session(tokens):
        return "gnome"
    if is_kde_session(tokens):
        return "kde"
    if compositor_hint(tokens) is not None:
        return "compositor"
    return None


def describe_session(environ: dict[str, str] | None = None) -> str:
    """One-line human description used in every activation report."""
    env = os.environ if environ is None else environ
    desktop = env.get("XDG_CURRENT_DESKTOP") or "<inconnu>"
    return f"session {session_type(env)}, bureau {desktop}"


def os_release() -> dict[str, str]:
    """Return the ``/etc/os-release`` fields, or an empty mapping elsewhere."""
    fields: dict[str, str] = {}
    for candidate in ("/etc/os-release", "/usr/lib/os-release"):
        try:
            content = Path(candidate).read_text(encoding="utf-8")
        except OSError:
            continue
        for line in content.splitlines():
            key, separator, value = line.partition("=")
            if separator and key.strip():
                fields[key.strip()] = value.strip().strip('"').strip("'")
        break
    return fields


def xkbcli_package_hint() -> str:
    """Name the package that provides ``xkbcli`` on this distribution."""
    fields = os_release()
    tokens = [fields.get("ID", "")] + fields.get("ID_LIKE", "").split()
    for token in tokens:
        token = token.strip().lower()
        if token in XKBCLI_PACKAGES:
            return XKBCLI_PACKAGES[token]
    return "libxkbcommon-tools ou libxkbcommon-utils selon la distribution"


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


def shell_join(command: list[str], environment: dict[str, str] | None = None) -> str:
    """Render a command line the user can paste back into a terminal."""
    prefix = [f"{key}={shell_quote(value)}" for key, value in sorted((environment or {}).items())]
    return " ".join(
        prefix + [shell_quote(part) if " " in part or not part else part for part in command]
    )


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


# Version probes, first hit wins. The library's own tool comes first because it
# is distribution-independent; the package managers cover hosts without it.
LIBXKBCOMMON_VERSION_PROBES = (
    ["xkbcli", "--version"],
    ["pkg-config", "--modversion", "xkbcommon"],
    ["pacman", "-Q", "libxkbcommon"],
    ["dpkg-query", "-W", "-f=${Version}", "libxkbcommon0"],
    ["rpm", "-q", "--queryformat", "%{VERSION}", "libxkbcommon"],
    ["apk", "list", "--installed", "libxkbcommon"],
    ["xbps-query", "-p", "pkgver", "libxkbcommon"],
)
XKEYBOARD_CONFIG_VERSION_PROBES = (
    ["pkg-config", "--modversion", "xkeyboard-config"],
    ["pacman", "-Q", "xkeyboard-config"],
    # Debian and Ubuntu package xkeyboard-config as xkb-data.
    ["dpkg-query", "-W", "-f=${Version}", "xkb-data"],
    ["rpm", "-q", "--queryformat", "%{VERSION}", "xkeyboard-config"],
    ["apk", "list", "--installed", "xkeyboard-config"],
    ["xbps-query", "-p", "pkgver", "xkeyboard-config"],
)


def probe_version(probes) -> tuple[tuple[int, ...], list[str]] | None:
    """Return the first version a probe reports, with the probe that answered."""
    for command in probes:
        if not shutil.which(command[0]):
            continue
        version = parse_version(run_capture(command) or "")
        if version:
            return version, list(command)
    return None


def libxkbcommon_version() -> tuple[int, ...] | None:
    """Return the installed libxkbcommon version; ``None`` when nothing answers."""
    found = probe_version(LIBXKBCOMMON_VERSION_PROBES)
    return found[0] if found else None


def xkeyboard_config_version() -> tuple[int, ...] | None:
    """Return the installed xkeyboard-config version; ``None`` when nothing answers."""
    found = probe_version(XKEYBOARD_CONFIG_VERSION_PROBES)
    return found[0] if found else None


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


def _gnome_schema_status() -> CommandCaptureStatus:
    """Distinguish no schemas at all from a failed schema-registry query."""
    try:
        result = subprocess.run(
            ["gsettings", "list-schemas"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=15,
            check=False,
            env={**os.environ, "LC_ALL": "C"},
        )
    except (subprocess.TimeoutExpired, OSError):
        return CommandCaptureStatus.FAILED
    if result.returncode == 0:
        return (
            CommandCaptureStatus.SUCCEEDED
            if GNOME_SCHEMA in result.stdout.splitlines()
            else CommandCaptureStatus.ABSENT
        )
    # GLib exits 1 before command dispatch when its default schema source is
    # absent. Require that exact C-locale diagnostic, not any nonzero result.
    if (
        result.returncode == 1
        and not result.stdout.strip()
        and result.stderr.strip() == "No schemas installed"
    ):
        return CommandCaptureStatus.ABSENT
    return CommandCaptureStatus.FAILED


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
            f"   ⚠️  Valeur gsettings illisible : elle est laissée intacte ({current_raw.strip()})."
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
    by_spec = {
        spec: names[index] if index < len(names) else "" for index, spec in enumerate(previous)
    }
    return ",".join(by_spec.get(spec, "") for spec in merged)


def _kde_reload() -> None:
    """Tell the keyboard daemon (X11) and KWin (Wayland) to reread kxkbrc."""
    if shutil.which("dbus-send"):
        run_reported(
            [
                "dbus-send",
                "--session",
                "--type=signal",
                "/Layouts",
                "org.kde.keyboard.reloadConfig",
            ],
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
        applied = _kde_write(
            writer, KDE_LAYOUTS_KEY, layout_list, "KDE : dispositions"
        ) and _kde_write(writer, KDE_VARIANTS_KEY, variant_list, "KDE : variantes")
        names = _kde_display_names(current, names_value, merged)
        if names is not None:
            applied = _kde_write(writer, KDE_NAMES_KEY, names, "KDE : noms affichés") and applied
    else:
        print("   ✅ KDE : la disposition est déjà en première position.")
    if use_value.lower() != "true":
        applied = (
            _kde_write(writer, KDE_USE_KEY, "true", "KDE : liste de dispositions activée")
            and applied
        )
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


# A live replacement from the user XKB tree. Xorg's xkbcomp reads the tree only
# when given it with -I, and setxkbmap does not bind a layout's key types from
# the user rules, so the keymap is printed, its types section pointed at the
# layout's own types file, and compiled straight into the running server. No
# root, no logout, and every call compiles again, so a rewritten file needs no
# new name here.
X11_TOOL_TIMEOUT_SECONDS = 30

X11_APPLIED = "applied"
X11_NOT_X11 = "not_x11"
X11_NO_DISPLAY = "no_display"
X11_TOOL_MISSING = "tool_missing"
X11_COMPILE_FAILED = "compile_failed"
X11_NOT_LOADED = "not_loaded"
X11_STALE_KEYMAP = "stale_keymap"

# The keys whose cells the number-row options move. A loaded keymap is the
# installed layout only when these keys hold what the installed files declare:
# a desktop that puts back an older layout of the same name (a system copy, a
# settings daemon) keeps the name and changes the cells.
ROW_PROBE_KEYS = ("<TLDE>",) + tuple("<AE%02d>" % number for number in range(1, 13))

_TYPES_SECTION = re.compile(r'(xkb_types\s*\{\s*include\s+)"[^"]*"')
_SYMBOLS_NAME = re.compile(r'xkb_symbols\s+"([^"]*)"')


def x11_keymap_text(spec: LayoutSpec, tree_root: Path, display: str) -> str | None:
    """The keymap description of ``spec`` with its types taken from the user tree.

    ``None`` when ``setxkbmap -print`` fails. The layout's key types live in
    ``types/<layout>`` of the tree (the installer writes them there)."""
    printed = run_capture(
        ["setxkbmap", "-I" + str(tree_root), *setxkbmap_arguments(spec), "-print"],
        timeout=X11_TOOL_TIMEOUT_SECONDS,
        env={"DISPLAY": display},
    )
    if printed is None:
        return None
    if (tree_root / "types" / spec.layout).is_file():
        printed = _TYPES_SECTION.sub(r'\1"' + spec.layout + '"', printed, count=1)
    return printed


def x11_loaded_keymap(display: str) -> str | None:
    """The keymap the running server holds, as ``xkbcomp`` prints it, or ``None``."""
    return run_capture(["xkbcomp", "-xkb", display, "-"], timeout=X11_TOOL_TIMEOUT_SECONDS)


def compile_keymap_text(keymap: str, tree_root: Path) -> str | None:
    """Compiles a keymap description offline, printed the way the server prints it."""
    try:
        result = subprocess.run(
            ["xkbcomp", "-I" + str(tree_root), "-xkb", "-", "-"],
            input=keymap,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=X11_TOOL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return result.stdout if result.returncode == 0 and result.stdout else None


def keymap_layout_group(keymap: str, layout: str) -> int | None:
    """The 1-based group that holds ``layout`` in a compiled keymap, or ``None``.

    The symbols section is named from the layouts it was built from
    (``pc+us+ergopti:2+inet(evdev)``); a layout without an index is group 1."""
    match = _SYMBOLS_NAME.search(keymap or "")
    if not match:
        return None
    for part in match.group(1).split("+"):
        name, _, index = part.partition(":")
        if name.split("(", 1)[0] == layout:
            return int(index) if index.isdigit() else 1
    return None


def keymap_group_symbols(keymap: str, key: str, group: int) -> list[str]:
    """The keysym names of ``key`` in ``group``; a single-group key may be printed bare."""
    held = keymap_key_symbols(keymap, key, group)
    if held or group != 1:
        return held
    block = keymap_key_block(keymap, key) or ""
    bare = re.findall(r"\[([^\]]*)\]", block)
    return [part.strip() for part in bare[-1].split(",") if part.strip()] if bare else []


def keymap_carries_layout(held: str, expected: str, layout: str) -> bool:
    """Whether the keymap ``held`` by a server types ``layout`` as compiled in ``expected``.

    Both are printed by ``xkbcomp``, so keysym names are spelled the same way;
    the layout may sit in another group of ``held`` (a desktop with several
    input sources)."""
    held_group = keymap_layout_group(held, layout)
    expected_group = keymap_layout_group(expected, layout)
    if held_group is None or expected_group is None:
        return False
    for key in ROW_PROBE_KEYS:
        wanted = keymap_group_symbols(expected, key, expected_group)
        if keymap_group_symbols(held, key, held_group) != wanted:
            return False
    return True


def apply_x11_user_tree(
    spec: LayoutSpec, tree_root: Path, environ: dict[str, str] | None = None
) -> tuple[bool, str]:
    """Replaces the running X11 keymap with a layout of the user XKB tree.

    Returns ``(applied, code)`` with a closed code: ``applied``, ``not_x11``,
    ``no_display``, ``tool_missing``, ``compile_failed``, ``not_loaded`` (the
    server compiled the upload but still holds another layout, which is what a
    desktop that re-applies its own settings looks like) or ``stale_keymap``
    (the server holds a layout of that name whose number row is not the
    installed one). Only a server keymap read back after the upload proves the
    layout is in use."""
    env = os.environ if environ is None else environ
    if session_type(environ) != "x11":
        return False, X11_NOT_X11
    display = env.get("DISPLAY", "")
    if not display:
        return False, X11_NO_DISPLAY
    if not (shutil.which("setxkbmap") and shutil.which("xkbcomp")):
        return False, X11_TOOL_MISSING
    keymap = x11_keymap_text(spec, tree_root, display)
    expected = compile_keymap_text(keymap, tree_root) if keymap is not None else None
    if expected is None:
        return False, X11_COMPILE_FAILED
    try:
        result = subprocess.run(
            ["xkbcomp", "-I" + str(tree_root), "-", display],
            input=keymap,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=X11_TOOL_TIMEOUT_SECONDS,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False, X11_COMPILE_FAILED
    if result.returncode != 0:
        return False, X11_COMPILE_FAILED
    held = x11_loaded_keymap(display)
    if keymap_layout_group(held or "", spec.layout) is None:
        return False, X11_NOT_LOADED
    if not keymap_carries_layout(held or "", expected, spec.layout):
        return False, X11_STALE_KEYMAP
    return True, X11_APPLIED


# ---------------------------------------------------------------------------
# Wayland live replacement (GNOME, KDE)
# ---------------------------------------------------------------------------

# A compositor compiles a keymap again when the selected layout id changes;
# rewriting the files of the selected id and writing the same setting back
# changes nothing it can see. Each build therefore alternates between two ids,
# the layout's own and the same id with LIVE_SLOT_SUFFIX, and the desktop
# setting moves from the one in use to the other. Both stay installed, so at
# most two copies of a layout ever exist.
LIVE_SLOT_SUFFIX = "_live"

WAYLAND_APPLIED = "applied"
WAYLAND_SESSION_UNSUPPORTED = "session_unsupported"
WAYLAND_NO_DISPLAY = "no_display"
WAYLAND_TOOL_MISSING = "tool_missing"
WAYLAND_COMPILE_FAILED = "compile_failed"
WAYLAND_SELECT_REFUSED = "select_refused"
WAYLAND_NOT_LOADED = "not_loaded"
WAYLAND_STALE_KEYMAP = "stale_keymap"

# The compositor compiles the new keymap in its own time after the setting
# changes; XWayland then receives it. A bounded poll, never a fixed sleep.
WAYLAND_READBACK_SECONDS = 10.0
WAYLAND_READBACK_INTERVAL_SECONDS = 0.2


def live_slots(layout_id: str) -> tuple[str, str]:
    """The two ids a layout alternates between on a Wayland desktop."""
    return layout_id, layout_id + LIVE_SLOT_SUFFIX


def wayland_live_desktop(environ: dict[str, str] | None = None) -> str | None:
    """``gnome`` or ``kde`` when this Wayland session selects layouts through a
    setting this module can write and read back; ``None`` for every other session."""
    if session_type(environ) != "wayland":
        return None
    owner = owning_desktop(desktop_tokens(environ))
    return owner if owner in ("gnome", "kde") else None


@dataclass
class DesktopSelection:
    """The desktop setting before a live selection, to put back on a refusal."""

    desktop: str
    values: dict[str, str]
    slot_in_use: str | None


def _read_gnome_selection(slots: tuple[str, str]) -> DesktopSelection | None:
    values = {}
    for key in (GNOME_KEY, GNOME_MRU_KEY):
        raw = run_capture(["gsettings", "get", GNOME_SCHEMA, key])
        if raw is None or parse_gsettings_sources(raw) is None:
            return None
        values[key] = raw.strip()
    sources = parse_gsettings_sources(values[GNOME_KEY]) or []
    in_use = next((ident for kind, ident in sources if kind == "xkb" and ident in slots), None)
    return DesktopSelection("gnome", values, in_use)


def _read_kde_selection(slots: tuple[str, str]) -> DesktopSelection | None:
    reader = _kde_reader()
    if reader is None or _kde_writer() is None:
        return None
    values = {}
    for key in (KDE_LAYOUTS_KEY, KDE_VARIANTS_KEY, KDE_NAMES_KEY, KDE_USE_KEY):
        status, value = _kde_read(reader, key)
        if status is CommandCaptureStatus.FAILED:
            return None
        values[key] = value
    layouts = parse_kde_layouts(values[KDE_LAYOUTS_KEY], values[KDE_VARIANTS_KEY])
    in_use = next(
        (spec.layout for spec in layouts if spec.layout in slots and not spec.variant), None
    )
    return DesktopSelection("kde", values, in_use)


def read_desktop_selection(desktop: str, slots: tuple[str, str]) -> DesktopSelection | None:
    """The current setting, or ``None`` when it cannot be read (never overwritten then)."""
    if desktop == "gnome":
        return _read_gnome_selection(slots)
    return _read_kde_selection(slots)


def _gnome_select(slot: str, slots: tuple[str, str], selection: DesktopSelection) -> bool:
    for key in (GNOME_KEY, GNOME_MRU_KEY):
        current = parse_gsettings_sources(selection.values[key]) or []
        wanted = [("xkb", slot)] + [
            pair for pair in current if not (pair[0] == "xkb" and pair[1] in slots)
        ]
        if not _gnome_set(key, wanted, "GNOME : disposition " + slot):
            return False
        readback = parse_gsettings_sources(
            run_capture(["gsettings", "get", GNOME_SCHEMA, key]) or ""
        )
        if readback != wanted:
            return False
    return True


def _kde_select(slot: str, slots: tuple[str, str], selection: DesktopSelection) -> bool:
    writer, reader = _kde_writer(), _kde_reader()
    if writer is None or reader is None:
        return False
    current = parse_kde_layouts(
        selection.values[KDE_LAYOUTS_KEY], selection.values[KDE_VARIANTS_KEY]
    )
    kept, _ = remove_layout_specs(current, lambda spec: spec.layout in slots and not spec.variant)
    merged = [LayoutSpec(slot)] + kept
    layout_list, variant_list = format_kde_layouts(merged)
    written = _kde_write(writer, KDE_LAYOUTS_KEY, layout_list, "KDE : dispositions")
    written = written and _kde_write(writer, KDE_VARIANTS_KEY, variant_list, "KDE : variantes")
    names = _kde_display_names(current, selection.values[KDE_NAMES_KEY], merged)
    if names is not None:
        written = written and _kde_write(writer, KDE_NAMES_KEY, names, "KDE : noms affichés")
    if selection.values[KDE_USE_KEY].lower() != "true":
        written = written and _kde_write(writer, KDE_USE_KEY, "true", "KDE : liste activée")
    if not written:
        return False
    _, readback = _kde_read(reader, KDE_LAYOUTS_KEY)
    if readback != layout_list:
        return False
    _kde_reload()
    return True


def restore_desktop_selection(selection: DesktopSelection) -> bool:
    """Writes back the setting read before a refused live selection."""
    if selection.desktop == "gnome":
        restored = True
        for key in (GNOME_KEY, GNOME_MRU_KEY):
            pairs = parse_gsettings_sources(selection.values[key]) or []
            restored = _gnome_set(key, pairs, "GNOME : réglage précédent rétabli") and restored
        return restored
    writer = _kde_writer()
    if writer is None:
        return False
    restored = True
    for key in (KDE_LAYOUTS_KEY, KDE_VARIANTS_KEY, KDE_NAMES_KEY, KDE_USE_KEY):
        restored = (
            _kde_write(writer, key, selection.values[key], "KDE : réglage précédent rétabli")
            and restored
        )
    if restored:
        _kde_reload()
    return restored


def wait_for_xwayland_keymap(spec: LayoutSpec, tree_root: Path, display: str) -> str:
    """Polls XWayland, which receives the compositor's keymap, until it holds
    ``spec`` as compiled from the user tree. Returns a closed code."""
    keymap = x11_keymap_text(spec, tree_root, display)
    expected = compile_keymap_text(keymap, tree_root) if keymap is not None else None
    if expected is None:
        return WAYLAND_COMPILE_FAILED
    code = WAYLAND_NOT_LOADED
    deadline = time.monotonic() + WAYLAND_READBACK_SECONDS
    while True:
        held = x11_loaded_keymap(display) or ""
        if keymap_layout_group(held, spec.layout) is None:
            code = WAYLAND_NOT_LOADED
        elif keymap_carries_layout(held, expected, spec.layout):
            return WAYLAND_APPLIED
        else:
            code = WAYLAND_STALE_KEYMAP
        if time.monotonic() >= deadline:
            return code
        time.sleep(WAYLAND_READBACK_INTERVAL_SECONDS)


def live_readback_refusal(environ: dict[str, str] | None = None) -> str | None:
    """Why the loaded keymap cannot be read back through XWayland, or ``None``."""
    env = os.environ if environ is None else environ
    if not env.get("DISPLAY", ""):
        return WAYLAND_NO_DISPLAY
    if not (shutil.which("setxkbmap") and shutil.which("xkbcomp")):
        return WAYLAND_TOOL_MISSING
    return None


def select_live_slot(
    slot: str,
    slots: tuple[str, str],
    selection: DesktopSelection,
    tree_root: Path,
    environ: dict[str, str] | None = None,
) -> tuple[bool, str]:
    """Selects ``slot`` through the desktop setting and proves it through XWayland.

    The setting read before (``selection``) is written back whenever the
    selection or its proof fails, so the session keeps the layout it had."""
    refusal = live_readback_refusal(environ)
    if refusal is not None:
        return False, refusal
    display = (os.environ if environ is None else environ)["DISPLAY"]
    select = _gnome_select if selection.desktop == "gnome" else _kde_select
    if not select(slot, slots, selection):
        restore_desktop_selection(selection)
        return False, WAYLAND_SELECT_REFUSED
    code = wait_for_xwayland_keymap(LayoutSpec(slot), tree_root, display)
    if code != WAYLAND_APPLIED:
        restore_desktop_selection(selection)
        return False, code
    return True, WAYLAND_APPLIED


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
            f"        gsettings set {GNOME_SCHEMA} {GNOME_KEY} \"[('xkb', '{spec.gnome_id}')]\"",
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
        "   ℹ️  Votre session gère elle-même sa disposition clavier : elle ne lit ni GNOME ni KDE.",
        f"      Dans {path}, remplacez la disposition actuelle par :",
    ]
    lines.extend(f"        {line}" for line in builder(spec))
    lines.append("      Puis rechargez la configuration du compositeur ou reconnectez-vous.")
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
# Keymap compilation
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class CompileResult:
    """Outcome of one keymap compilation, with everything a bug report needs."""

    command: list[str]
    keymap: str | None
    diagnostics: str
    environment: dict[str, str]

    @property
    def succeeded(self) -> bool:
        return self.keymap is not None

    def command_line(self) -> str:
        return shell_join(self.command, self.environment)


@dataclass(frozen=True)
class XkbcompProbe:
    """What to feed Xorg's ``xkbcomp``, which resolves no RMLVO rules for
    extension packages: explicit components and extra include directories."""

    symbols: str
    types: str
    include_dirs: tuple[Path, ...] = ()


XKBCOMP_KEYMAP_TEMPLATE = """xkb_keymap {{
\txkb_keycodes  {{ include "evdev+aliases(qwerty)" }};
\txkb_types     {{ include "{types}" }};
\txkb_compat    {{ include "complete" }};
\txkb_symbols   {{ include "{symbols}" }};
\txkb_geometry  {{ include "pc(pc105)" }};
}};
"""


def run_compiler(
    command: list[str], environment: dict[str, str] | None = None, timeout: int = 60
) -> CompileResult:
    """Run a keymap compiler, keeping its stderr for the failure report."""
    environment = dict(environment or {})
    try:
        result = subprocess.run(
            command,
            env={**os.environ, **environment} if environment else None,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return CompileResult(command, None, f"{command[0]} : commande introuvable", environment)
    except (OSError, subprocess.TimeoutExpired) as error:
        return CompileResult(command, None, f"{command[0]} : {error}", environment)
    diagnostics = result.stderr or ""
    if result.returncode != 0 or not (result.stdout or "").strip():
        if not diagnostics.strip():
            diagnostics = f"code de sortie {result.returncode}, aucune keymap produite"
        return CompileResult(command, None, diagnostics, environment)
    return CompileResult(command, result.stdout, diagnostics, environment)


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
) -> CompileResult:
    """Compile a keymap with libxkbcommon's own compiler.

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
    environment = dict(XKB_DIAGNOSTIC_ENV)
    if extensions_root is not None:
        environment["XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH"] = str(extensions_root)
        # Keep the versioned path out of the way so the staging tree is authoritative.
        environment["XKB_CONFIG_VERSIONED_EXTENSIONS_PATH"] = ""
    return run_compiler(command, environment)


def compile_with_xkbcomp(xkbcomp: str, probe: XkbcompProbe) -> CompileResult:
    """Compile explicit components through Xorg's compiler.

    libxkbcommon and ``xkbcomp`` parse the tree independently, and only the
    latter is what an Xorg session actually uses. For a clean package the
    probe adds the package directory to the search path, which proves the
    files are valid XKB even where libxkbcommon predates extension
    directories.
    """
    handle, temporary = tempfile.mkstemp(prefix="ergopti-", suffix=".xkb", text=True)
    command = [xkbcomp]
    command += [f"-I{directory}" for directory in probe.include_dirs]
    command += ["-xkb", temporary, "-"]
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(XKBCOMP_KEYMAP_TEMPLATE.format(symbols=probe.symbols, types=probe.types))
        return run_compiler(command)
    finally:
        Path(temporary).unlink(missing_ok=True)


def keymap_has_type(keymap: str, type_name: str) -> bool:
    return keymap_defines_type(keymap, type_name)


def describe_rmlvo(layouts: list[LayoutSpec]) -> str:
    return ",".join(spec.gnome_id for spec in layouts)


def relevant_diagnostics(
    diagnostics: str, needles: tuple[str, ...] = (), limit: int = 12
) -> list[str]:
    """Keep the compiler lines that explain a failure.

    Errors and every mention of ``needles`` (the component under test) are
    kept; the routine chatter both compilers emit for a perfectly good keymap
    is dropped so it cannot bury the cause. When nothing qualifies, the last
    lines are returned as they are.
    """
    kept: list[str] = []
    fallback: list[str] = []
    lowered_needles = tuple(needle.lower() for needle in needles if needle)
    for raw in diagnostics.splitlines():
        line = raw.strip()
        if not line:
            continue
        fallback.append(line)
        lowered = line.lower()
        names_component = any(needle in lowered for needle in lowered_needles)
        if not names_component and any(marker in lowered for marker in _DIAGNOSTIC_NOISE):
            continue
        if names_component or any(signal in lowered for signal in _DIAGNOSTIC_SIGNALS):
            kept.append(line)
    chosen = kept or fallback
    return chosen[-limit:]


def inspect_keymap(
    keymap: str, required_type: str, probe_key: str = PROBE_KEY, group: int = 1
) -> list[str]:
    """Return every reason a compiled keymap would leave the Ergopti layers dead.

    "It compiles" is not enough: a key whose type is unknown falls back to
    ONE_LEVEL without an error, which is exactly the dead Shift key of issue
    #84. The probe key must therefore be bound to the custom type in the
    group that carries Ergopti, and the type must map Ctrl to its own level
    while preserving it, or Ctrl+è would not act as Ctrl+Z.
    """
    problems: list[str] = []
    if not keymap_defines_type(keymap, required_type):
        problems.append(f"le type {required_type} n'est pas défini dans la keymap compilée")
    if keymap_key_block(keymap, probe_key) is None:
        problems.append(
            f"la touche {probe_key} est absente de la keymap : les symboles Ergopti n'ont pas été chargés"
        )
        return problems
    effective = keymap_key_type(keymap, probe_key, group)
    if effective != required_type:
        problems.append(
            f"la touche {probe_key} (è) utilise le type {effective or 'implicite'} au lieu de "
            f"{required_type} : les couches Maj et AltGr resteraient mortes"
        )
    if not problems:
        level = keymap_type_level(keymap, required_type, CONTROL_MODIFIER)
        if level is None:
            problems.append(
                f"le type {required_type} ne définit aucun niveau pour Ctrl : Ctrl+è ne donnerait pas Ctrl+Z"
            )
        elif not keymap_type_preserves(keymap, required_type, CONTROL_MODIFIER):
            problems.append(
                f"le type {required_type} ne conserve pas Ctrl (preserve) : Ctrl+è produirait z sans Ctrl"
            )
    return problems


def describe_probe(
    keymap: str, required_type: str, probe_key: str = PROBE_KEY, group: int = 1
) -> str:
    """Summarise what the probe key does, for the success line and diagnostics."""
    symbols = keymap_key_symbols(keymap, probe_key, group)
    level = keymap_type_level(keymap, required_type, CONTROL_MODIFIER)
    control = ""
    if level is not None:
        keysym = symbols[level - 1] if 0 < level <= len(symbols) else "?"
        control = f", Ctrl → niveau {level} ({keysym})"
    return f"{probe_key} : {len(symbols)} niveaux {symbols}{control}"


def _report_failure(
    label: str, problems: list[str], result: CompileResult, needles: tuple[str, ...]
) -> None:
    print(f"   ❌ {label}")
    for problem in problems:
        print(f"      • {problem}")
    print(f"      Commande : {result.command_line()}")
    for line in relevant_diagnostics(result.diagnostics, needles):
        print(f"      | {line}")


def _verify_with_xkbcli(
    xkbcli: str,
    spec: LayoutSpec,
    required_type: str,
    include_roots: list[Path] | None,
    extensions_root: Path | None,
    probe_key: str,
) -> bool:
    cases = [[spec], [spec, COMPANION_LAYOUT], [COMPANION_LAYOUT, spec]]
    needles = (required_type, spec.layout, spec.variant, "ergopti")
    summary = ""
    for layouts in cases:
        label = describe_rmlvo(layouts)
        group = layouts.index(spec) + 1
        result = compile_rmlvo(xkbcli, layouts, include_roots, extensions_root)
        if not result.succeeded:
            _report_failure(
                f"libxkbcommon : la configuration « {label} » ne compile pas, la disposition "
                "n'est pas visible par libxkbcommon.",
                [],
                result,
                needles,
            )
            return False
        problems = inspect_keymap(result.keymap or "", required_type, probe_key, group)
        if problems:
            _report_failure(
                f"libxkbcommon : « {label} » compile mais la disposition est inutilisable.",
                problems,
                result,
                needles,
            )
            return False
        if not summary:
            summary = describe_probe(result.keymap or "", required_type, probe_key, group)
    print(
        f"   ✅ Keymap vérifiée par libxkbcommon : « {spec.gnome_id} » compile avec {required_type}, "
        f"seule et à côté de « {COMPANION_LAYOUT.gnome_id} » ({summary})."
    )
    return True


def _verify_with_xkbcomp(
    xkbcomp: str, probe: XkbcompProbe, spec: LayoutSpec, required_type: str, probe_key: str
) -> bool:
    needles = (required_type, spec.layout, spec.variant, "ergopti")
    result = compile_with_xkbcomp(xkbcomp, probe)
    if not result.succeeded:
        _report_failure("xkbcomp (Xorg) rejette la disposition.", [], result, needles)
        return False
    problems = inspect_keymap(result.keymap or "", required_type, probe_key, 1)
    if problems:
        _report_failure(
            "xkbcomp (Xorg) compile la disposition mais elle est inutilisable.",
            problems,
            result,
            needles,
        )
        return False
    print(
        f"   ✅ Keymap vérifiée par xkbcomp (Xorg) : « {probe.symbols} » compile avec {required_type} "
        f"({describe_probe(result.keymap or '', required_type, probe_key, 1)})."
    )
    return True


def verify_keymap(
    spec: LayoutSpec,
    required_type: str,
    include_roots: list[Path] | None = None,
    extensions_root: Path | None = None,
    xkbcomp_probe: XkbcompProbe | None = None,
    probe_key: str = PROBE_KEY,
) -> bool | None:
    """Prove the installed layout resolves and delivers the custom type.

    libxkbcommon's compiler resolves the layout exactly as a Wayland
    compositor would, alone and next to a companion layout in both orders,
    because rules that only match single-layout configurations are the
    failure that killed the Shift and AltGr layers for every user who kept a
    second keyboard (issue #84). Xorg's ``xkbcomp`` compiles the explicit
    components when a probe is given: it is what an X11 session uses, and the
    only compiler available on hosts without ``xkbcli``.

    Returns ``False`` when any available compiler rejects the layout or
    produces dead layers, ``None`` when no compiler is installed (unverified,
    with the package to install printed), ``True`` otherwise.
    """
    verdicts: list[bool] = []
    xkbcli = shutil.which("xkbcli")
    if xkbcli:
        verdicts.append(
            _verify_with_xkbcli(
                xkbcli, spec, required_type, include_roots, extensions_root, probe_key
            )
        )
    else:
        print(
            "   ℹ️  xkbcli absent : la résolution de la disposition par libxkbcommon (sessions Wayland) "
            f"ne peut pas être vérifiée. Paquet à installer : {xkbcli_package_hint()}."
        )
    if xkbcomp_probe is not None:
        xkbcomp = shutil.which("xkbcomp")
        if xkbcomp:
            verdicts.append(
                _verify_with_xkbcomp(xkbcomp, xkbcomp_probe, spec, required_type, probe_key)
            )
        else:
            print("   ℹ️  xkbcomp absent : la compilation Xorg n'est pas vérifiée.")
    if False in verdicts:
        return False
    if not verdicts:
        print(
            "   ⚠️  Aucun compilateur XKB disponible (xkbcli, xkbcomp) : la disposition "
            "installée n'a pas pu être vérifiée."
        )
        return None
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

    gnome_status, current_raw = run_capture_status(["gsettings", "get", GNOME_SCHEMA, GNOME_KEY])
    if gnome_status is CommandCaptureStatus.FAILED:
        if _gnome_schema_status() is CommandCaptureStatus.ABSENT:
            gnome_status = CommandCaptureStatus.ABSENT
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
                if (
                    _gnome_set(GNOME_KEY, kept, "GNOME : sources Ergopti retirées")
                    and _gnome_get(GNOME_KEY) == kept
                ):
                    changed = True
                else:
                    failed = True
            mru = _gnome_get(GNOME_MRU_KEY)
            if mru is None:
                failed = True
            elif mru:
                kept_mru = [
                    pair
                    for pair in mru
                    if not (pair[0] == "xkb" and owned(LayoutSpec.parse(pair[1])))
                ]
                if kept_mru != mru:
                    if (
                        _gnome_set(
                            GNOME_MRU_KEY, kept_mru, "GNOME : dispositions récentes nettoyées"
                        )
                        and _gnome_get(GNOME_MRU_KEY) == kept_mru
                    ):
                        changed = True
                    else:
                        failed = True

    reader = _kde_reader()
    if reader is not None:
        layouts_status, layouts_value = _kde_read(reader, KDE_LAYOUTS_KEY)
        if layouts_status is CommandCaptureStatus.FAILED:
            failed = True
        elif layouts_status is CommandCaptureStatus.SUCCEEDED:
            variants_status, variants_value = _kde_read(reader, KDE_VARIANTS_KEY)
            names_status, names_value = _kde_read(reader, KDE_NAMES_KEY)
            if any(
                status is not CommandCaptureStatus.SUCCEEDED
                for status in (variants_status, names_status)
            ):
                return CleanupStatus.FAILED
            current = parse_kde_layouts(layouts_value, variants_value)
            kept, removed = remove_layout_specs(current, owned)
            if removed:
                writer = _kde_writer()
                layout_list, variant_list = format_kde_layouts(kept)
                if (
                    writer
                    and _kde_write(
                        writer, KDE_LAYOUTS_KEY, layout_list, "KDE : dispositions Ergopti retirées"
                    )
                    and _kde_write(writer, KDE_VARIANTS_KEY, variant_list, "KDE : variantes")
                ):
                    names = _kde_display_names(current, names_value, kept)
                    if names is not None:
                        if not _kde_write(writer, KDE_NAMES_KEY, names, "KDE : noms affichés"):
                            failed = True
                    expected = [(KDE_LAYOUTS_KEY, layout_list), (KDE_VARIANTS_KEY, variant_list)]
                    if names is not None:
                        expected.append((KDE_NAMES_KEY, names))
                    confirmed = all(
                        _kde_read(reader, key) == (CommandCaptureStatus.SUCCEEDED, value)
                        for key, value in expected
                    )
                    if confirmed:
                        changed = True
                        _kde_reload()
                    else:
                        failed = True
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
    layout. Returns True when the desktop that owns the setting accepted the
    change. A setting is only written when the session either identifies
    itself as its owner or does not identify itself at all: gsettings and
    kwriteconfig succeed under Sway or Hyprland without those compositors
    ever reading them, and reporting that as success is how a layout stays
    silently inactive.
    """
    if not specs:
        raise ValueError("activate_layout requires at least one layout")
    primary = specs[0]
    env = os.environ if environ is None else environ
    tokens = desktop_tokens(environ)
    kind = session_type(environ)
    owner = owning_desktop(tokens)
    desktop = env.get("XDG_CURRENT_DESKTOP") or "inconnu"
    print(f"🚀 Activation de « {primary.gnome_id} » ({describe_session(environ)})…")
    if running_as_root():
        print(
            "   ⚠️  Activation lancée en root : dconf et D-Bus appartiennent à "
            "votre session utilisateur, l'écriture serait sans effet."
        )
        return False
    gnome_applied = False
    if owner in (None, "gnome"):
        gnome_applied = apply_gnome(specs, tokens)
    else:
        print(f"   ℹ️  Réglage GNOME ignoré : le bureau « {desktop} » ne le lit pas.")
    kde_applied = False
    if owner in (None, "kde"):
        kde_applied = apply_kde(specs, tokens)
    else:
        print(f"   ℹ️  Réglage KDE ignoré : le bureau « {desktop} » ne le lit pas.")
    x11_applied = apply_x11(primary, environ)
    handled = (
        (gnome_applied and owner == "gnome") or (kde_applied and owner == "kde") or x11_applied
    )
    if not handled:
        for line in manual_instructions(primary, tokens, kind):
            print(line)
    if x11_applied and owner not in ("gnome", "kde"):
        for line in persistence_instructions(primary):
            print(line)
    if handled:
        print(
            "   ✅ Disposition activée pour cette session ; elle sera rechargée à la prochaine connexion."
        )
    else:
        print(
            "   ⚠️  Disposition non activée automatiquement : appliquez les instructions ci-dessus."
        )
    print("   ℹ️  Déconnectez-vous/reconnectez-vous si la disposition n'est pas active.")
    return gnome_applied or kde_applied or x11_applied
