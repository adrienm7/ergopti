"""Functions to correct and modify a keylayout content."""

import re

from data.lists import EXTRA_KEYS
from tests.run_all_tests import validate_keylayout
from utilities.keyboard_id import set_unique_keyboard_id
from utilities.keylayout_extraction import extract_keymap_body
from utilities.keylayout_modification import (
    delete_keymap,
    replace_keymap,
    replace_keymapselect,
    replace_keymapset_id_with_layout,
    replace_modifier_map_id,
    swap_keys,
)
from utilities.keylayout_sorting import sort_keylayout
from utilities.layer_names import replace_layer_names_in_file
from utilities.logger import logger
from utilities.output_action_modification import (
    convert_actions_to_outputs,
)
from utilities.output_modification import (
    fix_ctrl_symbols,
    modify_accented_letters_shortcuts,
    normalize_attribute_entities,
    replace_action_to_output_extra_keys,
)

LOGS_INDENTATION = "\t"


KEYMAPSELECT_MAPINDEX_4 = (
    '<keyMapSelect mapIndex="4">\n'
    '\t\t\t<modifier keys="anyControl anyOption? anyShift? caps? command?"/>\n'
    '\t\t\t<modifier keys="anyControl? anyOption? anyShift? caps? command"/>\n'
    "\t\t</keyMapSelect>"
)


KEYMAPSELECT_MAPINDEX_5 = (
    '<keyMapSelect mapIndex="5">\n'
    '\t\t\t<modifier keys="anyOption caps?"/>\n'
    "\t\t</keyMapSelect>"
)


KEYMAPSELECT_MAPINDEX_6 = (
    '<keyMapSelect mapIndex="6">\n'
    '\t\t\t<modifier keys="anyOption anyShift caps?"/>\n'
    "\t\t</keyMapSelect>"
)


def correct_keylayout(content: str, variant_number: int) -> str:
    """
    Apply all necessary corrections and modifications to a keylayout content.
    Returns the fully corrected content.
    """
    logger.info("%s🔧 Starting keylayout corrections…", LOGS_INDENTATION)

    logger.info("%s🔹 Removing XML comments…", LOGS_INDENTATION + "\t")
    content = re.sub(r"<!--.*?-->\n", "", content, flags=re.DOTALL)

    logger.info(
        "%s🔹 Removing empty lines at start and end…", LOGS_INDENTATION + "\t"
    )
    content = re.sub(r"^(\s*\n)+|((\s*\n)+)$", "", content)

    content = replace_keymapselect(content, 4, KEYMAPSELECT_MAPINDEX_4)
    content = replace_keymapselect(content, 5, KEYMAPSELECT_MAPINDEX_5)
    content = replace_keymapselect(content, 6, KEYMAPSELECT_MAPINDEX_6)

    content = delete_keymap(content, 7)
    content = delete_keymap(content, 8)

    content = replace_modifier_map_id(content)
    content = replace_keymapset_id_with_layout(content)

    content = normalize_attribute_entities(content)
    content = replace_action_to_output_extra_keys(content, EXTRA_KEYS)
    content = replace_layer_names_in_file(content)
    content = swap_keys(content, 10, 50)

    logger.info(
        "%s➕ Modifying keymap 4 (Ctrl/Command/etc.)…", LOGS_INDENTATION
    )
    keymap_0_content = extract_keymap_body(content, 0)
    keymap_content = modify_accented_letters_shortcuts(keymap_0_content)
    keymap_content = fix_ctrl_symbols(keymap_content)
    keymap_content = convert_actions_to_outputs(
        keymap_content
    )  # Ctrl shortcuts can be directly set to output, as they don’t trigger other states
    content = replace_keymap(content, 4, keymap_content)

    content = sort_keylayout(content)
    content = set_unique_keyboard_id(content, variant_number)
    validate_keylayout(content)

    logger.info("Keylayout corrections complete.")
    return content
