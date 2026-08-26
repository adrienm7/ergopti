"""Clean-method installer for the Ergopti XKB layout.

Implements the libxkbcommon >= 1.13 "XKB extensions directories" contract:

    <extensions root>/<package>/
    ├── symbols/<layout id>
    ├── types/<layout id>
    └── rules/evdev.xml + rules/evdev.post

Nothing outside that directory is modified: the custom types reach the keymap
through the composable ``rules/evdev.post`` fragment instead of patching the
system ``rules/evdev`` file, and the legacy X11 tree is only touched when the
user explicitly asks for X11 (non-Xwayland) session support.

Hardening rules enforced here:

- the types file is mandatory and validated against the symbols references
  before anything is installed (issue #84 class: an undefined key type kills
  the whole keymap, e.g. a dead Shift layer);
- the installation is staged then moved into place, so a failure never leaves
  a half-installed package behind;
- every best-effort activation step reports its outcome instead of swallowing
  errors silently;
- ``--uninstall`` removes exactly what was installed.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from enum import Enum
from pathlib import Path

XCOMPOSE_OWNER_MARKER = "# Ergopti managed XCompose"
XCOMPOSE_MANAGED_NAME = "ergopti.XCompose"
ENV_USER_HOME = "ERGOPTI_XKB_USER_HOME"


class CleanupStatus(Enum):
    ABSENT = "absent"
    CHANGED = "changed"
    FAILED = "failed"


class CommandCaptureStatus(Enum):
    ABSENT = "absent"
    SUCCEEDED = "succeeded"
    FAILED = "failed"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from layout_package import (  # noqa: E402
    EXIT_INSTALL_ABORTED,
    EXIT_OK,
    EXIT_VALIDATION,
    InstallerRoots,
    PACKAGE_NAME,
    SUPPORTED_VARIANTS,
    VARIANT_PLUS,
    VARIANT_STANDARD,
    build_evdev_post,
    build_registry_xml,
    format_gsettings_sources,
    merge_gsettings_source,
    merge_kde_layout_list,
    parse_gsettings_sources,
    parse_kde_layout_list,
    patch_symbols_default,
    remove_generation_two_links,
    resolve_roots,
    strip_legacy_evdev_patch,
    validate_component_identifier,
    validate_layout_files,
)


def check_root(roots: InstallerRoots) -> None:
    """Refuse to run as non-root outside of a sandbox."""
    if roots.sandboxed:
        return
    if hasattr(os, "geteuid") and os.geteuid() != 0:
        raise SystemExit(
            "Erreur : ce script doit être lancé avec sudo "
            "(ou avec les variables ERGOPTI_XKB_* pour un bac à sable)."
        )


def read_text(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except OSError as error:
        raise SystemExit(f"Erreur : lecture impossible de {path} ({error}).")


def run_reported(command: list[str], label: str, env: dict[str, str] | None = None) -> bool:
    """Run a best-effort command and report its outcome; never raise."""
    effective_env = os.environ.copy()
    if env:
        effective_env.update(env)
    try:
        result = subprocess.run(
            command,
            env=effective_env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"   ⚠️  {label} : impossible de lancer la commande ({error}).")
        return False
    if result.returncode == 0:
        print(f"   ✅ {label}.")
        return True
    output = (result.stdout or "").strip()
    detail = f" — {output.splitlines()[0]}" if output else ""
    print(f"   ⚠️  {label} : échec (code {result.returncode}){detail}.")
    return False


def compile_validation(extensions_root: Path, layout_id: str) -> bool:
    """Compile-test the staged package with xkbcli when it is available.

    Returns True when validation ran and succeeded. A missing or too-old
    xkbcli is not fatal: the structural validator already guarantees symbol/
    types coherence, and CI exercises both paths.
    """
    xkbcli = shutil.which("xkbcli")
    if not xkbcli:
        print("   ℹ️  xkbcli absent : compilation réelle ignorée (validation structurelle OK).")
        return True
    env = {
        "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(extensions_root),
        # Keep the versioned path out of the way so the staging tree is authoritative.
        "XKB_CONFIG_VERSIONED_EXTENSIONS_PATH": "",
    }
    command = [
        xkbcli,
        "compile-keymap",
        "--rules",
        "evdev",
        "--model",
        "pc105",
        "--layout",
        layout_id,
        "--test",
    ]
    print(f"   🔎 Compilation de contrôle via xkbcli (layout {layout_id})…")
    try:
        result = subprocess.run(
            command,
            env={**os.environ, **env},
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print(f"   ⚠️  Validation xkbcli impossible ({error}); installation poursuivie.")
        return True
    if result.returncode == 0:
        print("   ✅ La keymap compile (types inclus).")
        return True
    output = (result.stdout or "").strip()
    print("   ❌ La keymap ne compile pas ; installation annulée.")
    for line in output.splitlines()[:20]:
        print(f"      {line}")
    return False


def cleanup_previous_installations(roots: InstallerRoots) -> None:
    """Neutralise artefacts left by earlier installer generations.

    Idempotent: running an upgrade over any previous version or method ends in
    exactly one coherent package state.
    """
    removed_links = remove_generation_two_links(roots.system_root)
    if removed_links:
        print(f"   🧹 {removed_links} lien(s) hérité(s) supprimé(s) dans {roots.system_root}.")
    stripped_lines = strip_legacy_evdev_patch(roots.system_root)
    if stripped_lines:
        print(
            f"   🧹 {stripped_lines} ligne(s) de règles héritée(s) retirée(s) "
            f"de {roots.system_root / 'rules' / 'evdev'}."
        )


def recover_interrupted_package_swap(package_dir: Path) -> None:
    """Restore the last known-good package after an interrupted rename pair."""
    rollback_dir = package_dir.with_name(f".{PACKAGE_NAME}.rollback")
    if not rollback_dir.exists():
        return
    if package_dir.exists():
        shutil.rmtree(rollback_dir)
        return
    rollback_dir.rename(package_dir)


def commit_staged_package(staged_package: Path, package_dir: Path) -> None:
    """Atomically replace a package, restoring the previous one on failure."""
    rollback_dir = package_dir.with_name(f".{PACKAGE_NAME}.rollback")
    recover_interrupted_package_swap(package_dir)
    if rollback_dir.exists():
        shutil.rmtree(rollback_dir)
    had_previous = package_dir.exists()
    if had_previous:
        package_dir.rename(rollback_dir)
    try:
        staged_package.rename(package_dir)
    except BaseException:
        if package_dir.exists():
            shutil.rmtree(package_dir, ignore_errors=True)
        if had_previous and rollback_dir.exists():
            rollback_dir.rename(package_dir)
        raise
    if rollback_dir.exists():
        shutil.rmtree(rollback_dir)


def install_clean(
    symbols_path: Path,
    types_path: Path,
    xcompose_path: Path | None,
    variant: str,
    support_x11: bool,
    roots: InstallerRoots,
    activate_desktop: bool = True,
) -> None:
    """Install the layout package through the extensions-directory contract."""
    if variant not in SUPPORTED_VARIANTS:
        raise SystemExit(
            "Erreur : variante non prise en charge. Choisissez 'ergopti' ou 'ergopti_plus'."
        )
    symbols_content = read_text(symbols_path)
    types_content = read_text(types_path)

    print("🔎 Validation structurelle du paquet (symbols ↔ types)…")
    problems = validate_layout_files(symbols_content, types_content)
    if problems:
        for problem in problems:
            print(f"   ❌ {problem}")
        print("Erreur : le paquet de disposition est incohérent ; installation annulée.")
        raise SystemExit(EXIT_VALIDATION)
    print("   ✅ Chaque type référencé par les symboles est bien défini.")

    layout_id = validate_component_identifier(PACKAGE_NAME)
    patched_symbols = patch_symbols_default(symbols_content)

    package_dir = roots.package_dir
    package_dir.parent.mkdir(parents=True, exist_ok=True)
    recover_interrupted_package_swap(package_dir)
    with tempfile.TemporaryDirectory(
        prefix=f".{PACKAGE_NAME}.staging-", dir=package_dir.parent.parent
    ) as staging_name:
        staging_root = Path(staging_name)
        staged_package = staging_root / PACKAGE_NAME
        (staged_package / "symbols").mkdir(parents=True)
        (staged_package / "types").mkdir()
        (staged_package / "rules").mkdir()

        (staged_package / "symbols" / layout_id).write_text(
            patched_symbols, encoding="utf-8"
        )
        (staged_package / "types" / layout_id).write_text(
            types_content, encoding="utf-8"
        )
        description = "Français — Ergopti"
        if variant == VARIANT_PLUS:
            description = "Français — Ergopti+"
        (staged_package / "rules" / "evdev.xml").write_text(
            build_registry_xml(layout_id, description, []),
            encoding="utf-8",
        )
        (staged_package / "rules" / "evdev.post").write_text(
            build_evdev_post(layout_id),
            encoding="utf-8",
        )
        if xcompose_path is not None:
            (staged_package / "compose").mkdir()
            shutil.copy2(
                xcompose_path,
                staged_package / "compose" / XCOMPOSE_MANAGED_NAME,
            )

        if not compile_validation(staging_root, layout_id):
            raise SystemExit(EXIT_VALIDATION)

        commit_staged_package(staged_package, package_dir)

    print("🧼 Nettoyage des installations précédentes…")
    cleanup_previous_installations(roots)
    print(f"📦 Paquet installé dans {package_dir}.")

    managed_xcompose = package_dir / "compose" / XCOMPOSE_MANAGED_NAME
    if managed_xcompose.is_file():
        install_user_xcompose(managed_xcompose)
    else:
        remove_user_xcompose_include()

    if support_x11:
        create_legacy_symlinks(package_dir, layout_id, roots.system_root)

    purge_cache(roots)
    if activate_desktop:
        activate(layout_id, variant)


def resolve_user_identity() -> tuple[Path, int | None, int | None]:
    """Return the invoking user's home and ownership, even while under sudo."""
    sandbox_home = os.environ.get(ENV_USER_HOME)
    if sandbox_home:
        return Path(sandbox_home), None, None
    sudo_user = os.environ.get("SUDO_USER", "")
    if sudo_user:
        try:
            import pwd

            user = pwd.getpwnam(sudo_user)
            return Path(user.pw_dir), user.pw_uid, user.pw_gid
        except (ImportError, KeyError):
            pass
    uid_fn = getattr(os, "getuid", None)
    gid_fn = getattr(os, "getgid", None)
    uid = uid_fn() if callable(uid_fn) else None
    gid = gid_fn() if callable(gid_fn) else None
    return Path.home(), uid, gid


