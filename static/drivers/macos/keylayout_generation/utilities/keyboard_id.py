import datetime
import re

from .logger import logger

LOGS_INDENTATION = "\t"


def set_unique_keyboard_id(content: str) -> str:
    """
    Replace the id attribute in the <keyboard ...> tag with a unique value based on the current timestamp.
    Example: id="20250926153045123" (YYYYMMDDHHMMSSmmm)
    Ensures that each generated keylayout has a unique id.
    """
    logger.info(
        "%s🔹 Generating a unique id for the <keyboard> tag…",
        LOGS_INDENTATION + "\t",
    )
    now = datetime.datetime.now()
    unique_id = now.strftime("%Y%m%d%H%M%S%f")[:-3]  # Up to milliseconds

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
        "%sUnique id set for <keyboard>: %s", LOGS_INDENTATION + "\t", unique_id
    )
    return new_content
