"""
Utility for extracting information from keylayout files.
"""

import html
import re
from pathlib import Path

try:
    from lxml import etree as LET
except ImportError:
    LET = None

from .logger import logger

LOGS_INDENTATION = "\t"


def extract_name(content: str) -> str:
    """
    Extracts the name string (e.g. My Key Layout)
    from the name attribute in the given file.
    Returns 'Unknown' if not found.
    """
    name_match = re.search(r'name="([^"]+)"', content)
    name = name_match.group(1) if name_match else "Unknown"

    return name


def extract_version(content: str) -> str:
    """Extract the version string from a keylayout file content.

    Args:
        content: The content of the keylayout file as a string.

    Returns:
        The extracted version string, or an empty string if not found.
    """
    name_match = re.search(r'name="([^"]+)"', content)
    if name_match:
        name_value = name_match.group(1)
        # Search for ' v' and extract everything after it until the end of the name tag
        v_match = re.search(r"( v.+)$", name_value)
        if v_match:
            return v_match.group(1).strip()
    return ""


def extract_version_enhanced(content: str, keylayout_path: Path = None) -> str:
    """Extract the version string from a keylayout file content or associated version.plist.

    Args:
        content: The content of the keylayout file as a string.
        keylayout_path: Optional path to the keylayout file for version.plist lookup.

    Returns:
        The extracted version string, or an empty string if not found.
    """
    # First try to get version from version.plist if keylayout_path is provided
    if keylayout_path:
        version_from_plist = _extract_version_from_plist(keylayout_path)
        if version_from_plist:
            return version_from_plist

    # Fallback to extracting from keylayout content
    name_match = re.search(r'name="([^"]+)"', content)
    if name_match:
        name_value = name_match.group(1)

        # Try multiple patterns for version extraction:
        # 1. Pattern like "Ergopti v2.1.3", "Ergopti v2.2.0 Beta 4"
        v_match = re.search(r"\bv(.+)$", name_value)
        if v_match:
            version_part = v_match.group(1).strip()
            # Remove " Plus", " Plus Plus" suffixes if present
            version_part = re.sub(r"\s+Plus(?:\s+Plus)?$", "", version_part)
            return f"v{version_part}"

        # 2. Pattern like "Ergopti_v2_2_0", "Ergopti_v2_2_0_plus"
        v_underscore_match = re.search(r"_v(\d+(?:_\d+)*)", name_value)
        if v_underscore_match:
            version_part = v_underscore_match.group(1)
            # Convert underscores to dots for display
            version_part = version_part.replace("_", ".")
            return f"v{version_part}"

    return ""


def _extract_version_from_plist(keylayout_path: Path) -> str:
    """Extract version from version.plist file in bundle structure.

    Args:
        keylayout_path: Path to the keylayout file.

    Returns:
        Version string with 'v' prefix, or empty string if not found.
    """
    try:
        # Look for version.plist in bundle structure
        # keylayout_path should be like: .../Ergopti_v2.2.0.bundle/Contents/Resources/file.keylayout
        current_path = keylayout_path.parent
        version_plist_path = None

        # Search upward for version.plist in bundle structure
        for _ in range(3):  # Limit search depth
            potential_plist = current_path / "version.plist"
            if potential_plist.exists():
                version_plist_path = potential_plist
                break
            current_path = current_path.parent
            if current_path.name.endswith(".bundle"):
                # Try Contents/ directory in bundle
                bundle_version_plist = (
                    current_path / "Contents" / "version.plist"
                )
                if bundle_version_plist.exists():
                    version_plist_path = bundle_version_plist
                    break

        if not version_plist_path:
            return ""

        # Parse the plist file
        import xml.etree.ElementTree as ET

        tree = ET.parse(version_plist_path)
        root = tree.getroot()

        # Find the BuildVersion or SourceVersion key
        dict_elem = root.find(".//dict")
        if dict_elem is not None:
            keys = dict_elem.findall("key")
            strings = dict_elem.findall("string")

            for i, key in enumerate(keys):
                if key.text in ["BuildVersion", "SourceVersion"] and i < len(
                    strings
                ):
                    version = strings[i].text.strip()
                    if version:
                        # Add 'v' prefix if not present
                        if not version.startswith("v"):
                            version = f"v{version}"
                        return version

    except Exception as e:
        logger.debug("Could not extract version from plist: %s", e)

    return ""


