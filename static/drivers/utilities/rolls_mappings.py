"""
Mappings for the new dead keys of Ergopti+.
"""

import sys
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent.parent))

from collections import OrderedDict
from pprint import pprint

from utilities.logger import logger
from utilities.mappings_functions import (
    add_case_sensitive_mappings,
    escape_symbols_in_mappings,
)

LOGS_INDENTATION = "\t\t"


def load_plus_mappings_config() -> dict:
    """
    Load Ergopti+ mappings configuration from rolls.toml and suffixes.toml files.

    Returns:
        Dictionary containing the merged mappings configuration

    Raises:
        ImportError: If tomllib/tomli is not available
        FileNotFoundError: If any TOML file doesn't exist
        OSError: If there's an error reading the files
    """
    # Try to import TOML parser (Python 3.11+ has tomllib built-in)
    try:
        import tomllib
    except ImportError:
        try:
            import tomli as tomllib
        except ImportError:
            raise ImportError(
                "TOML parser required. Install with 'pip install tomli' for Python < 3.11"
            )

    # Load both TOML configuration files
    config_files = [
        Path(__file__).parent.parent / "configuration" / "apostrophe.toml",
        Path(__file__).parent.parent / "configuration" / "comma.toml",
        Path(__file__).parent.parent / "configuration" / "e_deadkey.toml",
        Path(__file__).parent.parent / "configuration" / "qu.toml",
        Path(__file__).parent.parent / "configuration" / "rolls.toml",
        Path(__file__).parent.parent / "configuration" / "sfb_reduction.toml",
        Path(__file__).parent.parent / "configuration" / "suffixes.toml",
    ]

    merged_toml_data = {}

    for config_file in config_files:
        if not config_file.exists():
            raise FileNotFoundError(
                f"Configuration file not found: {config_file}"
            )

        try:
            with open(config_file, "rb") as f:
                toml_data = tomllib.load(f)
                # Merge the data, with potential conflicts logged
                for section_name, section_data in toml_data.items():
                    if section_name in merged_toml_data:
                        logger.warning(
                            "Section '%s' found in multiple files, merging...",
                            section_name,
                        )
                        # Handle different data types for merging
                        if isinstance(
                            merged_toml_data[section_name], list
                        ) and isinstance(section_data, list):
                            merged_toml_data[section_name].extend(section_data)
                        elif isinstance(
                            merged_toml_data[section_name], dict
                        ) and isinstance(section_data, dict):
                            merged_toml_data[section_name].update(section_data)
                        elif isinstance(
                            merged_toml_data[section_name], list
                        ) and isinstance(section_data, dict):
                            merged_toml_data[section_name].append(section_data)
                        elif isinstance(
                            merged_toml_data[section_name], dict
                        ) and isinstance(section_data, list):
                            # Convert existing dict to list and extend
                            merged_toml_data[section_name] = [
                                merged_toml_data[section_name]
                            ]
                            merged_toml_data[section_name].extend(section_data)
                        else:
                            merged_toml_data[section_name] = section_data
                    else:
                        merged_toml_data[section_name] = section_data

                logger.info("Loaded configuration from: %s", config_file.name)
        except OSError as e:
            raise OSError(
                f"Error reading configuration file {config_file}: {e}"
            )

    # Convert TOML structure to the expected format
    # Group all mappings by trigger character
    trigger_groups = {}

    for section_name, section_data in merged_toml_data.items():
        # Handle case where section_data might be a list
        if isinstance(section_data, list):
            # Merge all objects in the list
            combined_data = {}
            for obj in section_data:
                if isinstance(obj, dict):
                    combined_data.update(obj)
            section_data = combined_data

        # Process each entry in the section
        for key, value_obj in section_data.items():
            # Skip entries we want to filter out
            if key in ["càd", "shàd", "à★"]:
                continue

            if len(key) >= 1:
                trigger = key[0]  # First character is the trigger

                # Only process triggers with length <= 2
                if len(trigger) <= 2:
                    # Determine the remaining part after trigger
                    if section_name == "a_grave_suffixes":
                        # For suffixes, the trigger is 'à' and we keep the full key
                        trigger = "à"
                        remaining = key
                    elif key.startswith(trigger) and len(key) > 1:
                        remaining = key[1:]
                    else:
                        remaining = key

                    # Extract the output value from the TOML object
                    if isinstance(value_obj, dict) and "output" in value_obj:
                        output_value = value_obj["output"]
                    elif isinstance(value_obj, str):
                        output_value = value_obj
                    else:
                        output_value = str(value_obj)

                    # Filter out entries with more than 1 character in remaining part
                    # Deadkeys can only work with single characters
                    if len(remaining) > 1:
                        logger.debug(
                            "Skipping entry '%s' -> '%s' (remaining part '%s' has more than 1 character)",
                            key,
                            output_value,
                            remaining,
                        )
                        continue

                    # Group by trigger
                    if trigger not in trigger_groups:
                        trigger_groups[trigger] = []
                    trigger_groups[trigger].append((remaining, output_value))

    # Convert trigger groups to config format
    config = {}
    for trigger, map_entries in trigger_groups.items():
        # Use trigger as the key directly
        config[trigger] = {
            "trigger": trigger,
            "map": map_entries,
        }

    return config


# Load configuration from TOML files
try:
    PLUS_MAPPINGS_CONFIG = load_plus_mappings_config()
    logger.info(
        "Loaded Ergopti+ mappings configuration from rolls.toml and suffixes.toml files"
    )
except (ImportError, FileNotFoundError, OSError) as e:
    logger.error("Error loading TOML configuration: %s", e)
    logger.info("Falling back to empty configuration")
    # Fallback to empty config if TOML loading fails
    PLUS_MAPPINGS_CONFIG = {}

plus_mappings = PLUS_MAPPINGS_CONFIG.copy()
plus_mappings = add_case_sensitive_mappings(plus_mappings)
plus_mappings = escape_symbols_in_mappings(plus_mappings)


# Custom sort: put mappings whose trigger is a single letter (a-zA-Z) last, others first.
# For single-letter triggers, sort as a, A, b, B, ..., z, Z
def _sort_key(item):
    trigger = item[0]  # The key is now the trigger directly
    is_single_alpha = len(trigger) == 1 and trigger.isalpha()
    if is_single_alpha:
        # Sort by (trigger.lower(), is_uppercase) for a, A, b, B, ...
        # is_uppercase: False (minuscule) avant True (majuscule)
        return (True, (trigger.lower(), trigger.isupper()))
    return (False, trigger)


plus_mappings = OrderedDict(sorted(plus_mappings.items(), key=_sort_key))


def check_duplicate_triggers(mappings_to_check: dict):
    """Check for duplicate trigger characters in the plus_mappings."""
    # Since the keys are now the triggers directly, duplicates would be overwritten automatically
    # But we can still check for potential issues with case sensitivity
    triggers_seen = set()
    for trigger in mappings_to_check.keys():
        if trigger.lower() in triggers_seen and trigger not in triggers_seen:
            logger.warning(
                "%sTrigger '%s' has both uppercase and lowercase variants",
                LOGS_INDENTATION,
                trigger.lower(),
            )
        triggers_seen.add(trigger.lower())
        triggers_seen.add(trigger)

    logger.success(
        "%sProcessed %d unique triggers in the Ergopti+ mappings.",
        LOGS_INDENTATION,
        len(mappings_to_check),
    )


check_duplicate_triggers(plus_mappings)


if __name__ == "__main__":
    pprint(plus_mappings, indent=2, width=120)