def write_user_text(
    destination: Path,
    content: str,
    uid: int | None,
    gid: int | None,
) -> None:
    """Atomically replace a user file without following a crafted temp symlink."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    previous_mode = (
        stat.S_IMODE(destination.stat().st_mode) if destination.exists() else 0o600
    )
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{destination.name}.ergopti-",
        dir=destination.parent,
        text=True,
    )
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        temporary.chmod(previous_mode)
        chown = getattr(os, "chown", None)
        if callable(chown) and uid is not None and gid is not None:
            chown(temporary, uid, gid)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def compose_include_line(source: Path) -> str:
    escaped = str(source).replace("\\", "\\\\").replace('"', '\\"')
    return f'include "{escaped}"'


def strip_owned_xcompose_block(content: str) -> tuple[list[str], bool]:
    """Remove the exact marker and its following include, never adjacent user data."""
    lines = content.splitlines()
    kept: list[str] = []
    removed = False
    index = 0
    while index < len(lines):
        if lines[index].strip() != XCOMPOSE_OWNER_MARKER:
            kept.append(lines[index])
            index += 1
            continue
        removed = True
        index += 1
        if index < len(lines) and lines[index].lstrip().startswith('include "'):
            index += 1
    return kept, removed


def install_user_xcompose(source: Path, home: Path | None = None) -> bool:
    """Append one owned include while preserving the user's Compose rules."""
    resolved_home, uid, gid = resolve_user_identity()
    if home is not None:
        resolved_home, uid, gid = home, None, None
    destination = resolved_home / ".XCompose"
    try:
        existing = destination.read_text(encoding="utf-8") if destination.exists() else ""
        kept, _ = strip_owned_xcompose_block(existing)
        include_line = compose_include_line(source)
        content = "\n".join(kept)
        if content and not content.endswith("\n"):
            content += "\n"
        content += f"{XCOMPOSE_OWNER_MARKER}\n{include_line}\n"
        if destination.exists() and destination.read_text(encoding="utf-8") == content:
            print("   ℹ️  Inclusion ~/.XCompose déjà en place.")
            return False
        write_user_text(destination, content, uid, gid)
        print("   ✅ Inclusion Ergopti ajoutée à ~/.XCompose.")
        return True
    except OSError as error:
        print(f"   ⚠️  Inclusion .XCompose non installée : {error}")
        return False


