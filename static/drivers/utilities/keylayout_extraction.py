"""
Utility for extracting information from keylayout files.
"""

import re
from pathlib import Path

from .logger import logger

LOGS_INDENTATION = "\t"


def extract_name_from_file(content: str) -> str:
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


def extract_version_from_file(file_path: Path) -> str:
    """Read a file and extract the version string using extract_version.

    Args:
        file_path: Path to the keylayout file.

    Returns:
        The extracted version string, or an empty string if not found.
    """
    content = file_path.read_text(encoding="utf-8")
    return extract_version(content)


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
