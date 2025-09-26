import re
import time
from datetime import datetime

from .logger import logger

LOGS_INDENTATION = "\t"


def generate_compact_id() -> str:
    """
    Generate a compact unique id using the current timestamp in milliseconds, encoded in base36.
    """
    ts = str(int(time.time() * 1000))
    compact_id = ts[-2:]  # Last 2 characters to save space

    return compact_id


def set_unique_keyboard_id(content: str) -> str:
    """
    Replace the id attribute in the <keyboard ...> tag with a compact unique value (base36 timestamp).
    Example: id="kq1z8w2" (base36 encoded milliseconds since epoch)
    Ensures that each generated keylayout has a unique and short id.
    """
    logger.info(
        "%s🔹 Generating a compact unique id for the <keyboard> tag…",
        LOGS_INDENTATION + "\t",
    )
    unique_id = (
        f"-{datetime.now():%y%m%d}{generate_compact_id()}"  # e.g. 250926xx
    )

    def replace_id(match):
        before = match.group(1)
        after = match.group(2)
        return f'{before}id="{unique_id}"{after}'

    new_content, num_subs = re.subn(
        r'(<keyboard[^>]*?)id="[^"]*"([^>]*>)', replace_id, content, count=1
    )
    if num_subs == 0:
        logger.warning(
            "%sNo <keyboard ... id=...> tag found for modification.",
            LOGS_INDENTATION + "\t",
        )
        return content
    logger.success(
        "%sUnique id set for <keyboard>: %s",
        LOGS_INDENTATION + "\t",
        unique_id,
    )
    return new_content