def remove_user_xcompose_include(home: Path | None = None) -> CleanupStatus:
    """Remove only the line owned by Ergopti, preserving all external edits."""
    resolved_home, uid, gid = resolve_user_identity()
    if home is not None:
        resolved_home, uid, gid = home, None, None
    destination = resolved_home / ".XCompose"
    if not destination.exists():
        return CleanupStatus.ABSENT
    try:
        existing = destination.read_text(encoding="utf-8")
        kept, removed = strip_owned_xcompose_block(existing)
        if not removed:
            return CleanupStatus.ABSENT
        content = "\n".join(kept)
        if content.strip():
            write_user_text(destination, content + "\n", uid, gid)
        else:
            destination.unlink()
        print("   🗑️  Inclusion Ergopti retirée de ~/.XCompose.")
        return CleanupStatus.CHANGED
    except OSError as error:
        print(f"   ⚠️  Inclusion .XCompose non retirée : {error}")
        return CleanupStatus.FAILED


def create_legacy_symlinks(package_dir: Path, layout_id: str, system_root: Path) -> None:
    """Bridge into the legacy tree so real X11 sessions can load the layout."""
    created = 0
    for component in ("symbols", "types"):
        target = system_root / component / layout_id
        source = package_dir / component / layout_id
        try:
            if target.exists() or target.is_symlink():
                target.unlink()
            target.symlink_to(source)
            created += 1
        except OSError as error:
            print(f"   ⚠️  Lien X11 {component} non créé : {error}")
    print(
        f"   🔗 Support X11 (Xorg) : {created}/2 liens créés dans {system_root}."
        if created
        else "   ⚠️  Aucun lien X11 créé."
    )


