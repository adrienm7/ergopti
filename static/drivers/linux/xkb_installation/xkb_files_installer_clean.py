"""
UNIVERSAL XKB LAYOUT INSTALLER (Hybrid Architecture + Strict Cleanup)

Overview:
    This script installs any custom XKB keyboard layout on Linux systems.
    It implements a "Hybrid" approach to ensure maximum compatibility:
    1. Modern: Installs files to /usr/share/xkeyboard-config.d/
    2. Legacy Bridge: Creates symbolic links in /usr/share/X11/xkb/
    3. Force Patch: Directly registers the layout in system evdev rules.

Features:
    - Deep Cleanup: Aggressively removes old symlinks and artifacts to prevent
      conflicts or dead links when switching variants.
    - XCompose Sync: Forces the update of the user's .XCompose file.
    - Cache Purge: Automatically clears XKB cache and refreshes input sources.

Usage:
    sudo python3 install.py --xkb <layout_file>.xkb [--types <types_file>] [--xcompose <compose_file>]

Example:
    sudo python3 install.py --xkb ergopti.xkb --types types.txt --xcompose .XCompose
"""

import argparse
import logging
import os
import shutil
import sys
import pwd
import subprocess
import re
import glob
import time
from pathlib import Path
from typing import Optional

# --- Constants & Paths ---
# Internal package name for folder organization
PACKAGE_NAME = "ergopti" 

# Paths
MODERN_XKB_PATH = Path("/usr/share/xkeyboard-config.d")
SYSTEM_XKB_PATH = Path("/usr/share/X11/xkb")
RULES_EVDEV_PATH = SYSTEM_XKB_PATH / "rules" / "evdev"
XKB_CACHE_DIR = Path("/var/lib/xkb")

# --- Logging Setup ---
logging.basicConfig(level=logging.INFO, format="%(message)s")


# ==================================================
# ============== EXECUTION PHASE ===================
# ==================================================

def main():
    """Main execution flow."""
    parser = argparse.ArgumentParser(description="Universal XKB Layout Installer")
    parser.add_argument("--xkb", type=Path, required=True, help="Path to the .xkb symbols file")
    parser.add_argument("--types", type=Path, help="Path to the types definition file")
    parser.add_argument("--xcompose", type=Path, help="Path to the .XCompose file")
    args = parser.parse_args()

    # 1. Privileges Validation
    check_sudo()
    logging.info(f"🚀 Installation de la disposition : {args.xkb.stem}")
    logging.info("   (Mode: Hybride + Nettoyage Strict + Force Patch)")

    try:
        # 2. Deep Cleanup of previous versions (Fixes dead links/variants)
        deep_cleanup_artifacts()

        # 3. Setup Directory Structure
        pkg_dir = setup_package_directory()
        layout_id = args.xkb.stem  # e.g., "ergopti", "fr-optimised"

        # 4. Install Core Files (Modern Path)
        install_file(args.xkb, pkg_dir / "symbols" / layout_id, patch_default=True)
        if args.types:
            install_file(args.types, pkg_dir / "types" / layout_id)

        # 5. Generate Configuration (Partial XML for UI)
        create_partial_xml(pkg_dir, layout_id, display_name="Custom Ergo")

        # 6. System Integration (Symlinks Bridge)
        create_system_symlinks(pkg_dir, layout_id)

        # 7. Apply Forced Rules Patch (Crucial for types loading)
        patch_system_evdev_rules(layout_id)

        # 8. User Configuration (Force Update XCompose)
        if args.xcompose:
            install_user_xcompose(args.xcompose)

        # 9. Activation & Cleanup
        refresh_and_activate(layout_id)

        logging.info("\n✨ Installation terminée avec succès.")

    except Exception as e:
        logging.error(f"\n❌ Erreur critique : {e}")
        sys.exit(1)


# ==================================================
# ============= SYSTEM & PRIVILEGES ================
# ==================================================

def check_sudo():
    """Ensures the script is running with root privileges."""
    if os.geteuid() != 0:
        logging.error("❌ Ce script doit être lancé avec sudo (root).")
        sys.exit(1)

def get_sudo_user_info() -> Optional[pwd.struct_passwd]:
    """Retrieves the actual user invoking sudo (to locate home dir)."""
    try:
        sudo_user = os.getenv("SUDO_USER")
        if sudo_user:
            return pwd.getpwnam(sudo_user)
    except KeyError:
        pass
    return None


# ==================================================
# ============ CLEANUP & FILESYSTEM ================
# ==================================================

