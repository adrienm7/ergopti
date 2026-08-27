"""Diagnostic report for an Ergopti XKB installation.

Prints, without privileges and without changing anything, everything a bug
report about a Linux installation needs: the host and its session, the XKB
tooling and library versions, the state of both installation methods on disk,
the desktop settings that select a layout, and a real compilation of every
Ergopti layout found, through the distribution's own search path. It exists
because the failures of issue #84 were invisible from a single command: a
package that compiled but not for the session's configuration, a setting
written into the wrong user's database, a session that never read the setting.

Every section is independent and never aborts the report: a tool that is
missing or fails is itself a finding. Run through ``install.sh --diagnose`` or
directly with ``python3 xkb_diagnose.py``.
"""

from __future__ import annotations

import datetime
import os
import platform
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable

sys.path.insert(0, str(Path(__file__).resolve().parent))

from desktop_activation import (  # noqa: E402
    COMPANION_LAYOUT,
    GNOME_KEY,
    GNOME_MRU_KEY,
    GNOME_SCHEMA,
    KDE_FILE,
    KDE_GROUP,
    KDE_LAYOUTS_KEY,
    KDE_USE_KEY,
    KDE_VARIANTS_KEY,
    XkbcompProbe,
    compositor_hint,
    desktop_tokens,
    describe_rmlvo,
    libxkbcommon_version,
    os_release,
    owning_desktop,
    resolve_user_identity,
    run_cli,
    running_as_root,
    session_type,
    verify_keymap,
    xkbcli_package_hint,
    xkeyboard_config_version,
)
from layout_package import (  # noqa: E402
    DEFAULT_SYSTEM_ROOT,
    ERGOPTI_TYPE_NAME,
    EXIT_OK,
    InstallerRoots,
    LayoutSpec,
    MIN_LIBXKBCOMMON_CLEAN,
    MIN_XKEYBOARDCONFIG_CLEAN,
    PACKAGE_NAME,
    find_stale_bridge_links,
    format_version,
    resolve_roots,
)

REPORT_VERSION = 1
LABEL_WIDTH = 30

# The second, versioned extensions directory libxkbcommon >= 1.13 also reads.
VERSIONED_EXTENSIONS_ROOT = Path("/usr/share/xkeyboard-config-2.d")
VERSIONED_DATA_ROOT = Path("/usr/share/xkeyboard-config-2")

SESSION_VARIABLES = (
    "XDG_SESSION_TYPE",
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "DESKTOP_SESSION",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
)
XKB_VARIABLES = (
    "XKB_DEFAULT_RULES",
    "XKB_DEFAULT_MODEL",
    "XKB_DEFAULT_LAYOUT",
    "XKB_DEFAULT_VARIANT",
    "XKB_DEFAULT_OPTIONS",
    "XKB_CONFIG_ROOT",
    "XKB_CONFIG_EXTRA_PATH",
    "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH",
    "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH",
)
TOOLS = (
    ("xkbcli", ["--version"]),
    ("xkbcomp", ["-version"]),
    ("setxkbmap", ["-version"]),
    ("gsettings", ["--version"]),
    ("kreadconfig6", []),
    ("kreadconfig5", []),
    ("kwriteconfig6", []),
    ("kwriteconfig5", []),
    ("localectl", ["--version"]),
    ("dbus-send", []),
    ("git", ["--version"]),
    ("fzf", ["--version"]),
    ("sudo", []),
    ("doas", []),
)

_LEGACY_SECTION_RE = re.compile(r'xkb_symbols\s+"(Ergopti[^"]*)"')


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------


def section(title: str) -> None:
    print(f"\n=== {title} ===")


def item(label: str, value: object) -> None:
    print(f"{label:<{LABEL_WIDTH}}: {value}")


def guarded(title: str, body: Callable[[], None]) -> None:
    """Run one section; a crash inside it is reported, never propagated."""
    section(title)
    try:
        body()
    except Exception as error:  # noqa: BLE001 - the report must reach its end
        print(f"   ⚠️  section interrompue : {type(error).__name__}: {error}")


