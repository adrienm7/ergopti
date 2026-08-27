"""Legacy installer for the Ergopti XKB layout.

Edits the system XKB tree in place (``/usr/share/X11/xkb`` by default). It is
the only method Xorg can use: the X server compiles keymaps with its own
``xkbcomp`` from that tree alone and ignores the XKB extensions directories the
clean method relies on. It therefore stays the universal fallback, for X11
sessions and for hosts whose libxkbcommon predates extensions directories.

Every touched file gets a numbered backup (``file.1``, ``file.2``, …) so that
``--uninstall`` restores the pristine state. The installation:

- appends (or replaces) the ``xkb_symbols`` section in ``symbols/fr``, so the
  layout is addressed as the ``fr`` variant ``Ergopti_<version>``;
- inserts the custom key type *inside* the ``xkb_types`` section of
  ``types/extra``, which ``complete`` includes for every layout. A block
  appended after the section is a syntax error that makes ``xkbcomp`` reject
  the whole ``complete`` file and makes libxkbcommon silently drop the type,
  leaving Shift and AltGr dead (issue #84);
- registers the variant in ``rules/evdev.lst`` and ``rules/evdev.xml``;
- proves the result compiles *with* the custom type, through libxkbcommon and
  through Xorg's ``xkbcomp`` when they are installed, and rolls every touched
  file back otherwise;
- installs the ``.XCompose`` file in the desktop user's home.

Desktop activation is delegated to ``desktop_activation`` and runs without
privileges (``--activate-only``): dconf and the Plasma configuration belong to
the user's session and are unreachable from a root process.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))

from desktop_activation import (  # noqa: E402
    CleanupStatus,
    activate_layout,
    deactivate_layouts,
    keymap_has_type,
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
    insert_type_sections,
    remove_generation_two_links,
    resolve_roots,
    strip_legacy_evdev_patch,
    validate_layout_files,
)

# The legacy method registers the layout as a variant of the system ``fr``
# layout, so desktops address it as ``fr`` + ``Ergopti_<version>``.
LEGACY_BASE_LAYOUT = "fr"

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


class LegacyInstallError(RuntimeError):
    """A step that leaves the system tree unusable; triggers a rollback."""


@dataclass(frozen=True)
class LegacyPaths:
    """The system files the legacy method edits."""

    symbols_fr: Path
    types_extra: Path
    evdev_lst: Path
    evdev_xml: Path

    def touched(self) -> tuple[Path, ...]:
        return (self.symbols_fr, self.types_extra, self.evdev_lst, self.evdev_xml)


def legacy_paths(system_root: Path) -> LegacyPaths:
    return LegacyPaths(
        symbols_fr=system_root / "symbols" / LEGACY_BASE_LAYOUT,
        types_extra=system_root / "types" / "extra",
        evdev_lst=system_root / "rules" / "evdev.lst",
        evdev_xml=system_root / "rules" / "evdev.xml",
    )


def check_sudo(roots: InstallerRoots) -> None:
    """Refuse to edit the real system tree without root privileges."""
    if roots.sandboxed:
        return
    if not running_as_root():
        logging.error("This script must be run with sudo privileges.")
        sys.exit(1)


def legacy_spec(symbol_name: str) -> LayoutSpec:
    """Return the desktop-facing layout for a legacy install."""
    if not symbol_name:
        raise ValueError("legacy activation requires a symbol name")
    if "+" in symbol_name:
        return LayoutSpec.parse(symbol_name)
    return LayoutSpec(LEGACY_BASE_LAYOUT, symbol_name)


def legacy_layout_id(symbol_name: str) -> str:
    """Return the GNOME spelling of the legacy layout identifier."""
    return legacy_spec(symbol_name).gnome_id


# ---------------------------------------------------------------------------
# Backups
# ---------------------------------------------------------------------------


def backup_file(file_path: Path) -> Optional[Path]:
    """Copy ``file_path`` to the next free ``file_path.N``; ``None`` if absent."""
    if not file_path.exists():
        return None
    version = 1
    while True:
        backup_path = file_path.with_suffix(f"{file_path.suffix}.{version}")
        if not backup_path.exists():
            try:
                shutil.copy(file_path, backup_path)
            except OSError as error:
                raise LegacyInstallError(
                    f"Failed to create backup for {file_path}: {error}"
                ) from error
            logging.info("Created backup: %s", backup_path)
            return backup_path
        version += 1


def find_backups(target: Path) -> list[Path]:
    """Return the ``<name>.<N>`` backups of *target*, oldest first."""
    backups: list[tuple[int, Path]] = []
    for candidate in target.parent.glob(f"{target.name}.*"):
        suffix = candidate.name[len(target.name) + 1 :]
        if suffix.isdigit():
            backups.append((int(suffix), candidate))
    backups.sort()
    return [path for _, path in backups]


def restore_backups(backups: list[tuple[Path, Path]]) -> None:
    """Put back the files touched by this run and drop their fresh backups."""
    for target, backup in reversed(backups):
        try:
            shutil.copy(backup, target)
            backup.unlink()
            logging.info("Restored %s from %s", target, backup.name)
        except OSError as error:
            logging.error("Could not restore %s from %s: %s", target, backup, error)


# ---------------------------------------------------------------------------
# System tree edits
# ---------------------------------------------------------------------------


def extract_xkb_info(xkb_file: Path) -> Tuple[str, str]:
    symbol_name, display_name = "", ""
    try:
        with xkb_file.open("r", encoding="utf-8") as stream:
            for line in stream:
                if "xkb_symbols" in line:
                    symbol_name = line.split('"')[1]
                if "name[Group1]" in line:
                    display_name = line.split('"')[1]
                if symbol_name and display_name:
                    break
    except OSError as error:
        logging.error("Could not read from %s: %s", xkb_file, error)
    return symbol_name, display_name


def update_lst_file(lst_path: Path, symbol_name: str, display_name: str) -> Optional[Path]:
    """Register the variant in ``evdev.lst``; returns the backup taken."""
    if not lst_path.exists():
        logging.warning("LST file not found, variant not listed: %s", lst_path)
        return None
    lines = lst_path.read_text(encoding="utf-8").splitlines(keepends=True)
    variant_section_index = next(
        (index for index, line in enumerate(lines) if line.strip() == "! variant"), -1
    )
    if variant_section_index == -1:
        raise LegacyInstallError(f"Could not find '! variant' section in {lst_path}.")
    new_line = f"  {symbol_name:<15} {LEGACY_BASE_LAYOUT}: {display_name}\n"
    backup = backup_file(lst_path)
    replaced = False
    for index, line in enumerate(lines):
        if symbol_name in line:
            lines[index] = new_line
            replaced = True
            break
    if not replaced:
        lines.insert(variant_section_index + 1, new_line)
    try:
        lst_path.write_text("".join(lines), encoding="utf-8")
    except OSError as error:
        raise LegacyInstallError(f"Failed to update {lst_path}: {error}") from error
    logging.info("%s variant in %s.", "Updated" if replaced else "Added", lst_path)
    return backup


def update_xml_file(xml_path: Path, symbol_name: str, display_name: str) -> Optional[Path]:
    """Register the variant in ``evdev.xml``; returns the backup taken."""
    if not xml_path.exists():
        logging.warning("XML registry not found, variant not listed: %s", xml_path)
        return None
    try:
        tree = ET.parse(str(xml_path))
    except ET.ParseError as error:
        raise LegacyInstallError(f"Failed to parse {xml_path}: {error}") from error
    root = tree.getroot()
    fr_layout = None
    for layout in root.findall(".//layout"):
        name_elem = layout.find("configItem/name")
        if name_elem is not None and name_elem.text == LEGACY_BASE_LAYOUT:
            fr_layout = layout
            break
    if fr_layout is None:
        raise LegacyInstallError(f"French layout section not found in {xml_path}.")
    variant_list = fr_layout.find("variantList")
    if variant_list is None:
        variant_list = ET.SubElement(fr_layout, "variantList")
    existing_variant = None
    for variant in variant_list.findall("variant"):
        name_elem = variant.find("configItem/name")
        if name_elem is not None and name_elem.text == symbol_name:
            existing_variant = variant
            break
    backup = backup_file(xml_path)
    if existing_variant is not None:
        description = existing_variant.find("configItem/description")
        if description is not None:
            description.text = display_name
        logging.info("Updated variant '%s' in %s.", symbol_name, xml_path)
    else:
        new_variant = ET.Element("variant")
        config_item = ET.SubElement(new_variant, "configItem")
        ET.SubElement(config_item, "name").text = symbol_name
        ET.SubElement(config_item, "description").text = display_name
        variant_list.insert(0, new_variant)
        logging.info("Added variant '%s' to %s.", symbol_name, xml_path)
    try:
        tree.write(
            str(xml_path),
            encoding="utf-8",
            xml_declaration=True,
            short_empty_elements=False,
        )
    except OSError as error:
        raise LegacyInstallError(f"Failed to update {xml_path}: {error}") from error
    return backup


def update_xkb_symbols_file(
    source_xkb: Path, symbol_name: str, dest_symbols_file: Path
) -> Optional[Path]:
    """Append or replace the layout section in ``symbols/fr``."""
    source_content = source_xkb.read_text(encoding="utf-8")
    section_re = re.compile(
        rf'xkb_symbols "{re.escape(symbol_name)}" \{{.*?^\}};',
        re.DOTALL | re.MULTILINE,
    )
    section_match = section_re.search(source_content)
    if not section_match:
        raise LegacyInstallError(f"Could not find symbol section in {source_xkb}.")
    section_to_add = section_match.group(0)
    if not dest_symbols_file.exists():
        raise LegacyInstallError(
            f"System symbols file {dest_symbols_file} not found; is xkeyboard-config installed?"
        )
    content = dest_symbols_file.read_text(encoding="utf-8")
    backup = backup_file(dest_symbols_file)
    if section_re.search(content):
        new_content = section_re.sub(lambda _m: section_to_add, content, count=1)
        logging.info("Replaced existing symbols section in %s.", dest_symbols_file)
    else:
        new_content = content.rstrip() + "\n\n" + section_to_add + "\n"
        logging.info("Appended new symbols section to %s.", dest_symbols_file)
    try:
        dest_symbols_file.write_text(new_content, encoding="utf-8")
    except OSError as error:
        raise LegacyInstallError(
            f"Failed to update symbols file {dest_symbols_file}: {error}"
        ) from error
    return backup


def update_xkb_types_file(source_types: Path, dest_types_file: Path) -> Optional[Path]:
    """Insert the custom key types inside the ``xkb_types`` section of ``types/extra``."""
    source_content = source_types.read_text(encoding="utf-8")
    if not dest_types_file.exists():
        raise LegacyInstallError(
            f"System types file {dest_types_file} not found; is xkeyboard-config installed?"
        )
    content = dest_types_file.read_text(encoding="utf-8")
    try:
        new_content, handled = insert_type_sections(content, source_content)
    except ValueError as error:
        raise LegacyInstallError(f"Cannot merge types into {dest_types_file}: {error}") from error
    backup = backup_file(dest_types_file)
    try:
        dest_types_file.write_text(new_content, encoding="utf-8")
    except OSError as error:
        raise LegacyInstallError(
            f"Failed to update types file {dest_types_file}: {error}"
        ) from error
    logging.info("Merged type(s) %s into %s.", ", ".join(handled), dest_types_file)
    return backup


def install_xcompose_file(xcompose_file: Path, force: bool = True) -> None:
    """Copy the Compose file into the desktop user's home, with a backup."""
    home_dir, uid, gid = resolve_user_identity()
    dest_xcompose = home_dir / ".XCompose"
    if dest_xcompose.exists():
        if force:
            logging.info(
                "Existing %s detected and force flag set: backing up and overwriting.",
                dest_xcompose,
            )
        else:
            try:
                tty = open("/dev/tty", "r+", encoding="utf-8")
            except OSError:
                logging.error(
                    "%s already exists and no terminal is available to ask the user. "
                    "Run the installer interactively or pass --force-xcompose.",
                    dest_xcompose,
                )
                sys.exit(2)
            try:
                tty.write(f"{dest_xcompose} already exists. Overwrite? [Y/n] (Enter = yes): ")
                tty.flush()
                response = tty.readline().strip().lower()
            finally:
                tty.close()
            if response not in ("", "y", "yes"):
                logging.info("User declined to overwrite %s; skipping.", dest_xcompose)
                return
        backup_file(dest_xcompose)
    try:
        home_dir.mkdir(parents=True, exist_ok=True)
        shutil.copy(xcompose_file, dest_xcompose)
        chown = getattr(os, "chown", None)
        if callable(chown) and uid is not None and gid is not None:
            chown(dest_xcompose, uid, gid)
    except OSError as error:
        logging.error("Failed to install .XCompose file: %s", error)
        return
    logging.info("Installed .XCompose file to %s", dest_xcompose)