def deep_cleanup_artifacts():
    """
    Aggressively removes old symlinks and files related to the package
    in the system XKB directories to prevent dead links or shadow files.
    """
    logging.info("   🧹 Nettoyage approfondi des anciennes versions...")
    
    # Directories where artifacts might linger
    subdirs = ["symbols", "types", "rules", "compat"]
    
    # Patterns to match (files containing the package name)
    # Adding variations to catch previous manual installs
    patterns = [f"*{PACKAGE_NAME}*", "*Ergopti*", "*ergopti*"]

    for subdir in subdirs:
        target_dir = SYSTEM_XKB_PATH / subdir
        if not target_dir.exists(): continue

        # 1. Remove by name pattern
        for pattern in patterns:
            for path_str in glob.glob(str(target_dir / pattern)):
                try:
                    p = Path(path_str)
                    if p.is_symlink() or p.is_file():
                        p.unlink()
                        logging.info(f"      🗑️ Supprimé : {p.name}")
                except Exception as e:
                    logging.warning(f"      ⚠️ Impossible de supprimer {path_str}: {e}")

        # 2. Remove broken symlinks pointing to our modern package folder
        # This catches links even if they were renamed to something else
        for p in target_dir.iterdir():
            if p.is_symlink():
                try:
                    target = p.resolve()
                    if PACKAGE_NAME in str(target):
                        p.unlink()
                        logging.info(f"      🔗 Lien obsolète supprimé : {p.name}")
                except FileNotFoundError:
                    # It's a broken link, check if it looks like ours
                    if PACKAGE_NAME in str(p):
                        p.unlink()


def setup_package_directory() -> Path:
    """Creates the package directory structure, wiping previous content."""
    pkg_dir = MODERN_XKB_PATH / PACKAGE_NAME
    if pkg_dir.exists():
        shutil.rmtree(pkg_dir)

    for folder in ("symbols", "types", "rules"):
        target = pkg_dir / folder
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, 0o755)
    return pkg_dir

def install_file(src: Path, dest: Path, patch_default: bool = False):
    """Copies source file to destination, optionally adding 'default' group."""
    if not src.exists():
        raise FileNotFoundError(f"Fichier introuvable : {src}")
    try:
        with src.open('r', encoding='utf-8') as f:
            content = f.read()
        
        if patch_default:
            # Ensure compatibility with Gnome/X11 requiring a default section
            content = re.sub(r'xkb_symbols\s+"[^"]+"', 'xkb_symbols "default"', content)
            if "default partial" not in content:
                content = content.replace(
                    'xkb_symbols "default"', 
                    'default partial alphanumeric_keys\nxkb_symbols "default"'
                )
        
        with dest.open('w', encoding='utf-8') as f:
            f.write(content)
        os.chmod(dest, 0o644)
    except Exception as e:
        raise IOError(f"Erreur d'installation pour {src.name} : {e}")


# ==================================================
# ============ RULES PATCHING ======================
# ==================================================

def patch_system_evdev_rules(layout_name: str):
    """
    Directly modifies /usr/share/X11/xkb/rules/evdev to associate layout=types.
    This is the "Force Patch" method required when evdev.post fails.
    """
    logging.info("   🔧 Application du patch système (rules/evdev)...")

    if not RULES_EVDEV_PATH.exists():
        logging.warning("⚠️ Fichier rules/evdev introuvable.")
        return

    try:
        with open(RULES_EVDEV_PATH, 'r', encoding='utf-8') as f:
            lines = f.readlines()
        
        # --- [MODIFICATION STARTED] ---
        # Clean up ANY old lines containing 'ergopti' or the package name.
        # This prevents accumulation of old variants like "Ergopti_v2", "Ergopti_v3", etc.
        clean_lines = []
        blacklist_terms = [PACKAGE_NAME.lower(), "ergopti"]
        
        for line in lines:
            # If the line contains an equals sign (it's a rule) AND matches "ergopti"
            # we skip it (delete it).
            if "=" in line and any(term in line.lower() for term in blacklist_terms):
                continue
            clean_lines.append(line)
            
        if len(lines) != len(clean_lines):
            logging.info(f"      🧹 {len(lines) - len(clean_lines)} anciennes entrées nettoyées dans evdev.")
            lines = clean_lines
        # --- [MODIFICATION ENDED] ---

        # 2. Prepare the patch logic
        section_regex = re.compile(r"^\s*!\s*layout\s*=\s*types\s*$")
        start_idx = -1
        patch_line = f"  {layout_name} = +{layout_name}\n"

        # Find the section header
        for i, line in enumerate(lines):
            if section_regex.match(line):
                start_idx = i
                break

        # 3. Apply the patch
        if start_idx != -1:
            # Normal: Insert after the header
            lines.insert(start_idx + 1, patch_line)
            with open(RULES_EVDEV_PATH, 'w', encoding='utf-8') as f:
                f.writelines(lines)
            logging.info(f"      ✅ Règles mises à jour (Insertion).")
        else:
            # Fallback: Force append to end of file if section missing
            needs_newline = lines and not lines[-1].endswith('\n')
            with open(RULES_EVDEV_PATH, 'a', encoding='utf-8') as f:
                if needs_newline: f.write("\n")
                f.write(f"\n! layout = types\n{patch_line}")
            logging.info(f"      ✅ Règles ajoutées à la fin (Force Append).")

    except Exception as e:
        logging.error(f"❌ Erreur patch rules : {e}")

