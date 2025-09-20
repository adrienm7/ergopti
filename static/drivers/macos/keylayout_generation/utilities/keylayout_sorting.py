"""Functions to reorder and sort various parts of a keylayout XML body for consistency and readability."""

import logging
import re
import unicodedata

logger = logging.getLogger("ergopti")
LOGS_INDENTATION = "\t"


def sort_keylayout(content: str) -> str:
    """
    Apply sorting functions to a keylayout content for consistency and readability.
    Returns the sorted content.
    """
    logger.info(f"{LOGS_INDENTATION}🎨 Starting keylayout sorting…")

    content = reorder_modifiers_and_attributes(content)
    content = sort_keymaps(content)
    content = sort_keys(content)
    content = sort_actions(content)
    content = sort_terminators(content)

    logger.success(f"{LOGS_INDENTATION}\tKeylayout sorting complete.")
    return content


def reorder_modifiers_and_attributes(body: str) -> str:
    """Standardize encoding, maxout, and key/modifier orders for cosmetic consistency."""
    logger.info(
        f"{LOGS_INDENTATION}\t🔹 Reordering modifiers and attributes inside modifierMap…"
    )

    # Standardize encoding
    body = body.replace('encoding="utf-8"', 'encoding="UTF-8"')

    # Increase maxout from 1 to 3
    body = re.sub(r'maxout="1"', 'maxout="3"', body)

    # Standardize key orders and specific modifier blocks
    key_replacements = {
        'keys="anyOption caps anyShift"': 'keys="anyShift caps anyOption"',
        'keys="anyOption anyShift"': 'keys="anyShift anyOption"',
        'keys="anyOption caps"': 'keys="caps anyOption"',
        'keys="caps anyShift"': 'keys="anyShift caps"',
        'keys="command caps? anyOption? control?"': 'keys="caps? anyOption? command anyControl?"',
        'keys="control caps? anyOption?"': 'keys="caps? anyOption? anyControl"',
    }
    for old, new in key_replacements.items():
        body = body.replace(old, new)

    return body


def sort_keymaps(body: str) -> str:
    """Sort all <keyMap> blocks numerically by their index inside <keyMapSet>."""
    logger.info(f"{LOGS_INDENTATION}\t🔹 Sorting keyMaps inside keyMapSet…")

    # Function to sort a single <keyMapSet> block
    def sort_block(match):
        header, inner_body, footer = match.groups()

        # Extract all keyMap blocks in the inner body
        keymaps = re.findall(
            r'(<keyMap index="(\d+)">.*?</keyMap>)', inner_body, flags=re.DOTALL
        )
        if not keymaps:
            logger.warning(
                f"{LOGS_INDENTATION}\tNo <keyMap> blocks found in <keyMapSet>."
            )
            return match.group(0)  # Return original block if no keyMaps

        # Sort by index numerically
        keymaps_sorted = sorted(keymaps, key=lambda k: int(k[1]))

        # Rebuild the keyMapSet block
        new_inner_body = "".join("\n\t\t" + k[0] for k in keymaps_sorted)
        return f"{header}{new_inner_body}\n\t{footer}"

    # Replace only the <keyMapSet> block(s) in the full body
    return re.sub(
        r"(<keyMapSet.*?>)(.*?)(</keyMapSet>)",
        sort_block,
        body,
        flags=re.DOTALL,
    )


def sort_keys(body: str) -> str:
    """Sort all <key> elements in each <keyMap> block by their code attribute."""
    logger.info(
        f"{LOGS_INDENTATION}\t🔹 Sorting keys by code inside each keyMap…"
    )

    def sort_block(match):
        header, body, footer = match.groups()
        # Extract all <key .../> elements
        keys = re.findall(r"(\s*<key[^>]+/>)", body)
        # Sort keys numerically by their code attribute
        keys_sorted = sorted(
            keys, key=lambda k: int(re.search(r'code="(\d+)"', k).group(1))
        )
        # Reconstruct the block
        return f"{header}{''.join(keys_sorted)}\n\t\t{footer}"

    return re.sub(
        r'(<keyMap index="\d+">)(.*?)(</keyMap>)',
        sort_block,
        body,
        flags=re.DOTALL,
    )


def sort_key(id_str: str):
    """
    Key function for sorting or comparison:
    - Lowercase letters = 0
    - Uppercase letters = 1
    - Symbols/numbers = 2
    """

    def normalize_id(id_str: str) -> str:
        """
        Normalize ID for sorting:
        - Strip accents to base letters
        - Preserve original case (so lowercase sorts before uppercase)
        """
        nfkd = unicodedata.normalize("NFKD", id_str)
        return "".join([c for c in nfkd if not unicodedata.combining(c)])

    normalized = normalize_id(id_str)
    key = []
    for c in normalized:
        if c.islower():
            key.append((0, c))
        elif c.isupper():
            key.append((1, c))
        else:
            key.append((2, c))
    return tuple(key)


def sort_actions(body: str) -> str:
    """
    Sort all <action> blocks by their id attribute inside <actions> blocks.
    """
    logger.info(
        f"{LOGS_INDENTATION}\t🔹 Sorting actions by id inside <actions> blocks…"
    )

    def sort_block(match):
        header, body_content, footer = match.groups()

        # Extract all <action> blocks
        actions = re.findall(
            r"(\s*<action\b.*?>.*?</action>)", body_content, flags=re.DOTALL
        )

        # Sort by ID using the custom sort_key function
        actions_sorted = sorted(
            actions,
            key=lambda a: sort_key(
                re.search(r'id=["\']([^"\']+)["\']', a).group(1)
            ),
        )

        # Rebuild <actions> block
        return f"{header}{''.join(actions_sorted)}\n\t{footer}"

    # Replace <actions> block in the body
    return re.sub(
        r"(<actions.*?>)(.*?)(</actions>)", sort_block, body, flags=re.DOTALL
    )


def sort_terminators(body: str) -> str:
    """
    Sort the <when .../> lines inside the <terminators> block by the numeric value of state.
    """
    logger.info(f"{LOGS_INDENTATION}\t🔹 Sorting terminators by state…")

    def state_key(line):
        m = re.search(r'state="s(\d+)"', line)
        return int(m.group(1)) if m else 0

    def sort_block(match):
        header, inner, footer = match.groups()
        # Extract all <when .../> lines
        whens = re.findall(r"(\s*<when[^>]+/>)", inner)
        # Sort by state number
        whens_sorted = sorted(whens, key=state_key)
        return f"{header}{''.join(whens_sorted)}\n\t{footer}"

    return re.sub(
        r"(<terminators.*?>)(.*?)(</terminators>)",
        sort_block,
        body,
        flags=re.DOTALL,
    )
