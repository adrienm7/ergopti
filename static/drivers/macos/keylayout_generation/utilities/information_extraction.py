"""
Utility for extracting information from keylayout files.
"""

import re


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
