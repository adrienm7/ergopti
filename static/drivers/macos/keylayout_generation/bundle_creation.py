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
    for keylayout, logo in zip(keylayout_paths, logo_paths):
        if not keylayout.exists():
            raise FileNotFoundError(f"Keylayout file not found: {keylayout}")
        if not logo.exists():
            print(f"\t⚠️ Logo file not found: {logo}, continuing without it")
            logo_path_to_use = None
        else:
            logo_path_to_use = logo

        # Copier le keylayout
        dest_layout = resources_path / keylayout.name
        shutil.copy(keylayout, dest_layout)

        # Copier le logo et renommer pour correspondre au keylayout
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
        info_plist_entries.append(f"""<key>{plist_key}</key>
        <dict>
            <key>TICapsLockLanguageSwitchCapable</key>
            <true/>{icon_tag}
            <key>TISInputSourceID</key>
            <string>{bundle_identifier}.{"plus" if "plus" in keylayout.stem.lower() else "standard"}</string>
            <key>TISIntendedLanguage</key>
            <string>fr</string>
        </dict>""")

    # Write Info.plist
    info_plist_content = generate_info_plist(version, info_plist_entries)
    info_plist_path = bundle_path / "Contents" / "Info.plist"
    info_plist_path.write_text(info_plist_content, encoding="utf-8")

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


def copy_keylayout_and_logo(
    src: Path, base_dir: Path, resources_path: Path
) -> str:
    """Copy the keylayout and its logo, renaming the logo to match the keylayout filename."""

    # Copy keylayout file
    dest_layout = resources_path / src.name
    shutil.copy(src, dest_layout)

    # Determine logo to use based on keyboard name containing "plus" (case-insensitive)
    content = src.read_text(encoding="utf-8")
    match = re.search(r'<keyboard\b[^>]*\bname="([^"]+)"', content)
    keyboard_name_in_xml = match.group(1) if match else src.stem

    if "plus" in keyboard_name_in_xml.lower():
        logo_filename = "logo_ergopti_plus.icns"
    else:
        logo_filename = "logo_ergopti.icns"

    logo_path = base_dir / logo_filename
    if logo_path.exists():
        # Rename logo to match keylayout filename
        dest_logo = resources_path / f"{src.stem}.icns"
        shutil.copy(logo_path, dest_logo)
        icon_tag = f"""
        <key>TISIconIsTemplate</key>
        <false/>
        <key>ICNS</key>
        <string>{dest_logo.name}</string>"""
        print(f"Added logo {logo_filename} as {dest_logo.name}")
    else:
        print(f"⚠️ Logo file not found: {logo_filename}, continuing without it")
        icon_tag = ""

    # Use keylayout filename as the plist key
    plist_key = f"KLInfo_{src.stem}"

    # Generate Info.plist entry
    return f"""
    <key>{plist_key}</key>
    <dict>
        <key>TICapsLockLanguageSwitchCapable</key>
        <true/>{icon_tag}
        <key>TISInputSourceID</key>
        <string>{bundle_identifier}.{src.stem.lower()}</string>
        <key>TISIntendedLanguage</key>
        <string>fr</string>
    </dict>"""


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
                # Relative path from the parent of the bundle folder to keep the bundle folder itself
                relative_path = file_path.relative_to(bundle_path.parent)
                zipf.write(file_path, relative_path)
    print(f"\t📦 Zipped bundle at: {zip_path}")
