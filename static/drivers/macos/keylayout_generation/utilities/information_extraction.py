"""
Utility for extracting information from keylayout files.
"""

import re

from .logger import logger

LOGS_INDENTATION = "\t"


def extract_version_from_file(file_path) -> str:
    """
    Extracts the version string (e.g. v1.2.3, v1.2.3 Beta 2)
    from the name attribute in the given file.
    Returns 'vX.X.X' if not found.
    """

    with file_path.open("r", encoding="utf-8") as f:
        content = f.read()

    name_match = re.search(r'name="([^"]+)"', content)
    if name_match:
        name_value = name_match.group(1)
        # Look for v followed by digit or 'version', then capture up to space, quote or end
        version_match = re.search(
            r"((v\d|version).*)", name_value, re.IGNORECASE
        )
        version = version_match.group(1).strip() if version_match else "vX.X.X"
    else:
        version = "vX.X.X"

    return version


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
    state_indices = [int(m) for m in re.findall(r'state="s(\d+)"', body)]
    next_indices = [int(m) for m in re.findall(r'next="s(\d+)"', body)]

    if state_indices or next_indices:
        max_layer = max(state_indices + next_indices)
    else:
        max_layer = 0

    logger.info("%sLast used layer: s%d", LOGS_INDENTATION + "\t", max_layer)
    return max_layer
