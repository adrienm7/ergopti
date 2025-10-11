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
    Load Ergopti+ mappings configuration from TOML file.

    Returns:
            Dictionary containing the mappings configuration

    Raises:
            ImportError: If tomllib/tomli is not available
            FileNotFoundError: If the TOML file doesn't exist
            OSError: If there's an error reading the file
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

    # Load TOML configuration file
    config_file = Path(__file__).parent / "rolls.toml"

    if not config_file.exists():
        raise FileNotFoundError(f"Configuration file not found: {config_file}")

    try:
        with open(config_file, "rb") as f:
            toml_data = tomllib.load(f)
    except OSError as e:
        raise OSError(f"Error reading configuration file {config_file}: {e}")

    # Convert TOML structure to the expected format
    config = {}
    for section_name, section_data in toml_data.items():
        # Extract trigger from the first key and build mappings
        triggers = set()
        map_entries = []

        for key, value in section_data.items():
            if len(key) >= 1:
                trigger = key[0]  # First character is the trigger
                remaining = key[1:]  # Rest is the mapping key
                triggers.add(trigger)
                map_entries.append((remaining, value))

        # Use the most common trigger (should be only one per section)
        if triggers:
            trigger = list(triggers)[
                0
            ]  # Take the first (and should be only) trigger
            config[section_name] = {"trigger": trigger, "map": map_entries}

    return config


# Load configuration from TOML file
try:
    PLUS_MAPPINGS_CONFIG = load_plus_mappings_config()
    logger.info("Loaded Ergopti+ mappings configuration from TOML file")
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
    trigger = item[1].get("trigger", "")
    is_single_alpha = len(trigger) == 1 and trigger.isalpha()
    if is_single_alpha:
        # Sort by (trigger.lower(), is_uppercase) for a, A, b, B, ...
        # is_uppercase: False (minuscule) avant True (majuscule)
        return (True, (trigger.lower(), trigger.isupper()))
    return (False, trigger)


plus_mappings = OrderedDict(sorted(plus_mappings.items(), key=_sort_key))


def check_duplicate_triggers(mappings_to_check: dict):
    """Check for duplicate trigger characters in the plus_mappings."""
    triggers = {}
    for key, data in mappings_to_check.items():
        trigger = data["trigger"]
        if trigger in triggers:
            logger.error(
                "%sDuplicate trigger '%s' found in '%s' and '%s'",
                LOGS_INDENTATION,
                trigger,
                key,
                triggers[trigger],
            )
        else:
            triggers[trigger] = key
    logger.success(
        "%sNo duplicate triggers found in the Ergopti+ mappings.",
        LOGS_INDENTATION,
    )


check_duplicate_triggers(plus_mappings)


if __name__ == "__main__":
    pprint(plus_mappings, indent=2, width=120)
