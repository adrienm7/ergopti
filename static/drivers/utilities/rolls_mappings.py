"""
Mappings for the new dead keys of Ergopti+.
"""

import sys
import tomllib
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent.parent))

from collections import OrderedDict, defaultdict
from pprint import pprint

from utilities.logger import logger
from utilities.mappings_functions import (
    add_case_sensitive_mappings,
    escape_symbols_in_mappings,
)

LOGS_INDENTATION = "\t\t"


def _get_config_files() -> list[Path]:
    """Get list of configuration files to load."""
    config_dir = Path(__file__).parent.parent / "configuration"
    filenames = [
        "apostrophe.toml",
        "comma.toml",
        "e_deadkey.toml",
        "qu.toml",
        "rolls.toml",
        "sfb_reduction.toml",
        "suffixes.toml",
    ]
    return [config_dir / filename for filename in filenames]


def _merge_section_data(existing_data, new_data):
    """Merge two section data objects based on their types."""
    if isinstance(existing_data, list) and isinstance(new_data, list):
        existing_data.extend(new_data)
    elif isinstance(existing_data, dict) and isinstance(new_data, dict):
        existing_data.update(new_data)
    elif isinstance(existing_data, list) and isinstance(new_data, dict):
        existing_data.append(new_data)
    elif isinstance(existing_data, dict) and isinstance(new_data, list):
        return [existing_data] + new_data
    else:
        return new_data
    return existing_data


def _load_toml_files(config_files: list[Path]) -> dict:
    """Load and merge all TOML configuration files."""
    merged_data = {}

    for config_file in config_files:
        if not config_file.exists():
            raise FileNotFoundError(
                f"Configuration file not found: {config_file}"
            )

        try:
            with open(config_file, "rb") as f:
                toml_data = tomllib.load(f)

                for section_name, section_data in toml_data.items():
                    if section_name in merged_data:
                        logger.warning(
                            "Section '%s' found in multiple files, merging...",
                            section_name,
                        )
                        merged_data[section_name] = _merge_section_data(
                            merged_data[section_name], section_data
                        )
                    else:
                        merged_data[section_name] = section_data

                logger.info("Loaded configuration from: %s", config_file.name)
        except OSError as e:
            raise OSError(
                f"Error reading configuration file {config_file}: {e}"
            ) from e

    return merged_data


def _extract_output_value(value_obj):
    """Extract output value from TOML object."""
    if isinstance(value_obj, dict) and "output" in value_obj:
        return value_obj["output"]
    elif isinstance(value_obj, str):
        return value_obj
    else:
        return str(value_obj)


def _process_section_data(section_data):
    """Convert section data to dictionary if it's a list."""
    if isinstance(section_data, list):
        combined_data = {}
        for obj in section_data:
            if isinstance(obj, dict):
                combined_data.update(obj)
        return combined_data
    return section_data


def _should_skip_entry(key: str) -> bool:
    """Check if entry should be skipped."""
    return key in ["càd", "shàd", "à★"]


def _get_trigger_and_remaining(key: str, section_name: str) -> tuple[str, str]:
    """Extract trigger and remaining characters from key."""
    if section_name == "a_grave_suffixes":
        return "à", key

    trigger = key[0]
    if key.startswith(trigger) and len(key) > 1:
        remaining = key[1:]
    else:
        remaining = key

    return trigger, remaining


def _process_mappings(merged_toml_data: dict) -> dict:
    """Process TOML data and convert to trigger groups."""
    trigger_groups = defaultdict(list)

    for section_name, section_data in merged_toml_data.items():
        section_data = _process_section_data(section_data)

        for key, value_obj in section_data.items():
            if _should_skip_entry(key):
                continue

            trigger, remaining = _get_trigger_and_remaining(key, section_name)

            # Only process triggers with length <= 2 and remaining with length <= 1
            if len(trigger) <= 2 and len(remaining) <= 1:
                output_value = _extract_output_value(value_obj)
                trigger_groups[trigger].append((remaining, output_value))
            else:
                output_value = _extract_output_value(value_obj)
                logger.debug(
                    "Skipping entry '%s' -> '%s' (trigger: '%s', remaining: '%s')",
                    key,
                    output_value,
                    trigger,
                    remaining,
                )

    # Convert to config format
    return {
        trigger: {"trigger": trigger, "map": map_entries}
        for trigger, map_entries in trigger_groups.items()
    }


def load_plus_mappings_config() -> dict:
    """
    Load Ergopti+ mappings configuration from TOML files.

    Returns:
        Dictionary containing the merged mappings configuration

    Raises:
        ImportError: If tomllib/tomli is not available
        FileNotFoundError: If any TOML file doesn't exist
        OSError: If there's an error reading the files
    """
    config_files = _get_config_files()
    merged_toml_data = _load_toml_files(config_files)
    return _process_mappings(merged_toml_data)


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


def _sort_key(item):
    """Sort key: alphabetic triggers last (a, A, b, B, ...), others first."""
    trigger = item[0]
    is_single_alpha = len(trigger) == 1 and trigger.isalpha()

    if is_single_alpha:
        return (True, trigger.lower(), trigger.isupper())
    return (False, trigger)


plus_mappings = OrderedDict(sorted(plus_mappings.items(), key=_sort_key))


def check_duplicate_triggers(mappings_to_check: dict):
    """Check for duplicate trigger characters with case sensitivity warnings."""
    triggers_seen = set()

    for trigger in mappings_to_check.keys():
        trigger_lower = trigger.lower()
        if trigger_lower in triggers_seen and trigger not in triggers_seen:
            logger.warning(
                "%sTrigger '%s' has both uppercase and lowercase variants",
                LOGS_INDENTATION,
                trigger_lower,
            )
        triggers_seen.add(trigger_lower)
        triggers_seen.add(trigger)

    logger.success(
        "%sProcessed %d unique triggers in the Ergopti+ mappings.",
        LOGS_INDENTATION,
        len(mappings_to_check),
    )


check_duplicate_triggers(plus_mappings)


if __name__ == "__main__":
    pprint(plus_mappings, indent=2, width=120)
