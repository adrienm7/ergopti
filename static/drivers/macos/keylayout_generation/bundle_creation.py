"""Create a macOS bundle for Ergopti keylayouts."""

import os
import re
import shutil
import zipfile
from pathlib import Path

from utilities.logger import logger

BUNDLE_IDENTIFIER = "com.apple.keyboardlayout.ergopti"
LOGS_INDENTATION = "\t"


def create_bundle(
    bundle_path: Path,
    version: str,
    keylayout_paths: list[Path],
    logo_paths: list[Path],
    cleanup: bool = True,
    zip_destination_dir: Path = None,
):
    """
    Create a .bundle package for macOS keyboard layouts.
    keylayout_paths and logo_paths must be lists of the same length.
    Each layout file is saved as Ergopti.keylayout or Ergopti Plus.keylayout,
    and its internal <keyboard name="..."> attribute is also rewritten.
    """
    if len(keylayout_paths) != len(logo_paths):
        raise ValueError(
            "keylayout_paths and logo_paths must have the same length"
        )

    if bundle_path.exists():
        shutil.rmtree(bundle_path)

    resources_path = bundle_path / "Contents" / "Resources"
    resources_path.mkdir(parents=True, exist_ok=True)

    info_plist_entries = []
    layout_localization_infos: list[tuple[str, bool]] = []

    for keylayout, logo in zip(keylayout_paths, logo_paths):
        if not keylayout.exists():
            raise FileNotFoundError(f"Keylayout file not found: {keylayout}")
        if not logo or not logo.exists():
            logger.info(
                "%sLogo file not found: %s, continuing without it",
                LOGS_INDENTATION,
                logo,
            )
            logo_path_to_use = None
        else:
            logo_path_to_use = logo

        # Read and patch keylayout content
        content = keylayout.read_text(encoding="utf-8")
        stem = keylayout.stem.lower()
        is_plusplus = stem.endswith("plus_plus")
        is_plus = "plus" in stem and not is_plusplus
        if is_plusplus:
            new_name = "Ergopti Plus Plus"
        elif is_plus:
            new_name = "Ergopti Plus"
        else:
            new_name = "Ergopti"

        # Necessary for the layout to be found in "French" layouts instead of "Others"
        content = re.sub(
            r'(<keyboard\b[^>]*\bname=")([^"]+)(")',
            rf"\1{new_name}\3",
            content,
        )

        # Determine output file name
        dest_filename = f"{new_name}.keylayout"
        dest_layout = resources_path / dest_filename
        dest_layout.write_text(content, encoding="utf-8")

        if is_plusplus:
            layout_localization_infos.append((new_name, "++"))
        elif is_plus:
            layout_localization_infos.append((new_name, "+"))
        else:
            layout_localization_infos.append((new_name, ""))

        # Copy logo file with matching base name
        icon_tag = ""
        if logo_path_to_use:
            dest_logo = resources_path / f"{new_name}.icns"
            shutil.copy(logo_path_to_use, dest_logo)
            icon_tag = f"""
            <key>TISIconIsTemplate</key>
            <false/>
            <key>ICNS</key>
            <string>{dest_logo.name}</string>"""
            logger.info(
                "%sAdded logo %s as %s",
                LOGS_INDENTATION,
                logo_path_to_use.name,
                dest_logo.name,
            )

        plist_key = f"KLInfo_{new_name}"
        if is_plusplus:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plusplus"
        elif is_plus:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plus"
        else:
            input_source_id = BUNDLE_IDENTIFIER

        info_plist_entries.append(f"""<key>{plist_key}</key>
        <dict>
            <key>TICapsLockLanguageSwitchCapable</key>
            <true/>{icon_tag}
            <key>TISInputSourceID</key>
            <string>{input_source_id}</string>
            <key>TISIntendedLanguage</key>
            <string>fr</string>
        </dict>""")

    # Write Info.plist
    info_plist_content = generate_info_plist(version, info_plist_entries)
    info_plist_path = bundle_path / "Contents" / "Info.plist"
    info_plist_path.write_text(info_plist_content, encoding="utf-8")

    # Write localized InfoPlist.strings
    generate_localizations(bundle_path, version, layout_localization_infos)

    # Write version.plist
    version_plist_content = generate_version_plist(version)
    version_plist_path = bundle_path / "Contents" / "version.plist"
    version_plist_path.write_text(version_plist_content, encoding="utf-8")

    # Zip the bundle
    if zip_destination_dir:
        zip_path = zip_destination_dir / f"{bundle_path.name}.zip"
    else:
        zip_path = bundle_path.with_suffix(".bundle.zip")
    zip_bundle_folder(bundle_path, zip_path)
    if cleanup:
        shutil.rmtree(bundle_path)

    return (bundle_path if not cleanup else None, zip_path)


def generate_info_plist(version: str, entries: list[str]) -> str:
    """Generate the full Info.plist content without localized translations."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>Ergopti</string>
    <key>CFBundleVersion</key>
    <string>{version.lstrip("v")}</string>
    {"\n\t".join(entries)}
</dict>
</plist>
"""


def generate_localizations(
    bundle_path: Path, version: str, layouts: list[tuple[str, bool]]
):
    """
    Generate localized InfoPlist.strings files (en and fr).
    Each layout name is mapped to either:
      - "Ergopti v{version}"  (standard)
      - "Ergopti+ v{version}" (plus)
    """
    for lang in ("en", "fr"):
        lproj_dir = bundle_path / "Contents" / "Resources" / f"{lang}.lproj"
        lproj_dir.mkdir(parents=True, exist_ok=True)
        strings_path = lproj_dir / "InfoPlist.strings"

        lines = []
        for original_name, variant in layouts:
            if variant == "++":
                localized = f"Ergopti++ {version}"
            elif variant == "+":
                localized = f"Ergopti+ {version}"
            else:
                localized = f"Ergopti {version}"
            lines.append(f'"{original_name}" = "{localized}";')

        strings_content = "\n".join(lines) + "\n"
        strings_path.write_text(strings_content, encoding="utf-16")
        logger.info(
            "%s🌍 Added localization mappings for %s: %s",
            LOGS_INDENTATION,
            lang,
            strings_path,
        )


def generate_version_plist(version: str) -> str:
    """Generate the version.plist content dynamically."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BuildVersion</key>
    <string>{version.lstrip("v")}</string>
    <key>ProjectName</key>
    <string>Ergopti</string>
    <key>SourceVersion</key>
    <string>{version.lstrip("v")}</string>
</dict>
</plist>
"""


def zip_bundle_folder(bundle_path: Path, zip_path: Path):
    """Zip the entire bundle folder so that unzipping preserves the bundle folder."""
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, _, files in os.walk(bundle_path):
            for file in files:
                file_path = Path(root) / file
                relative_path = file_path.relative_to(bundle_path.parent)
                zipf.write(file_path, relative_path)
    logger.info("%s📦 Zipped bundle at: %s", LOGS_INDENTATION, zip_path)