def create_partial_xml(pkg_dir: Path, layout_name: str, display_name: str):
    """Creates XML for GUI registry (Gnome Settings / KDE)."""
    xml_file = pkg_dir / "rules" / "evdev.xml"
    xml_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE xkbConfigRegistry SYSTEM "xkb.dtd">
<xkbConfigRegistry version="1.1">
  <layoutList>
    <layout>
      <configItem>
        <name>{layout_name}</name>
        <shortDescription>Ergo</shortDescription>
        <description>{display_name}</description>
        <languageList><iso639Id>fra</iso639Id></languageList>
      </configItem>
    </layout>
  </layoutList>
</xkbConfigRegistry>
"""
    try:
        with xml_file.open('w', encoding='utf-8') as f: f.write(xml_content)
        os.chmod(xml_file, 0o644)
    except Exception: pass


# ==================================================
# ========= SYSTEM INTEGRATION (BRIDGE) ============
# ==================================================

def create_system_symlinks(pkg_dir: Path, layout_name: str):
    """Create new symbolic links to bridge modern path to legacy system path."""
    logging.info("   🔗 Création des liens système...")
    folders = ["symbols", "types"]
    for folder in folders:
        src = pkg_dir / folder / layout_name
        dest = SYSTEM_XKB_PATH / folder / layout_name
        
        if src.exists():
            try:
                # Determine if dest exists (symlink or file) and remove it
                if dest.exists() or dest.is_symlink():
                    dest.unlink()
                os.symlink(src, dest)
            except OSError as e:
                logging.error(f"      ❌ Erreur lien {folder}: {e}")


# ==================================================
# ======== USER ENVIRONMENT & ACTIVATION ===========
# ==================================================

def install_user_xcompose(src: Path):
    """
    Installs .XCompose. Forces overwrite to ensure update.
    """
    if not src.exists():
        logging.warning("⚠️ Fichier source XCompose introuvable.")
        return
    
    user = get_sudo_user_info()
    if not user:
        logging.warning("⚠️ Impossible de déterminer l'utilisateur sudo.")
        return
    
    dest = Path(user.pw_dir) / ".XCompose"
    
    try:
        # 1. Backup existing
        if dest.exists():
            shutil.copy2(dest, dest.with_suffix(".bak"))
            dest.unlink() # Explicitly remove old file to break inodes

        # 2. Copy new file
        shutil.copy(src, dest)
        
        # 3. Set Permissions
        os.chown(dest, user.pw_uid, user.pw_gid)
        os.chmod(dest, 0o644)
        
        # 4. Verification log
        size = dest.stat().st_size
        logging.info(f"   ⌨️ .XCompose mis à jour pour {user.pw_name} ({size} octets)")
        
    except Exception as e:
        logging.error(f"❌ Erreur critique .XCompose : {e}")

def refresh_and_activate(layout_id: str):
    """Purge cache and attempt to activate configuration via CLI."""
    # 1. Purge XKB cache
    if XKB_CACHE_DIR.exists():
        subprocess.run(f"rm -rf {XKB_CACHE_DIR}/*", shell=True, stderr=subprocess.DEVNULL)
        logging.info("   🔄 Cache XKB purgé.")

    user = get_sudo_user_info()
    if not user: return

    def run_as_user(cmd_list):
        """Helper to run command as the real user."""
        try:
            env = os.environ.copy()
            env['XDG_RUNTIME_DIR'] = f"/run/user/{user.pw_uid}"
            subprocess.run(['su', user.pw_name, '-c', " ".join(cmd_list)],
                env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception: pass

    logging.info("   🚀 Rechargement de la configuration...")
    
    # 2. Force types explicitly using setxkbmap (Immediate effect)
    run_as_user(['setxkbmap', '-layout', layout_id, '-types', f"complete+{layout_id}"])
    
    # 3. Update DE settings
    run_as_user(['gsettings', 'set', 'org.gnome.desktop.input-sources', 'sources', f"[('xkb', '{layout_id}')]"])
    run_as_user(['kwriteconfig6', '--file', 'kxkbrc', '--group', 'Layout', '--key', 'LayoutList', layout_id])
    run_as_user(['qdbus', 'org.kde.KWin', '/KWin', 'org.kde.KWin.reconfigure'])

if __name__ == "__main__":
    main()
