"""
Keylayout Plus generation utilities for Ergopti:
create a variant with extra dead key features and symbol modifications.
"""

from tests.run_all_tests import validate_keylayout
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_extraction import extract_name
from utilities.keylayout_modification import (
    modify_name_from_file,
    swap_keys,
)
from utilities.keylayout_sorting import sort_keylayout
from utilities.logger import logger

LOGS_INDENTATION = "\t"


def create_keylayout_ansi(content: str, variant_number: int):
    """
    Create an 'ANSI' variant of a corrected keylayout.
    """
    logger.info("%s🔧 Starting keylayout ANSI creation…", LOGS_INDENTATION)

    name = extract_name(content)
    content = modify_name_from_file(content, f"{name} ANSI")

    logger.info(
        "%s➕ Swapping keys for ANSI layout…",
        LOGS_INDENTATION,
    )
    content = swap_keys(content, 10, 50)  # Swap ê and $
    content = swap_keys(content, 42, 30)  # Swap dead keys ¨ and ^

    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content, variant_number)

    validate_keylayout(content)

    logger.success("Keylayout plus creation complete.")
    return content