def purge_cache(roots: InstallerRoots) -> None:
    cache = roots.cache_dir
    if not cache.exists():
        return
    for child in cache.iterdir():
        try:
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child)
            else:
                child.unlink()
        except OSError as error:
            print(f"   ⚠️  Cache XKB : élément non supprimé {child.name} ({error})")
    print("   🧹 Cache XKB purgé.")


def activate(layout_id: str, variant: str) -> None:
    """Best-effort desktop activation that never drops existing layouts.

    GNOME and KDE store the user's layout list; the previous installer
    overwrote it, silently removing the user's other keyboards. The merge
    helpers below append our layouts only when missing.
    """
    def run_capture(command: list[str]) -> str | None:
        try:
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=15,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        return result.stdout if result.returncode == 0 else None

    def run_report(command: list[str], label: str) -> bool:
        return run_reported(command, label)

    wanted = [("xkb", layout_id)]
    print("🚀 Activation (best-effort, sans écraser vos dispositions)…")

    # --- GNOME / Wayland (mutter) ---
    current_raw = run_capture(["gsettings", "get", "org.gnome.desktop.input-sources", "sources"])
    if current_raw is None:
        print("   ℹ️  gsettings indisponible : GNOME non détecté, étape ignorée.")
    else:
        current_sources = parse_gsettings_sources(current_raw)
        if current_sources is None:
            print("   ℹ️  gsettings indisponible : GNOME non détecté, étape ignorée.")
        else:
            merged, added = merge_gsettings_source(current_sources, wanted)
            if added:
                run_report(
                    [
                        "gsettings",
                        "set",
                        "org.gnome.desktop.input-sources",
                        "sources",
                        format_gsettings_sources(merged),
                    ],
                    "GNOME : disposition ajoutée à vos sources existantes",
                )
            else:
                print("   ✅ GNOME : déjà présente dans vos sources, rien à changer.")

    # --- KDE Plasma ---
    kde_readers = ["kreadconfig6", "kreadconfig5"]
    current_list = None
    for reader in kde_readers:
        current_list = run_capture(
            [reader, "--file", "kxkbrc", "--group", "Layout", "--key", "LayoutList"]
        )
        if current_list is not None:
            break
    kde_ids = [layout_id]
    if current_list is None:
        print("   ℹ️  kreadconfig indisponible : KDE non détecté, étape ignorée.")
    else:
        merged_kde, added_kde = merge_kde_layout_list(
            parse_kde_layout_list(current_list), kde_ids
        )
        if added_kde:
            writer = (
                "kwriteconfig6"
                if shutil.which("kwriteconfig6")
                else "kwriteconfig5"
            )
            run_report(
                [
                    writer,
                    "--file",
                    "kxkbrc",
                    "--group",
                    "Layout",
                    "--key",
                    "LayoutList",
                    ",".join(merged_kde),
                ],
                "KDE : disposition ajoutée à votre liste",
            )
        else:
            print("   ✅ KDE : déjà présente dans votre liste, rien à changer.")
        run_report(
            ["qdbus", "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"],
            "KDE : reconfiguration de KWin",
        )

    print("   ℹ️  Déconnectez-vous/reconnectez-vous si la disposition n'est pas active.")


