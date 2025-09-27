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


def swap_keys(body: str, key1: int, key2: int) -> str:
    """Swap key codes 10 and 50."""
    logger.info(
        "%s🔹 Swapping key codes %d and %d…",
        LOGS_INDENTATION + "\t",
        key1,
        key2,
    )
    body = re.sub(f'code="{key2}"', "TEMP_CODE", body)
    body = re.sub(f'code="{key1}"', f'code="{key2}"', body)
    body = re.sub(r"TEMP_CODE", f'code="{key1}"', body)
    return body


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
