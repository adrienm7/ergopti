import os
import re
import shutil
import zipfile
from pathlib import Path

bundle_identifier = "com.apple.com.keyboardlayout.ergopti"


def create_bundle(
    version: str,
    output_dir: Path,
    keylayout_paths: list[Path],
    logo_paths: list[Path],
    cleanup: bool = True,
):
    """
    Create a .bundle package for macOS keyboard layouts.
    keylayout_paths and logo_paths must be lists of the same length.
    Localized layout names (per-layout) are written into InfoPlist.strings
    so that each layout display name can be replaced by "Ergopti v{version}"
    or "Ergopti+ v{version}" for plus layouts.
    """
    if len(keylayout_paths) != len(logo_paths):
        raise ValueError(
            "keylayout_paths and logo_paths must have the same length"
        )

    base_dir = (
        output_dir.resolve() if output_dir else Path(__file__).parent.resolve()
    )
    bundle_name = f"Ergopti_{version}.bundle"
    bundle_path = base_dir / bundle_name

    if bundle_path.exists():
        shutil.rmtree(bundle_path)

    resources_path = bundle_path / "Contents" / "Resources"
    resources_path.mkdir(parents=True, exist_ok=True)

    info_plist_entries = []
    # store tuples (original_display_name, is_plus)
    layout_localization_infos: list[tuple[str, bool]] = []

    for keylayout, logo in zip(keylayout_paths, logo_paths):
        if not keylayout.exists():
            raise FileNotFoundError(f"Keylayout file not found: {keylayout}")
        if not logo.exists():
            print(f"\t⚠️ Logo file not found: {logo}, continuing without it")
            logo_path_to_use = None
        else:
            logo_path_to_use = logo

        # read keylayout to extract original display name if present
        content = keylayout.read_text(encoding="utf-8")
        m = re.search(r'<keyboard\b[^>]*\bname="([^"]+)"', content)
        original_name = m.group(1) if m else keylayout.stem

        # determine plus vs standard (check both stem and original name)
        is_plus = ("plus" in keylayout.stem.lower()) or (
            "plus" in original_name.lower()
        )
        layout_localization_infos.append((original_name, is_plus))

        # copy keylayout file
        dest_layout = resources_path / keylayout.name
        shutil.copy(keylayout, dest_layout)

        # copy logo file and rename to match keylayout stem if available
        icon_tag = ""
        if logo_path_to_use:
            dest_logo = resources_path / f"{keylayout.stem}.icns"
            shutil.copy(logo_path_to_use, dest_logo)
            icon_tag = f"""
            <key>TISIconIsTemplate</key>
            <false/>
            <key>ICNS</key>
            <string>{dest_logo.name}</string>"""
            print(f"\tAdded logo {logo_path_to_use.name} as {dest_logo.name}")

        plist_key = f"KLInfo_{keylayout.stem}"
        input_source_id = (
            f"{bundle_identifier}.plus" if is_plus else bundle_identifier
        )

        info_plist_entries.append(f"""<key>{plist_key}</key>
        <dict>
            <key>TICapsLockLanguageSwitchCapable</key>
            <true/>{icon_tag}
            <key>TISInputSourceID</key>
            <string>{bundle_identifier}{".plus" if is_plus else ""}</string>
            <key>TISIntendedLanguage</key>
            <string>fr</string>
        </dict>""")

    # Write Info.plist
    info_plist_content = generate_info_plist(version, info_plist_entries)
    info_plist_path = bundle_path / "Contents" / "Info.plist"
    info_plist_path.write_text(info_plist_content, encoding="utf-8")

    # Write localized InfoPlist.strings that map original layout names to Ergopti v{version} / Ergopti+ v{version}
    generate_localizations(bundle_path, version, layout_localization_infos)

    # Write version.plist
    version_plist_content = generate_version_plist(version)
    version_plist_path = bundle_path / "Contents" / "version.plist"
    version_plist_path.write_text(version_plist_content, encoding="utf-8")

    # Zip the bundle
    zip_path = None
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
    <string>{bundle_identifier}</string>
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
    Each original layout name is mapped to either:
      - "Ergopti v{version}"  (standard)
      - "Ergopti+ v{version}" (plus)
    Both English and French files receive the same mappings.
    """
    for lang in ("en", "fr"):
        lproj_dir = bundle_path / "Contents" / "Resources" / f"{lang}.lproj"
        lproj_dir.mkdir(parents=True, exist_ok=True)
        strings_path = lproj_dir / "InfoPlist.strings"

        lines = []
        for original_name, is_plus in layouts:
            localized = (
                f"Ergopti+ v{version}" if is_plus else f"Ergopti v{version}"
            )
            # ensure quotes inside original_name are escaped
            escaped_original = original_name.replace('"', '\\"')
            escaped_localized = localized.replace('"', '\\"')
            lines.append(f'"{escaped_original}" = "{escaped_localized}";')

        strings_content = "\n".join(lines) + "\n"
        # write as UTF-16 for macOS compatibility (includes BOM)
        strings_path.write_text(strings_content, encoding="utf-16")
        print(f"\t🌍 Added localization mappings for {lang}: {strings_path}")


def generate_version_plist(version: str) -> str:
    """Generate the version.plist content dynamically."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BuildVersion</key>
    <string>{version}</string>
    <key>ProjectName</key>
    <string>Ergopti</string>
    <key>SourceVersion</key>
    <string>{version}</string>
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
    print(f"\t📦 Zipped bundle at: {zip_path}")