def deactivate(layout_id: str) -> CleanupStatus:
    """Remove only Ergopti desktop entries and preserve every other source."""
    sudo_user = os.environ.get("SUDO_USER")
    prefix = ["sudo", "-u", sudo_user] if sudo_user else []
    owned_ids = {layout_id, f"{layout_id}+plus"}
    changed = False
    failed = False

    def run_capture(command: list[str]) -> tuple[CommandCaptureStatus, str]:
        try:
            result = subprocess.run(
                prefix + command,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=15,
                check=False,
            )
        except FileNotFoundError:
            return CommandCaptureStatus.ABSENT, ""
        except (subprocess.TimeoutExpired, OSError):
            return CommandCaptureStatus.FAILED, ""
        if result.returncode != 0:
            return CommandCaptureStatus.FAILED, ""
        return CommandCaptureStatus.SUCCEEDED, result.stdout

    gnome_status, current_raw = run_capture(
        ["gsettings", "get", "org.gnome.desktop.input-sources", "sources"]
    )
    if gnome_status is CommandCaptureStatus.FAILED:
        failed = True
    elif gnome_status is CommandCaptureStatus.SUCCEEDED:
        current_sources = parse_gsettings_sources(current_raw)
        if current_sources is None:
            failed = True
        else:
            kept_sources = [
                pair
                for pair in current_sources
                if not (pair[0] == "xkb" and pair[1] in owned_ids)
            ]
            if kept_sources != current_sources:
                if run_reported(
                    prefix
                    + [
                        "gsettings",
                        "set",
                        "org.gnome.desktop.input-sources",
                        "sources",
                        format_gsettings_sources(kept_sources),
                    ],
                    "GNOME : sources Ergopti retirées",
                ):
                    changed = True
                else:
                    failed = True

    kde_status = CommandCaptureStatus.ABSENT
    current_list = ""
    for reader in ("kreadconfig6", "kreadconfig5"):
        read_status, read_output = run_capture(
            [reader, "--file", "kxkbrc", "--group", "Layout", "--key", "LayoutList"]
        )
        if read_status is CommandCaptureStatus.ABSENT:
            continue
        kde_status = read_status
        current_list = read_output
        break
    if kde_status is CommandCaptureStatus.FAILED:
        failed = True
    elif kde_status is CommandCaptureStatus.SUCCEEDED:
        current_ids = parse_kde_layout_list(current_list)
        kept_ids = [entry for entry in current_ids if entry not in owned_ids]
        if kept_ids != current_ids:
            writer = "kwriteconfig6" if shutil.which("kwriteconfig6") else "kwriteconfig5"
            if run_reported(
                prefix
                + [
                    writer,
                    "--file",
                    "kxkbrc",
                    "--group",
                    "Layout",
                    "--key",
                    "LayoutList",
                    ",".join(kept_ids),
                ],
                "KDE : dispositions Ergopti retirées",
            ):
                changed = True
                if not run_reported(
                    prefix
                    + ["qdbus", "org.kde.KWin", "/KWin", "org.kde.KWin.reconfigure"],
                    "KDE : reconfiguration de KWin",
                ):
                    failed = True
            else:
                failed = True
    if failed:
        return CleanupStatus.FAILED
    return CleanupStatus.CHANGED if changed else CleanupStatus.ABSENT