def purge_cache(roots: InstallerRoots) -> None:
    """Drop Xorg's compiled-keymap cache so the next login recompiles."""
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
            logging.warning("XKB cache entry not removed %s (%s)", child.name, error)
    logging.info("XKB cache purged.")


def remove_conflicting_clean_package(roots: InstallerRoots) -> None:
    """Remove the extensions-directory package if a clean install exists.

    The two methods are mutually exclusive; keeping both would let the rules
    composition and the legacy tree fight over the same layout id.
    """
    package_dir = roots.package_dir
    if package_dir.is_dir():
        shutil.rmtree(package_dir)
        logging.info("Removed conflicting clean-method package directory: %s", package_dir)


def cleanup_previous_generations(roots: InstallerRoots) -> None:
    removed_links = remove_generation_two_links(roots.system_root)
    if removed_links:
        logging.info("Removed %d stale bridge link(s) in %s.", removed_links, roots.system_root)
    stripped = strip_legacy_evdev_patch(roots.system_root)
    if stripped:
        logging.info("Removed %d inherited Ergopti rule line(s) from rules/evdev.", stripped)


# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

XKBCOMP_KEYMAP_TEMPLATE = """xkb_keymap {{
\txkb_keycodes  {{ include "evdev+aliases(qwerty)" }};
\txkb_types     {{ include "complete" }};
\txkb_compat    {{ include "complete" }};
\txkb_symbols   {{ include "{symbols}" }};
\txkb_geometry  {{ include "pc(pc105)" }};
}};
"""


