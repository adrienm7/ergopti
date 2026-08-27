"""Clean-method installer for the Ergopti XKB layout.

Implements the libxkbcommon >= 1.13 "XKB extensions directories" contract:

    <extensions root>/<package>/
    ├── symbols/<layout id>
    ├── types/<layout id>
    └── rules/evdev.xml + rules/evdev.post

Nothing outside that directory is modified: the custom types reach the keymap
through the composable ``rules/evdev.post`` fragment instead of patching the
system ``rules/evdev`` file. Only libxkbcommon reads that directory, so this
method serves Wayland sessions; Xorg compiles keymaps with its own ``xkbcomp``
from the legacy tree and needs the legacy installer.

Hardening rules enforced here:

- the types file is mandatory and validated against the symbols references
  before anything is installed (issue #84 class: an undefined key type kills
  the whole keymap, e.g. a dead Shift layer);
- the installation is staged then moved into place, so a failure never leaves
  a half-installed package behind;
- the staged package is compiled with libxkbcommon, alone and next to another
  layout, and must carry the custom type in every case before it is committed;
- every best-effort activation step reports its outcome instead of swallowing
  errors silently;
- ``--uninstall`` removes exactly what was installed.
"""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import sys
import tempfile
from pathlib import Path

XCOMPOSE_OWNER_MARKER = "# Ergopti managed XCompose"
XCOMPOSE_MANAGED_NAME = "ergopti.XCompose"

sys.path.insert(0, str(Path(__file__).resolve().parent))

from desktop_activation import (  # noqa: E402
    CleanupStatus,
    ENV_USER_HOME,
    activate_layout,
    deactivate_layouts,
    rerun_unprivileged,
    resolve_user_identity,
    running_as_root,
    verify_keymap,
)
from layout_package import (  # noqa: E402
    ERGOPTI_TYPE_NAME,
    EXIT_INSTALL_ABORTED,
    EXIT_OK,
    EXIT_VALIDATION,
    InstallerRoots,
    LayoutSpec,
    PACKAGE_NAME,
    SUPPORTED_VARIANTS,
    VARIANT_PLUS,
    VARIANT_STANDARD,
    build_evdev_post,
    build_registry_xml,
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


def compile_validation(extensions_root: Path, layout_id: str) -> bool:
    """Compile-test the staged package with libxkbcommon when it is available.

    The keymap must carry the custom type alone *and* next to another layout:
    rules that only match single-layout configurations compile fine and leave
    the Shift and AltGr layers dead for every user who keeps a second keyboard.
    A missing xkbcli is not fatal: the structural validator already guarantees
    symbol/types coherence, and CI exercises the real compiler.
    """
    print(f"   🔎 Compilation de contrôle via xkbcli (layout {layout_id})…")
    verdict = verify_keymap(
        LayoutSpec(layout_id), ERGOPTI_TYPE_NAME, extensions_root=extensions_root
    )
    if verdict is None:
        print("   ℹ️  xkbcli absent : compilation réelle ignorée (validation structurelle OK).")
        return True
    if not verdict:
        print("   ❌ Le paquet ne fournit pas ses couches ; installation annulée.")
    return verdict


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

    purge_cache(roots)
    if activate_desktop:
        activate(layout_id, variant)


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


def activate(layout_id: str, variant: str) -> bool:
    """Activate the freshly installed package in the user's desktop session.

    The whole desktop-facing logic lives in ``desktop_activation`` so the
    legacy installer applies exactly the same rules; ``variant`` is accepted for
    call-site symmetry because both variants ship under the same layout id.
    """
    del variant
    return activate_layout([LayoutSpec(layout_id)])


def deactivate_desktop_entries() -> CleanupStatus:
    """Remove the desktop entries, dropping privileges when run as root.

    dconf and the Plasma configuration belong to the user's session; reading
    them as root returns root's empty settings and would report "nothing to
    remove" while the user's list still carries the layout.
    """
    if running_as_root():
        code = rerun_unprivileged(
            [sys.executable or "python3", str(Path(__file__).resolve()), "--deactivate-only"]
        )
        if code is None:
            print(
                "   ⚠️  Retrait de la session impossible en root : relancez "
                "sans sudo avec --deactivate-only si la disposition reste listée."
            )
            return CleanupStatus.ABSENT
        return CleanupStatus.ABSENT if code == 0 else CleanupStatus.FAILED
    return deactivate_layouts()


def uninstall_clean(roots: InstallerRoots, deactivate_desktop: bool = True) -> bool:
    """Remove the package; the desktop half is skipped when it runs elsewhere.

    ``deactivate_desktop`` is False when the entry point already ran
    ``--deactivate-only`` in the user's session, which is the only place where
    dconf and Plasma are reachable.
    """
    package_dir = roots.package_dir
    compose_status = remove_user_xcompose_include()
    desktop_status = deactivate_desktop_entries() if deactivate_desktop else CleanupStatus.ABSENT
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
        "--skip-activation",
        action="store_true",
        help="Installer le paquet sans toucher à la session de bureau.",
    )
    parser.add_argument(
        "--activate-only",
        action="store_true",
        help="Activer le paquet déjà installé dans la session de bureau courante.",
    )
    parser.add_argument(
        "--deactivate-only",
        action="store_true",
        help="Retirer la disposition de la session de bureau, sans toucher aux fichiers.",
    )
    parser.add_argument("--uninstall", action="store_true", help="Désinstaller le paquet")
    args = parser.parse_args(argv)
    if args.activate_only and args.deactivate_only:
        parser.error("--activate-only est incompatible avec --deactivate-only")
    if args.activate_only and (args.uninstall or args.skip_activation):
        parser.error("--activate-only est incompatible avec --uninstall et --skip-activation")
    if args.deactivate_only and args.uninstall:
        parser.error("--deactivate-only est incompatible avec --uninstall")
    if not args.uninstall and not args.activate_only and not args.deactivate_only:
        missing = [name for name in ("--xkb", "--types") if getattr(args, name.lstrip("-")) is None]
        if missing:
            parser.error("les options suivantes sont requises : " + ", ".join(missing))
    return args


