"""
Keylayout Plus generation utilities for Ergopti:
create a variant with extra dead key features and symbol modifications.
"""

from configuration.keylayout_plus_mappings import plus_mappings
from data.lists import EXTRA_KEYS
from tests.run_all_tests import validate_keylayout
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_extraction import (
    extract_version,
    get_last_used_layer,
)
from utilities.keylayout_modification import modify_name_from_file
from utilities.keylayout_sorting import sort_keylayout
from utilities.layer_names import create_layer_name
from utilities.logger import logger
from utilities.output_action_modification import (
    add_action_when_state,
    add_terminator_state,
    assign_layer_to_action_block_none,
    ensure_action_block_exists,
    ensure_key_uses_action_and_not_output,
)
from utilities.output_modification import replace_action_to_output_extra_keys

LOGS_INDENTATION = "\t"


def create_keylayout_plus_plus(content: str):
    """
    Create a '_plus' variant of the plus keylayout, with extra dead keys.
    """
    logger.info("%s🔧 Starting keylayout plus plus creation…", LOGS_INDENTATION)

    version = extract_version(content)
    content = modify_name_from_file(content, f"Ergopti++ {version}")

    logger.info(
        "%s➕ Adding dead key features for Ergopti++…",
        LOGS_INDENTATION,
    )
    start_layer = get_last_used_layer(content) + 1

    for i, (feature, data) in enumerate(plus_mappings.items()):
        layer_number = start_layer + i
        trigger_key = data["trigger"]
        layer_name = create_layer_name(layer_number, trigger_key)
        logger.info(
            "%s🔹 Adding feature '%s' with trigger '%s' at layer %s…",
            LOGS_INDENTATION + "\t",
            feature,
            trigger_key,
            layer_name,
        )

        if not data["map"]:
            continue

        # Create the new dead key
        content = ensure_key_uses_action_and_not_output(
            content, trigger_key, EXTRA_KEYS
        )
        content = ensure_action_block_exists(content, trigger_key)
        content = assign_layer_to_action_block_none(
            content, trigger_key, layer_name
        )
        content = add_terminator_state(content, trigger_key, layer_name)

        # Add all dead key outputs
        for trigger, output in data["map"]:
            logger.debug(
                "%s— Adding output '%s' + '%s' ➜ '%s'…",
                LOGS_INDENTATION + "\t\t",
                trigger_key,
                trigger,
                output,
            )

            # Ensure any <key ... output="trigger"> is converted to action="trigger"
            # This is necessary, otherwise the key will always have the same output, despite being in a dead key layer
            content = ensure_key_uses_action_and_not_output(
                content, trigger, EXTRA_KEYS
            )

            # Add the new output on the key when in the dead key layer
            content = add_action_when_state(
                content, trigger, layer_name, output
            )

    content = replace_action_to_output_extra_keys(content, EXTRA_KEYS)
    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content, 3)

    validate_keylayout(content)

    logger.success("Keylayout plus plus creation complete.")
    return content
