"""Tests for validating a keylayout."""

import logging

from .tests_cosmetic import (
    check_ascending_actions,
    check_ascending_keymaps,
    check_ascending_keys_in_keymaps,
    check_attribute_order,
    check_indentation_consistency,
    check_no_empty_lines,
)
from .tests_cross_references import (
    check_each_action_in_keymaps_defined_in_actions,
    check_each_action_in_keymaps_is_used,
)
from .tests_logic import (
    check_each_action_has_when_state_none,
    check_each_action_when_states_unique,
    check_each_when_has_output_or_next,
    check_terminators_when_states_unique,
    check_when_states_defined_in_terminators,
)
from .tests_presence_uniqueness import (
    check_each_action_has_id,
    check_each_key_has_a_code,
    check_each_key_has_either_output_or_action,
    check_unique_action_ids,
    check_unique_codes_in_keymaps,
    check_unique_keymap_indices,
)
from .tests_structure_syntax import (
    check_consistent_attribute_quotes,
    check_forbidden_empty_attribute_values,
    check_forbidden_tags_or_attributes,
    check_max_min_code_state_values,
    check_required_blocks_present,
    check_valid_xml_structure,
    check_xml_attribute_errors,
)

logger = logging.getLogger("ergopti")
LOGS_INDENTATION = "\t"


def validate_keylayout(content: str) -> None:
    """
    Run all validation checks on the provided keylayout content.
    Raises ValueError if any check fails.
    """
    logger.launch(f"{LOGS_INDENTATION}🔎 Validating keylayout…")

    logger.info(f"{LOGS_INDENTATION}=== XML structure & syntax checks ===")
    check_valid_xml_structure(content)
    check_required_blocks_present(content)
    check_forbidden_tags_or_attributes(content)
    check_forbidden_empty_attribute_values(content)
    check_consistent_attribute_quotes(content)
    check_xml_attribute_errors(content)
    check_max_min_code_state_values(content)

    logger.info(
        f"{LOGS_INDENTATION}=== Key & Action presence/uniqueness checks ==="
    )
    check_each_key_has_a_code(content)
    check_each_action_has_id(content)
    check_unique_keymap_indices(content)
    check_unique_codes_in_keymaps(content)
    check_unique_action_ids(content)
    check_each_key_has_either_output_or_action(content)

    logger.info(f"{LOGS_INDENTATION}=== Action & KeyMap cross-references ===")
    check_each_action_in_keymaps_defined_in_actions(content)
    check_each_action_in_keymaps_is_used(content)

    logger.info(
        f"{LOGS_INDENTATION}=== Action/When/Terminator logic checks ==="
    )
    check_each_action_has_when_state_none(content)
    check_each_action_when_states_unique(content)
    check_terminators_when_states_unique(content)
    check_when_states_defined_in_terminators(content)
    check_each_when_has_output_or_next(content)

    logger.info(f"{LOGS_INDENTATION}=== Cosmetic & ordering checks ===")
    check_indentation_consistency(content)
    check_no_empty_lines(content)
    check_ascending_keymaps(content)
    check_ascending_keys_in_keymaps(content)
    check_ascending_actions(content)
    check_attribute_order(content)

    logger.success(f"{LOGS_INDENTATION}Keylayout validation passed.")
