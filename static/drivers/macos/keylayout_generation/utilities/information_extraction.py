"""
Utility for extracting information from keylayout files.
"""

import re


def extract_version_from_file(file_path) -> str:
    """
    Extracts the version string (e.g. v1.2.3, v1.2.3 Beta 2) from the name attribute in the given file.
    Returns 'vX.X.X' if not found.
    """

    with file_path.open("r", encoding="utf-8") as f:
        content = f.read()
        # Capture everything after " v" up to the next quote in the name attribute
        match = re.search(r'name="[^"]* (v[^"]+)"', content)
        version = match.group(1).strip() if match else "vX.X.X"
    return version