def command_output(command: list[str], timeout: int = 15) -> tuple[int | None, str]:
    """Run a read-only command and return (exit code, merged output)."""
    try:
        result = subprocess.run(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except FileNotFoundError:
        return None, "commande introuvable"
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)
    return result.returncode, (result.stdout or "").strip()


def first_line(text: str) -> str:
    return text.strip().splitlines()[0] if text.strip() else ""


def describe_path(path: Path) -> str:
    try:
        if path.is_symlink():
            return f"lien symbolique → {os.path.realpath(path)}"
        if path.is_dir():
            return "répertoire"
        if path.is_file():
            return f"fichier de {path.stat().st_size} octets"
    except OSError as error:
        return f"illisible ({error})"
    return "absent"


def mode_string(path: Path) -> str:
    try:
        return oct(path.stat().st_mode & 0o777)
    except OSError:
        return "?"


def count_mentions(path: Path, needle: str = "ergopti") -> int | None:
    try:
        content = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    return sum(1 for line in content.splitlines() if needle in line.lower())


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------


def report_host() -> None:
    fields = os_release()
    item("Date", datetime.datetime.now().isoformat(timespec="seconds"))
    item("Distribution", fields.get("PRETTY_NAME") or "os-release illisible")
    item("os-release ID / ID_LIKE", f"{fields.get('ID', '?')} / {fields.get('ID_LIKE', '-')}")
    item("Noyau / architecture", f"{platform.release()} / {platform.machine()}")
    item("Python", f"{platform.python_version()} ({sys.executable})")
    item("Shell", os.environ.get("SHELL") or "?")
    home, uid, gid = resolve_user_identity()
    item("Utilisateur", f"uid={uid} gid={gid} home={home} root={'oui' if running_as_root() else 'non'}")
    for name in ("SUDO_USER", "DOAS_USER", "PKEXEC_UID"):
        if os.environ.get(name):
            item(f"  {name}", os.environ[name])
    for candidate in ("/etc/NIXOS", "/run/current-system", "/run/ostree-booted"):
        if Path(candidate).exists():
            item("Système particulier", f"{candidate} présent (NixOS / ostree : /usr non modifiable ?)")


def report_session() -> None:
    for name in SESSION_VARIABLES:
        item(name, os.environ.get(name, "<non défini>"))
    tokens = desktop_tokens()
    kind = session_type()
    owner = owning_desktop(tokens) or "inconnu"
    item("Type de session déduit", kind)
    item("Bureau reconnu", f"{owner} (identifiants : {', '.join(sorted(tokens)) or 'aucun'})")
    hint = compositor_hint(tokens)
    if hint is not None:
        item("Fichier du compositeur", hint[0])
    if kind == "x11":
        item("Méthode visible", "Legacy uniquement : Xorg ignore les répertoires d'extensions XKB")


def report_tools() -> None:
    for name, arguments in TOOLS:
        path = shutil.which(name)
        if not path:
            item(name, "absent")
            continue
        detail = path
        if arguments:
            _, output = command_output([path, *arguments])
            if output:
                detail += f"  ({first_line(output)})"
        item(name, detail)
    if not shutil.which("xkbcli"):
        item("Paquet fournissant xkbcli", xkbcli_package_hint())
    lib = libxkbcommon_version()
    data = xkeyboard_config_version()
    item(
        "libxkbcommon",
        f"{format_version(lib)} (Clean requiert >= {format_version(MIN_LIBXKBCOMMON_CLEAN)})"
        if lib
        else "version indéterminée",
    )
    item(
        "xkeyboard-config",
        f"{format_version(data)} (Clean requiert >= {format_version(MIN_XKEYBOARDCONFIG_CLEAN)})"
        if data
        else "version indéterminée",
    )
    detector = Path(__file__).resolve().parent / "detect_installation_method.sh"
    if detector.is_file() and shutil.which("bash"):
        code, output = command_output(["bash", str(detector)])
        print(f"Détecteur de méthode (code {code}) :")
        for line in output.splitlines():
            print(f"   {line}")