def extract_version_from_file(file_path: Path) -> str:
    """Read a file and extract the version string using extract_version.

    Args:
        file_path: Path to the keylayout file.

    Returns:
        The extracted version string, or an empty string if not found.
    """
    content = file_path.read_text(encoding="utf-8")
    return extract_version(content)


def extract_version_from_file_enhanced(file_path: Path) -> str:
    """Read a file and extract the version string using extract_version_enhanced.

    Args:
        file_path: Path to the keylayout file.

    Returns:
        The extracted version string, or an empty string if not found.
    """
    content = file_path.read_text(encoding="utf-8")
    return extract_version_enhanced(content, file_path)


def extract_keymap_body(body: str, index: int) -> str:
    """Extract only the inner body of a keyMap by index."""
    logger.info(
        "%s🔹 Extracting body of keymap %d…", LOGS_INDENTATION + "\t", index
    )
    match = re.search(
        rf'<keyMap index="{index}">(.*?)</keyMap>',
        body,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1)


def extract_actions_body(body: str) -> str:
    """Extract the <actions>...</actions> block from a keylayout file body.

    Returns the inner content of the actions element (not including the
    surrounding tags) or an empty string if not present.
    """
    match = re.search(r"<actions>(.*?)</actions>", body, flags=re.DOTALL)
    if not match:
        return ""
    return match.group(1)


def get_last_used_layer(body: str) -> int:
    """
    Scan the keylayout body to find the highest layer number in use.
    Returns this number (not the next available one).
    Useful to get the last used layer, then add +1 if needed.
    """
    logger.info("%sScanning for last used layer…", LOGS_INDENTATION + "\t")

    # Find all numbers in 'state="sX"' and 'next="sX"'
    state_indices = [int(m) for m in re.findall(r'state="s(\d+)', body)]
    next_indices = [int(m) for m in re.findall(r'next="s(\d+)', body)]

    if state_indices or next_indices:
        max_layer = max(state_indices + next_indices)
    else:
        max_layer = 0

    logger.info("%sLast used layer: s%d", LOGS_INDENTATION + "\t", max_layer)
    return max_layer


def get_symbol(keymap_body: str, macos_code: int, actions_body: str) -> str:
    """Extract the symbol (output or action) for a given macOS key code
    in a keyMap body.

    Simplified behavior:
    - If the <key ... output="..."> attribute exists for the macOS code,
      return the unescaped output.
    - If the key uses action="NAME":
        - if an <action name="NAME"> block exists in `actions_body` and
          it contains a `<when state="none" output="..."/>`, return that
          unescaped output;
        - otherwise return the action name ( NAME ).
    """
    match = re.search(
        rf'<key[^>]*code="{macos_code}"[^>]*\b(output|action)="([^"]+)"',
        keymap_body,
    )
    if not match:
        return ""

    kind = match.group(1)
    value = html.unescape(match.group(2))

    if kind == "output":
        return value

    # kind == 'action'
    action_name = value
    if not actions_body:
        return action_name

    # Find the action block and look for when state="none"
    action_block_re = (
        rf'<action[^>]*id="{re.escape(action_name)}"[^>]*>(.*?)</action>'
    )
    action_block = re.search(action_block_re, actions_body, flags=re.DOTALL)
    if not action_block:
        return action_name

    action_inner = action_block.group(1)
    when_none = re.search(
        r'<when[^>]*state="none"[^>]*output="([^"]+)"',
        action_inner,
    )
    if when_none:
        return html.unescape(when_none.group(1))

    return action_name
