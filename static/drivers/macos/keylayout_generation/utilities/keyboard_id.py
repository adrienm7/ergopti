import re
import time
from datetime import datetime

from .logger import logger

LOGS_INDENTATION = "\t"


def generate_compact_id() -> str:
    """
    Generate a compact unique id using the current timestamp in milliseconds, encoded in base36.
    """
    ts = int(time.time() * 1000)
    chars = "0123456789abcdefghijklmnopqrstuvwxyz"
    base36 = ""

    while ts:
        ts, i = divmod(ts, 36)
        base36 = chars[i] + base36

    return base36[:2]  # First 2 characters to save space


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
    unique_id = f"{datetime.now():%Y%m%d}{generate_compact_id()}"

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