def report_xkb_tree(roots: InstallerRoots) -> None:
    if roots.sandboxed:
        item("Bac à sable", "variables ERGOPTI_XKB_* actives, chemins non standard")
    item(str(roots.system_root), describe_path(roots.system_root))
    if not roots.sandboxed:
        item(str(VERSIONED_DATA_ROOT), describe_path(VERSIONED_DATA_ROOT))
        for extensions_root in (roots.extensions_root, VERSIONED_EXTENSIONS_ROOT):
            report_extensions_root(extensions_root)
    else:
        report_extensions_root(roots.extensions_root)
    package_dir = roots.package_dir
    item(f"Paquet Clean {package_dir}", describe_path(package_dir))
    if package_dir.is_dir():
        for path in sorted(package_dir.rglob("*")):
            if path.is_file():
                relative = path.relative_to(package_dir)
                item(f"  {relative}", f"{path.stat().st_size} octets, mode {mode_string(path)}")
        post = package_dir / "rules" / "evdev.post"
        if post.is_file():
            print("  rules/evdev.post :")
            for line in post.read_text(encoding="utf-8", errors="replace").splitlines():
                print(f"     {line}")
    for name in XKB_VARIABLES:
        if os.environ.get(name):
            item(name, os.environ[name])


def report_extensions_root(extensions_root: Path) -> None:
    item(str(extensions_root), describe_path(extensions_root))
    if extensions_root.is_dir():
        try:
            children = sorted(child.name for child in extensions_root.iterdir())
        except OSError as error:
            children = [f"illisible ({error})"]
        item("  paquets présents", ", ".join(children) or "aucun")