def xkbcomp_check(roots: InstallerRoots, spec: LayoutSpec) -> Optional[bool]:
    """Compile through Xorg's own compiler; ``None`` when it is not installed.

    libxkbcommon and ``xkbcomp`` parse the tree independently, and only the
    latter is what an Xorg session actually uses.
    """
    xkbcomp = shutil.which("xkbcomp")
    if not xkbcomp:
        logging.info("xkbcomp absent: Xorg-side compilation check skipped.")
        return None
    symbols = f"pc+{spec.layout}({spec.variant})+inet(evdev)" if spec.variant else f"pc+{spec.layout}+inet(evdev)"
    handle, temporary = tempfile.mkstemp(prefix="ergopti-", suffix=".xkb", text=True)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(XKBCOMP_KEYMAP_TEMPLATE.format(symbols=symbols))
        command = [xkbcomp]
        if roots.sandboxed:
            command.append(f"-I{roots.system_root}")
        command += ["-xkb", temporary, "-"]
        result = subprocess.run(
            command, capture_output=True, text=True, timeout=60, check=False
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        logging.warning("xkbcomp could not run: %s", error)
        return None
    finally:
        Path(temporary).unlink(missing_ok=True)
    if result.returncode != 0:
        logging.error("xkbcomp rejected the installed layout:")
        for line in (result.stderr or "").strip().splitlines()[:12]:
            logging.error("   %s", line)
        return False
    if not keymap_has_type(result.stdout, ERGOPTI_TYPE_NAME):
        logging.error("xkbcomp compiled the layout without the %s type.", ERGOPTI_TYPE_NAME)
        return False
    logging.info("xkbcomp compiled the layout with the %s type.", ERGOPTI_TYPE_NAME)
    return True


def compile_check(roots: InstallerRoots, spec: LayoutSpec) -> Optional[bool]:
    """Prove the patched tree compiles with the custom type present.

    Returns ``None`` when neither compiler is installed (unverified), ``False``
    when any installed compiler rejects the tree or drops the type.
    """
    include_roots = [roots.system_root] if roots.sandboxed else None
    verdicts = [
        verify_keymap(spec, ERGOPTI_TYPE_NAME, include_roots=include_roots),
        xkbcomp_check(roots, spec),
    ]
    if False in verdicts:
        return False
    if all(verdict is None for verdict in verdicts):
        return None
    return True


# ---------------------------------------------------------------------------
# Install / uninstall
# ---------------------------------------------------------------------------


def perform_install(
    roots: InstallerRoots,
    xkb_file: Path,
    xcompose_file: Optional[Path],
    types_file: Path,
    force_xcompose: bool = False,
) -> LayoutSpec:
    """Write the system XKB tree transactionally and return the layout to activate."""
    paths = legacy_paths(roots.system_root)
    symbol_name, display_name = extract_xkb_info(xkb_file)
    if not symbol_name or not display_name:
        raise LegacyInstallError(f"Could not extract layout info from {xkb_file}.")
    spec = legacy_spec(symbol_name)
    backups: list[tuple[Path, Path]] = []

    def record(target: Path, backup: Optional[Path]) -> None:
        if backup is not None:
            backups.append((target, backup))

    try:
        record(paths.symbols_fr, update_xkb_symbols_file(xkb_file, symbol_name, paths.symbols_fr))
        record(paths.types_extra, update_xkb_types_file(types_file, paths.types_extra))
        record(paths.evdev_lst, update_lst_file(paths.evdev_lst, symbol_name, display_name))
        record(paths.evdev_xml, update_xml_file(paths.evdev_xml, symbol_name, display_name))
        cleanup_previous_generations(roots)
        verdict = compile_check(roots, spec)
        if verdict is False:
            raise LegacyInstallError(
                "the patched XKB tree does not compile with the Ergopti key type; "
                "every touched file has been restored"
            )
        if verdict is None:
            logging.warning(
                "No XKB compiler found (xkbcli or xkbcomp): the installation could not be verified."
            )
    except LegacyInstallError:
        restore_backups(backups)
        raise

    if xcompose_file and xcompose_file.is_file():
        install_xcompose_file(xcompose_file, force=force_xcompose)
    else:
        logging.info("No .XCompose file specified. Skipping.")
    purge_cache(roots)
    return spec


def deactivate_desktop_entries() -> CleanupStatus:
    """Remove the desktop entries, dropping privileges when run as root."""
    if running_as_root():
        code = rerun_unprivileged(
            [sys.executable or "python3", str(Path(__file__).resolve()), "--deactivate-only"]
        )
        if code is None:
            logging.warning(
                "Cannot reach the desktop session as root; re-run without sudo with "
                "--deactivate-only if the layout stays listed."
            )
            return CleanupStatus.ABSENT
        return CleanupStatus.ABSENT if code == 0 else CleanupStatus.FAILED
    return deactivate_layouts()


def uninstall_legacy(roots: InstallerRoots, deactivate_desktop: bool = True) -> bool:
    """Restore every file the legacy installer touched, from its first backup.

    The first backup (``.1``) is the pristine pre-Ergopti snapshot taken
    before the very first modification. When a file has no backup, it was
    never touched by this installer and is left alone.
    """
    if deactivate_desktop and deactivate_desktop_entries() is CleanupStatus.FAILED:
        logging.error("Desktop entries could not be removed; the system files are kept.")
        return False
    changed = False
    home_dir, _uid, _gid = resolve_user_identity()
    targets = list(legacy_paths(roots.system_root).touched()) + [home_dir / ".XCompose"]
    for target in targets:
        backups = find_backups(target)
        if not backups:
            continue
        pristine = backups[0]
        try:
            shutil.copy(pristine, target)
        except OSError as error:
            logging.error("Could not restore %s: %s", target, error)
            continue
        logging.info("Restored %s from %s", target, pristine.name)
        for extra in backups[1:]:
            extra.unlink(missing_ok=True)
        changed = True
    removed_lines = strip_legacy_evdev_patch(roots.system_root)
    if removed_lines:
        logging.info("Removed %d inherited Ergopti rule line(s).", removed_lines)
        changed = True
    removed_links = remove_generation_two_links(roots.system_root)
    if removed_links:
        logging.info("Removed %d stale bridge link(s).", removed_links)
        changed = True
    purge_cache(roots)
    if not changed:
        logging.info("Nothing to uninstall: no legacy backup found.")
        return False
    logging.warning(
        "Legacy uninstall complete. Log out / log back in, and check "
        "~/.XCompose if you had custom Compose sequences."
    )
    return True


# ---------------------------------------------------------------------------
# Desktop phases (unprivileged)
# ---------------------------------------------------------------------------


def run_activation_phase(layout_id: Optional[str], roots: InstallerRoots) -> int:
    """Activate a legacy install in the user's desktop session."""
    if not layout_id:
        logging.error("--activate-only requires --layout-id.")
        return EXIT_INSTALL_ABORTED
    spec = legacy_spec(layout_id)
    if running_as_root():
        argv = [
            sys.executable or "python3",
            str(Path(__file__).resolve()),
            "--activate-only",
            "--layout-id",
            spec.gnome_id,
        ]
        code = rerun_unprivileged(argv)
        if code is not None:
            return EXIT_OK if code == 0 else EXIT_INSTALL_ABORTED
        logging.error(
            "Cannot activate as root and no desktop user was identified; "
            "re-run without sudo: python3 %s --activate-only --layout-id %s",
            Path(__file__).resolve(),
            spec.gnome_id,
        )
        return EXIT_INSTALL_ABORTED
    print("🔎 Vérification de la disposition installée…")
    include_roots = [roots.system_root] if roots.sandboxed else None
    verify_keymap(spec, ERGOPTI_TYPE_NAME, include_roots=include_roots)
    activate_layout([spec])
    return EXIT_OK


def run_deactivation_phase() -> int:
    """Remove the desktop entries from the user's session before file restore."""
    if running_as_root():
        code = rerun_unprivileged(
            [sys.executable or "python3", str(Path(__file__).resolve()), "--deactivate-only"]
        )
        if code is not None:
            return EXIT_OK if code == 0 else EXIT_INSTALL_ABORTED
        logging.warning("Cannot reach the desktop session as root; re-run without sudo.")
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


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Apply Ergopti XKB installation (non-interactive, legacy method)."
    )
    parser.add_argument("--xkb", type=Path, help="Path to the .xkb file (required unless --uninstall).")
    parser.add_argument("--xcompose", type=Path, help="Path to the .XCompose file.")
    parser.add_argument(
        "--types",
        type=Path,
        help="Path to the full xkb_types.txt file (required when installing: "
        "it owns the Shift/CapsLock/AltGr layers).",
    )
    parser.add_argument(
        "--force-xcompose",
        action="store_true",
        help="When provided, overwrite the user's ~/.XCompose without prompting.",
    )
    parser.add_argument(
        "--uninstall", action="store_true", help="Restore the files this installer previously backed up."
    )
    parser.add_argument(
        "--skip-activation",
        action="store_true",
        help="Install or uninstall the files without touching the desktop session.",
    )
    parser.add_argument(
        "--activate-only",
        action="store_true",
        help="Activate an already installed layout in the current desktop session.",
    )
    parser.add_argument(
        "--deactivate-only",
        action="store_true",
        help="Remove the layout from the desktop session without touching any file.",
    )
    parser.add_argument("--layout-id", help="Layout identifier to activate, e.g. fr+Ergopti_v2_2_1.")
    args = parser.parse_args(argv)
    if args.activate_only and args.deactivate_only:
        parser.error("--activate-only is incompatible with --deactivate-only")
    if (args.activate_only or args.deactivate_only) and args.uninstall:
        parser.error("--activate-only and --deactivate-only are incompatible with --uninstall")
    if not (args.uninstall or args.activate_only or args.deactivate_only):
        missing = [name for name in ("--xkb", "--types") if getattr(args, name.lstrip("-")) is None]
        if missing:
            parser.error("the following options are required: " + ", ".join(missing))
    return args


