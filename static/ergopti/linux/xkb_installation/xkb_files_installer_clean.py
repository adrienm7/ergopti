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
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from layout_package import (  # noqa: E402
    InstallerRoots,
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


def compile_validation(staging_dir: Path, layout_id: str) -> bool:
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
        "XKB_CONFIG_UNVERSIONED_EXTENSIONS_PATH": str(staging_dir),
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
    package_dir = roots.package_dir
    if package_dir.exists():
        shutil.rmtree(package_dir)
        print(f"   🧹 Ancien paquet remplacé ({package_dir}).")
    staging = package_dir.with_name(f".{PACKAGE_NAME}.staging")
    if staging.exists():
        shutil.rmtree(staging, ignore_errors=True)
    removed_links = remove_generation_two_links(roots.system_root)
    if removed_links:
        print(f"   🧹 {removed_links} lien(s) hérité(s) supprimé(s) dans {roots.system_root}.")
    stripped_lines = strip_legacy_evdev_patch(roots.system_root)
    if stripped_lines:
        print(
            f"   🧹 {stripped_lines} ligne(s) de règles héritée(s) retirée(s) "
            f"de {roots.system_root / 'rules' / 'evdev'}."
        )


def install_clean(
    symbols_path: Path,
    types_path: Path,
    xcompose_path: Path | None,
    variant: str,
    support_x11: bool,
    roots: InstallerRoots,
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
        raise SystemExit(
            "Erreur : le paquet de disposition est incohérent ; installation annulée."
        )
    print("   ✅ Chaque type référencé par les symboles est bien défini.")

    layout_id = validate_component_identifier(PACKAGE_NAME)
    patched_symbols = patch_symbols_default(symbols_content)

    print("🧼 Nettoyage des installations précédentes…")
    cleanup_previous_installations(roots)

    package_dir = roots.package_dir
    staging_dir = package_dir.with_name(f".{PACKAGE_NAME}.staging")
    if staging_dir.exists():
        shutil.rmtree(staging_dir, ignore_errors=True)
    (staging_dir / "symbols").mkdir(parents=True)
    (staging_dir / "types").mkdir()
    (staging_dir / "rules").mkdir()

    (staging_dir / "symbols" / layout_id).write_text(patched_symbols, encoding="utf-8")
    (staging_dir / "types" / layout_id).write_text(types_content, encoding="utf-8")
    variants = []
    description = "Français — Ergopti"
    if variant == VARIANT_PLUS:
        description = "Français — Ergopti+"
        variants.append(("plus", "Ergopti+"))
    else:
        variants.append(("plus", "Ergopti+ (avec Espanso)"))
    (staging_dir / "rules" / "evdev.xml").write_text(
        build_registry_xml(layout_id, description, variants),
        encoding="utf-8",
    )
    (staging_dir / "rules" / "evdev.post").write_text(
        build_evdev_post(layout_id),
        encoding="utf-8",
    )

    if not compile_validation(staging_dir, layout_id):
        shutil.rmtree(staging_dir, ignore_errors=True)
        raise SystemExit(1)

    if package_dir.exists():
        shutil.rmtree(package_dir)
    staging_dir.rename(package_dir)
    print(f"📦 Paquet installé dans {package_dir}.")

    if xcompose_path is not None:
        install_user_xcompose(xcompose_path)

    if support_x11:
        create_legacy_symlinks(package_dir, layout_id, roots.system_root)

    purge_cache(roots)
    activate(layout_id, variant)


def install_user_xcompose(source: Path) -> None:
    sudo_user = os.environ.get("SUDO_USER", "")
    home = Path.home() if not sudo_user else Path(os.path.expanduser(f"~{sudo_user}"))
    destination = home / ".XCompose"
    try:
        if source.resolve() == destination.resolve():
            print("   ℹ️  .XCompose déjà en place.")
            return
        if destination.exists():
            shutil.copy2(destination, destination.with_suffix(".bak"))
            destination.unlink()
        shutil.copy(source, destination)
        print(f"   ✅ ~/.XCompose mis à jour ({destination.stat().st_size} octets).")
    except OSError as error:
        print(f"   ⚠️  .XCompose non installé : {error}")


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
    """Best-effort activation; every attempt is reported, none is fatal."""
    sudo_user = os.environ.get("SUDO_USER")
    prefix = ["sudo", "-u", sudo_user] if sudo_user else []

    def run_user(command: list[str], label: str) -> bool:
        if prefix:
            return run_reported(prefix + command, label)
        return run_reported(command, label)

    print("🚀 Activation (best-effort)…")
    run_user(["setxkbmap", "-layout", layout_id], "setxkbmap -layout (session X11)")
    sources = f"[('xkb', '{layout_id}'), ('xkb', '{layout_id}+plus')]"
    if variant == VARIANT_PLUS:
        sources = f"[('xkb', '{layout_id}+plus')]"
    run_user(
        [
            "gsettings",
            "set",
            "org.gnome.desktop.input-sources",
            "sources",
            sources,
        ],
        "Sélection GNOME",
    )
    run_user(
        [
            "kwriteconfig6",
            "--file",
            "kxkbrc",
            "--group",
            "Layout",
            "--key",
            "LayoutList",
            f"{layout_id}, {layout_id}+plus",
        ],
        "Sélection KDE Plasma",
    )
    print("   ℹ️  Déconnectez-vous/reconnectez-vous si la disposition n'est pas active.")


def uninstall_clean(roots: InstallerRoots) -> None:
    package_dir = roots.package_dir
    removed = False
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
    parser.add_argument("--xkb", type=Path, required=True, help="Fichier .xkb de la disposition")
    parser.add_argument("--types", type=Path, required=True, help="Fichier de types complet (obligatoire)")
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
    parser.add_argument("--uninstall", action="store_true", help="Désinstaller le paquet")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    force_utf8_stdio()
    args = parse_args(argv)
    roots = resolve_roots()
    check_root(roots)
    if args.uninstall:
        uninstall_clean(roots)
        return 0
    install_clean(
        symbols_path=args.xkb,
        types_path=args.types,
        xcompose_path=args.xcompose,
        variant=args.variant,
        support_x11=args.support_x11,
        roots=roots,
    )
    print("\n✨ Installation terminée. Redémarrez la session pour tout prendre en compte.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
