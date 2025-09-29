"""
Utility for modifying information from keylayout files.
"""

import re

LOGS_INDENTATION = "\t"


def modify_name_from_file(content: str, new_name: str) -> str:
    """
    Modifies the name string (e.g. My Key Layout)
    in the name attribute of the given file.
    """

    content = re.sub(r'name="([^"]+)"', f'name="{new_name}"', content)

    return content