def main(argv: list[str]) -> int:
    if sys.platform == "win32":
        logging.error("This script is for Linux and cannot be run on Windows.")
        return EXIT_INSTALL_ABORTED
    args = parse_args(argv)
    roots = resolve_roots()
    if args.activate_only:
        return run_activation_phase(args.layout_id, roots)
    if args.deactivate_only:
        return run_deactivation_phase()
    check_sudo(roots)
    if args.uninstall:
        uninstall_legacy(roots, deactivate_desktop=not args.skip_activation)
        return EXIT_OK

    if "_plus_plus" in args.xkb.name.lower():
        logging.error(
            "Ergopti++ is no longer installable (it saturates XCompose). "
            "Choose Ergopti or Ergopti+ instead."
        )
        return EXIT_VALIDATION
    problems = validate_layout_files(
        args.xkb.read_text(encoding="utf-8"), args.types.read_text(encoding="utf-8")
    )
    if problems:
        for problem in problems:
            logging.error("Layout package inconsistency: %s", problem)
        logging.error("Aborting: refusing to write an incoherent layout.")
        return EXIT_VALIDATION

    remove_conflicting_clean_package(roots)
    try:
        spec = perform_install(
            roots, args.xkb, args.xcompose, args.types, force_xcompose=args.force_xcompose
        )
    except LegacyInstallError as error:
        logging.error("%s", error)
        return EXIT_INSTALL_ABORTED
    logging.info("Desktop activation identifier: %s", spec.gnome_id)
    if not args.skip_activation:
        return run_activation_phase(spec.gnome_id, roots)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