def legacy_variants(system_root: Path) -> list[str]:
    """Return the Ergopti sections registered in ``symbols/fr`` by the legacy method."""
    symbols_fr = system_root / "symbols" / "fr"
    try:
        return _LEGACY_SECTION_RE.findall(symbols_fr.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []


def report_legacy(roots: InstallerRoots) -> None:
    rules = roots.system_root / "rules"
    targets = [
        roots.system_root / "symbols" / "fr",
        roots.system_root / "types" / "extra",
        rules / "evdev",
        rules / "evdev.lst",
        rules / "evdev.xml",
    ]
    for target in targets:
        mentions = count_mentions(target)
        backups = sorted(
            candidate.name
            for candidate in target.parent.glob(f"{target.name}.*")
            if candidate.name[len(target.name) + 1 :].isdigit()
        ) if target.parent.is_dir() else []
        state = "absent" if mentions is None else f"{mentions} ligne(s) mentionnant ergopti"
        item(str(target), f"{state}; sauvegardes : {', '.join(backups) or 'aucune'}")
    variants = legacy_variants(roots.system_root)
    item("Sections Legacy dans symbols/fr", ", ".join(variants) or "aucune")
    stale = find_stale_bridge_links(roots.system_root)
    item("Liens hérités (génération 2)", ", ".join(str(path) for path in stale) or "aucun")


def report_desktop_settings() -> None:
    if shutil.which("gsettings"):
        for key in (GNOME_KEY, GNOME_MRU_KEY):
            code, output = command_output(["gsettings", "get", GNOME_SCHEMA, key])
            item(f"gsettings {key}", output if code == 0 else f"échec (code {code}) : {first_line(output)}")
    else:
        item("gsettings", "absent (pas de bureau GNOME, ou outils non installés)")
    reader = next((name for name in ("kreadconfig6", "kreadconfig5") if shutil.which(name)), None)
    if reader:
        for key in (KDE_LAYOUTS_KEY, KDE_VARIANTS_KEY, KDE_USE_KEY):
            code, output = command_output(
                [reader, "--file", KDE_FILE, "--group", KDE_GROUP, "--key", key]
            )
            item(f"kxkbrc {key}", output if code == 0 else f"échec (code {code})")
    else:
        item("kxkbrc", "kreadconfig absent (pas de KDE Plasma)")
    if shutil.which("localectl"):
        code, output = command_output(["localectl", "status"])
        for line in output.splitlines():
            if "X11" in line or "Keymap" in line:
                item("localectl", line.strip())
    if shutil.which("setxkbmap") and os.environ.get("DISPLAY"):
        code, output = command_output(["setxkbmap", "-query"])
        summary = ", ".join(line.strip() for line in output.splitlines()) if code == 0 else f"échec (code {code})"
        note = " (Xwayland : peut ne pas refléter le compositeur)" if session_type() == "wayland" else ""
        item("setxkbmap -query", summary + note)
    home, _, _ = resolve_user_identity()
    compose = home / ".XCompose"
    item(str(compose), describe_path(compose))
    if compose.is_file():
        for line in compose.read_text(encoding="utf-8", errors="replace").splitlines():
            if "include" in line or "Ergopti" in line:
                item("  ", line.strip())


def report_compilation(roots: InstallerRoots) -> None:
    if not shutil.which("xkbcli") and not shutil.which("xkbcomp"):
        item("Compilation", "impossible : ni xkbcli ni xkbcomp n'est installé")
        return
    include_roots = [roots.system_root] if roots.sandboxed else None
    extensions_root = roots.extensions_root if roots.sandboxed else None
    candidates: list[tuple[str, LayoutSpec, XkbcompProbe]] = []
    if roots.package_dir.is_dir():
        candidates.append(
            (
                "paquet Clean",
                LayoutSpec(PACKAGE_NAME),
                XkbcompProbe(
                    symbols=f"pc+{PACKAGE_NAME}+inet(evdev)",
                    types=f"complete+{PACKAGE_NAME}",
                    include_dirs=(roots.package_dir,),
                ),
            )
        )
    for variant in legacy_variants(roots.system_root):
        candidates.append(
            (
                "installation Legacy",
                LayoutSpec("fr", variant),
                XkbcompProbe(
                    symbols=f"pc+fr({variant})+inet(evdev)",
                    types="complete",
                    include_dirs=(roots.system_root,) if roots.sandboxed else (),
                ),
            )
        )
    if not candidates:
        item("Compilation", "aucune disposition Ergopti installée (ni paquet Clean, ni section Legacy)")
        return
    for label, spec, probe in candidates:
        print(f"{label} « {spec.gnome_id} » :")
        verdict = verify_keymap(
            spec,
            ERGOPTI_TYPE_NAME,
            include_roots=include_roots,
            extensions_root=extensions_root,
            xkbcomp_probe=probe,
        )
        item("  verdict", {True: "utilisable", False: "INUTILISABLE", None: "non vérifiable"}[verdict])
        print(f"  Configurations testées : {describe_rmlvo([spec])}, {describe_rmlvo([spec, COMPANION_LAYOUT])}, {describe_rmlvo([COMPANION_LAYOUT, spec])}")
    if shutil.which("xkbcli"):
        environment = None
        if roots.sandboxed:
            environment = {
                **os.environ,
                "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(roots.extensions_root),
                "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH": "",
            }
        try:
            result = subprocess.run(
                ["xkbcli", "list"],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=30,
                check=False,
                env=environment,
            )
            listing = result.stdout or ""
        except (OSError, subprocess.TimeoutExpired) as error:
            listing = f"xkbcli list : {error}"
        matches = [line.strip() for line in listing.splitlines() if "ergopti" in line.lower()]
        item("Registre (xkbcli list)", "; ".join(matches) or "aucune entrée Ergopti")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main(argv: list[str]) -> int:
    if any(argument in ("-h", "--help") for argument in argv):
        print("Usage : python3 xkb_diagnose.py\nAffiche un rapport de diagnostic de l'installation Ergopti XKB.")
        return EXIT_OK
    roots = resolve_roots()
    print(f"===== Diagnostic Ergopti XKB (format {REPORT_VERSION}) =====")
    print("Copiez l'intégralité de ce rapport dans le rapport de bug.")
    guarded("Système", report_host)
    guarded("Session graphique", report_session)
    guarded("Outils et versions", report_tools)
    guarded("Arborescence XKB", lambda: report_xkb_tree(roots))
    guarded("Méthode Legacy (fichiers système)", lambda: report_legacy(roots))
    guarded("Réglages de bureau", report_desktop_settings)
    guarded("Compilation des dispositions installées", lambda: report_compilation(roots))
    print("\n===== Fin du diagnostic =====")
    if roots.system_root != DEFAULT_SYSTEM_ROOT and not roots.sandboxed:
        item("Note", "racine XKB non standard")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(run_cli(main, sys.argv[1:]))