def uninstall_clean(roots: InstallerRoots) -> bool:
    package_dir = roots.package_dir
    compose_status = remove_user_xcompose_include()
    desktop_status = deactivate(PACKAGE_NAME)
    if CleanupStatus.FAILED in (compose_status, desktop_status):
        print(
            "❌ Désinstallation interrompue : une référence utilisateur Ergopti "
            "n'a pas pu être retirée. Le paquet est conservé."
        )
        return False
    removed = CleanupStatus.CHANGED in (compose_status, desktop_status)
    if package_dir.exists():
        shutil.rmtree(package_dir)
        print(f"🗑️  {package_dir} supprimé.")
        removed = True
    legacy_links = [
        roots.system_root / "symbols" / PACKAGE_NAME,
        roots.system_root / "types" / PACKAGE_NAME,
    ]
    for link in legacy_links:
        if link.is_symlink():
            link.unlink()
            print(f"🗑️  Lien hérité supprimé : {link}")
            removed = True
    stripped = strip_legacy_evdev_patch(roots.system_root)
    if stripped:
        print(
            f"🗑️  {stripped} ligne(s) de règles héritée(s) retirée(s) du fichier evdev système."
        )
        removed = True
    stale_links = remove_generation_two_links(roots.system_root)
    if stale_links:
        print(f"🗑️  {stale_links} lien(s) d'anciennes générations supprimé(s).")
        removed = True
    if not removed:
        print("ℹ️  Rien à désinstaller.")
    return removed


def force_utf8_stdio() -> None:
    """Keep the CLI alive on consoles that cannot encode every glyph.

    The installer prints progress glyphs; on a cp1252 terminal (or any host
    with a legacy ANSI code page) the default print encoding raises
    UnicodeEncodeError mid-install. Reconfigure both streams to UTF-8 with
    replacement characters so output degrades instead of crashing.
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is None:
            continue
        try:
            reconfigure(encoding="utf-8", errors="replace")
        except (OSError, ValueError):
            continue


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Installeur Ergopti (méthode clean)")
    parser.add_argument("--xkb", type=Path, help="Fichier .xkb de la disposition")
    parser.add_argument(
        "--types", type=Path, help="Fichier de types complet (obligatoire sauf --uninstall)"
    )
    parser.add_argument("--xcompose", type=Path, default=None, help="Fichier .XCompose optionnel")
    parser.add_argument(
        "--variant",
        choices=list(SUPPORTED_VARIANTS),
        default=VARIANT_STANDARD,
        help="Variante installée",
    )
    parser.add_argument(
        "--support-x11",
        action="store_true",
        help="Créer aussi les liens pour les sessions X11 (Xorg) réelles",
    )
    parser.add_argument(
        "--skip-activation",
        action="store_true",
        help="Installer le paquet sans toucher à la session de bureau.",
    )
    parser.add_argument(
        "--activate-only",
        action="store_true",
        help="Activer le paquet déjà installé dans la session de bureau courante.",
    )
    parser.add_argument("--uninstall", action="store_true", help="Désinstaller le paquet")
    args = parser.parse_args(argv)
    if args.activate_only and (args.uninstall or args.skip_activation):
        parser.error("--activate-only est incompatible avec --uninstall et --skip-activation")
    if not args.uninstall and not args.activate_only:
        missing = [name for name in ("--xkb", "--types") if getattr(args, name.lstrip("-")) is None]
        if missing:
            parser.error("les options suivantes sont requises : " + ", ".join(missing))
    return args


def main(argv: list[str]) -> int:
    force_utf8_stdio()
    args = parse_args(argv)
    roots = resolve_roots()
    if args.activate_only:
        activate(PACKAGE_NAME, args.variant)
        return EXIT_OK
    check_root(roots)
    if args.uninstall:
        return EXIT_OK if uninstall_clean(roots) else EXIT_INSTALL_ABORTED
    try:
        install_clean(
            symbols_path=args.xkb,
            types_path=args.types,
            xcompose_path=args.xcompose,
            variant=args.variant,
            support_x11=args.support_x11,
            roots=roots,
            activate_desktop=not args.skip_activation,
        )
    except SystemExit as error:
        # install_clean already printed a diagnostic; map its aborts to the
        # documented exit codes so scripts can branch on them.
        code = error.code
        return code if isinstance(code, int) else EXIT_INSTALL_ABORTED
    print("\n✨ Installation terminée. Redémarrez la session pour tout prendre en compte.")
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
