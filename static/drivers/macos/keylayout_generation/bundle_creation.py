"""Create a macOS bundle for Ergopti keylayouts."""

import os
import re
import shutil
import zipfile
from pathlib import Path

from utilities.logger import logger

# macOS reserves the `com.apple.keylayout.*` namespace for input sources that
# ship with the OS itself; third-party bundles must use `com.apple.keyboardlayout.*`
# (note the longer form). When a third-party bundle declares an ID under the
# reserved namespace, macOS silently refuses to register it — the bundle is
# physically copied to /Library/Keyboard Layouts/ but never shows up in the
# input-source list, regardless of whether Hammerspoon is running.
#
# The TIS IDs are kept stable across versions (no v2_2_X suffix) so that an
# upgrade is recognised as the same input source: the user-enabled set, the
# active selection, and any layout-specific preferences are preserved across
# v2.2.1 → v2.2.2 → … upgrades.
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
    Each layout file is saved as Ergopti_vx_x_x.keylayout format,
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
    # Each entry: (internal_name, variant, is_ansi, input_source_id).
    # input_source_id is needed because macOS looks up the localised display
    # name by `kTISPropertyInputSourceID` — using anything else (e.g. the
    # keylayout filename) silently falls back to the raw ID in System Settings.
    layout_localization_infos: list[tuple[str, str, bool, str]] = []

    # Extract version for filename format
    match = re.search(r"(v\d+\.\d+\.\d+)", version)
    simple_version = match.group(1) if match else version
    version_underscore = simple_version.replace(".", "_")

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
        # Detect plus_plus anywhere in the stem (covers both
        # "..._plus_plus" and "..._plus_plus_ANSI" filenames)
        is_plusplus = "plus_plus" in stem
        is_plus = "plus" in stem and not is_plusplus
        is_ansi = "ansi" in stem

        # Generate new name in the format Ergopti_vx_x_x
        # Base name depending on variant
        if is_plusplus and is_ansi:
            base_name = f"Ergopti_{version_underscore}_plus_plus_ansi"
            variant = "++"
        elif is_plusplus:
            base_name = f"Ergopti_{version_underscore}_plus_plus"
            variant = "++"
        elif is_plus and is_ansi:
            base_name = f"Ergopti_{version_underscore}_plus_ansi"
            variant = "+"
        elif is_plus:
            base_name = f"Ergopti_{version_underscore}_plus"
            variant = "+"
        elif is_ansi:
            base_name = f"Ergopti_{version_underscore}_ansi"
            variant = ""
        else:
            base_name = f"Ergopti_{version_underscore}"
            variant = ""

        new_name = base_name
        display_name = new_name

        # Use the same name for both filename and internal name attribute
        content = re.sub(
            r'(<keyboard\b[^>]*\bname=")([^"]+)(")',
            rf"\1{display_name}\3",
            content,
        )

        # Determine output file name
        dest_filename = f"{new_name}.keylayout"
        dest_layout = resources_path / dest_filename
        dest_layout.write_text(content, encoding="utf-8")

        # Build input source id WITHOUT version suffix. macOS treats two
        # bundles with the same TISInputSourceID as the same input source,
        # so an upgrade of v2.2.1 → v2.2.2 with stable IDs is recognised
        # by the OS as the same layout (the user-enabled set, the active
        # selection, and any layout-specific preferences are preserved).
        if is_plusplus and is_ansi:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plus_plus.ansi"
        elif is_plusplus:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plus_plus"
        elif is_plus and is_ansi:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plus.ansi"
        elif is_plus:
            input_source_id = f"{BUNDLE_IDENTIFIER}.plus"
        elif is_ansi:
            input_source_id = f"{BUNDLE_IDENTIFIER}.ansi"
        else:
            input_source_id = BUNDLE_IDENTIFIER

        # Store variant, ANSI flag, and the canonical input source id used
        # later as the InfoPlist.strings key.
        layout_localization_infos.append(
            (new_name, variant, is_ansi, input_source_id)
        )

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
    clean_version = version.lstrip("v")
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>{BUNDLE_IDENTIFIER}</string>
    <key>CFBundleName</key>
    <string>Ergopti</string>
    <key>CFBundleShortVersionString</key>
    <string>{clean_version}</string>
    <key>CFBundleVersion</key>
    <string>{clean_version}</string>
    {"\n\t".join(entries)}
</dict>
</plist>
"""


def generate_localizations(
    bundle_path: Path,
    version: str,
    layouts: list[tuple[str, str, bool, str]],
):
    """
    Generate localized InfoPlist.strings files (en and fr).

    macOS resolves the layout's display name by looking up the keylayout's
    INTERNAL NAME (the `name=` attribute of the <keyboard> element, which is
    also the basename of the .keylayout file and the suffix used in the
    `KLInfo_<name>` Info.plist key) as the KEY in the bundle's
    `InfoPlist.strings`. Both the working v2.2.1 bundle and the reference
    Optimot bundle follow this convention. An earlier attempt that used the
    TISInputSourceID as the key broke the bundle entirely: macOS could not
    resolve the localised name and silently refused to register the bundle.

    Each layout is mapped to either:
      - "Ergopti v{version}"   (standard)
      - "Ergopti+ v{version}"  (plus)
      - "Ergopti++ v{version}" (plus plus)
    plus an optional " ANSI" suffix.
    """
    for lang in ("en", "fr"):
        lproj_dir = bundle_path / "Contents" / "Resources" / f"{lang}.lproj"
        lproj_dir.mkdir(parents=True, exist_ok=True)
        strings_path = lproj_dir / "InfoPlist.strings"

        lines = []
        for internal_name, variant, is_ansi, _input_source_id in layouts:
            ansi_suffix = " ANSI" if is_ansi else ""
            if variant == "++":
                localized = f"Ergopti++{ansi_suffix} {version}"
            elif variant == "+":
                localized = f"Ergopti+{ansi_suffix} {version}"
            else:
                localized = f"Ergopti{ansi_suffix} {version}"
            # The lookup key MUST be the keylayout's internal name (= the
            # `KLInfo_<name>` suffix). Using the TISInputSourceID here makes
            # macOS reject the bundle entirely.
            lines.append(f'"{internal_name}" = "{localized}";')

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