def run_activation_phase(variant: str, roots: InstallerRoots) -> int:
    """Run the unprivileged half of the installation.

    The package is already on disk at this point. Two things still have to
    happen, and neither may run as root: proving the layout is visible to
    libxkbcommon, and telling the desktop session to use it.
    """
    if running_as_root():
        argv = [
            sys.executable or "python3",
            str(Path(__file__).resolve()),
            "--activate-only",
            "--variant",
            variant,
        ]
        code = rerun_unprivileged(argv)
        if code is not None:
            return EXIT_OK if code == 0 else EXIT_INSTALL_ABORTED
        print(
            "   ❌ Activation impossible en root et aucun utilisateur de bureau "
            "identifié. Relancez sans sudo :"
        )
        print(f"      python3 {Path(__file__).resolve()} --activate-only --variant {variant}")
        return EXIT_INSTALL_ABORTED
    print("🔎 Vérification du paquet installé…")
    verify_keymap(
        LayoutSpec(PACKAGE_NAME),
        ERGOPTI_TYPE_NAME,
        extensions_root=roots.extensions_root if roots.sandboxed else None,
    )
    activate(PACKAGE_NAME, variant)
    return EXIT_OK


def run_deactivation_phase() -> int:
    """Remove the desktop entries from the user's session before file removal."""
    if running_as_root():
        argv = [
            sys.executable or "python3",
            str(Path(__file__).resolve()),
            "--deactivate-only",
        ]
        code = rerun_unprivileged(argv)
        if code is not None:
            return EXIT_OK if code == 0 else EXIT_INSTALL_ABORTED
        print(
            "   ⚠️  Retrait de la session impossible en root : relancez "
            "sans sudo si la disposition reste listée."
        )
        return EXIT_OK
    status = deactivate_layouts()
    if status is CleanupStatus.FAILED:
        print("   ❌ Les entrées de bureau Ergopti n'ont pas pu être retirées.")
        return EXIT_INSTALL_ABORTED
    if status is CleanupStatus.CHANGED:
        print("   ✅ Entrées de bureau Ergopti retirées.")
    else:
        print("   ℹ️  Aucune entrée de bureau Ergopti à retirer.")
    return EXIT_OK


def main(argv: list[str]) -> int:
    force_utf8_stdio()
    args = parse_args(argv)
    roots = resolve_roots()
    if args.activate_only:
        return run_activation_phase(args.variant, roots)
    if args.deactivate_only:
        return run_deactivation_phase()
    check_root(roots)
    if args.uninstall:
        kept = uninstall_clean(roots, deactivate_desktop=not args.skip_activation)
        return EXIT_OK if kept else EXIT_INSTALL_ABORTED
    try:
        install_clean(
            symbols_path=args.xkb,
            types_path=args.types,
            xcompose_path=args.xcompose,
            variant=args.variant,
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
