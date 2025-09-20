"""Tests for validating a keylayout."""

import logging
import re

logger = logging.getLogger("ergopti")
LOGS_INDENTATION = "\t"


def check_each_action_in_keymaps_defined_in_actions(body: str) -> None:
    """
    Ensure that all action names used in keyMaps are defined as <action id="..."> in <actions>.
    Raises ValueError if any keyMap action is missing in <actions>.
    Displays all missing action references.
    """
    logger.info(
        f"{LOGS_INDENTATION}\t🔹 Checking that all keyMap actions exist in <actions>…"
    )

    # Extract all action IDs defined in <actions>
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        logger.warning(
            f"{LOGS_INDENTATION}\t\t️  No <actions> block found, skipping."
        )
        return

    _, actions_body, _ = actions_match.groups()
    defined_actions = set(re.findall(r'id=["\']([^"\']+)["\']', actions_body))

    missing_actions_found = {}

    # Iterate over each <keyMap> block
    for keymap_match in re.finditer(
        r"<keyMap[^>]*>(.*?)</keyMap>", body, flags=re.DOTALL
    ):
        keymap_block = keymap_match.group(0)
        index_match = re.search(r'index=["\']([^"\']+)["\']', keymap_block)
        keymap_label = (
            f'index="{index_match.group(1)}"' if index_match else "<unknown>"
        )

        # Find all <key> elements with an action attribute
        keys_with_action = re.findall(
            r'(<key[^>]*action=["\']([^"\']+)["\'][^>]*/>)', keymap_block
        )

        for full_tag, action_name in keys_with_action:
            if action_name not in defined_actions:
                missing_actions_found.setdefault(keymap_label, []).append(
                    full_tag
                )

    if missing_actions_found:
        logger.info(
            f"{LOGS_INDENTATION}\tKeyMap actions not defined in <actions> detected:"
        )
        for keymap_name, tags in missing_actions_found.items():
            logger.info(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for tag in tags:
                logger.info(f"{LOGS_INDENTATION}\t\t\t— {tag.strip()}")
        raise ValueError("Some keyMap actions are missing in <actions>.")

    logger.success(
        f"{LOGS_INDENTATION}\t\tAll keyMap actions are defined in <actions>."
    )


def check_each_action_in_keymaps_is_used(body: str) -> None:
    """
    Ensure that every <action id="..."> in <actions> is referenced by at least one <key> in keyMaps.
    """
    logger.info(
        f"{LOGS_INDENTATION}\t🔹 Checking that all <actions> are used in keyMaps…"
    )

    # Extract the <actions> block
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        logger.warning(
            f"{LOGS_INDENTATION}\t\t️  No <actions> block found, skipping."
        )
        return

    _, actions_body, _ = actions_match.groups()

    # Find all <action> blocks and map them by id
    action_blocks = re.findall(
        r"(\s*<action\b.*?>.*?</action>)", actions_body, flags=re.DOTALL
    )
    defined_actions = {
        re.search(r'id=["\']([^"\']+)["\']', blk).group(1): blk
        for blk in action_blocks
    }

    # Find all actions used in keyMaps
    used_action_matches = re.findall(
        r'<key[^>]*action=["\']([^"\']+)["\'][^>]*/>', body
    )
    used_actions = set(used_action_matches)

    # Detect unused actions
    unused_action_ids = set(defined_actions.keys()) - used_actions

    if unused_action_ids:
        logger.error(f"{LOGS_INDENTATION}\tUnused <action> blocks detected:")
        for action_id in unused_action_ids:
            logger.error(
                f"{LOGS_INDENTATION}\t\t— {defined_actions[action_id].strip()}"
            )

    logger.success(
        f"{LOGS_INDENTATION}\t\tAll <action> blocks are used in keyMaps."
    )
