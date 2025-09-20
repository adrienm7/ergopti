"""Tests for validating logic in a keylayout."""

import logging
import re

logger = logging.getLogger("ergopti")
LOGS_INDENTATION = "\t\t"


def check_each_action_has_when_state_none(body: str) -> None:
    """
    Ensure that every <action> block contains at least one <when> with state="none".
    Raises ValueError if any <action> is missing a 'state="none"' definition.
    Displays all offending <action> blocks.
    """
    logger.info(
        '%s🔹 Checking that each <action> has a <when state="none">…',
        LOGS_INDENTATION,
    )

    # Extract <action> blocks
    action_blocks = re.findall(
        r"(<action\b.*?>.*?</action>)", body, flags=re.DOTALL
    )
    offending_actions = []

    for block in action_blocks:
        # Extract id if present
        id_match = re.search(r'id=["\']([^"\']+)["\']', block)
        action_id = id_match.group(1) if id_match else "<unknown>"

        # Check if at least one <when state="none"> exists
        if not re.search(r'<when\b[^>]*state=["\']none["\']', block):
            offending_actions.append((action_id, block))

    if offending_actions:
        logger.info(
            '%sSome <action> blocks are missing a <when state="none">:',
            LOGS_INDENTATION + "\t",
        )
        for action_id, block in offending_actions:
            logger.info("%s— %s", LOGS_INDENTATION + "\t\t", block.strip())
        raise ValueError(
            'Some <action> blocks do not contain a <when state="none">.'
        )
    else:
        logger.success(
            '%sAll <action> blocks have at least one <when state="none">.',
            LOGS_INDENTATION + "\t",
        )


def check_each_action_when_states_unique(body: str) -> None:
    """
    Ensure that within each <action> block, all <when> states are unique.
    Raises ValueError if duplicate states are found inside the same <action>.
    Displays all duplicates.
    """
    logger.info(
        "%s🔹 Checking that <when> states are unique within each <action>…",
        LOGS_INDENTATION,
    )

    # Extract <action> blocks
    action_blocks = re.findall(
        r"(<action\b.*?>.*?</action>)", body, flags=re.DOTALL
    )
    duplicates_found = {}

    for block in action_blocks:
        # Extract id if present
        id_match = re.search(r'id=["\']([^"\']+)["\']', block)
        action_id = id_match.group(1) if id_match else "<unknown>"

        # Collect states in this action
        states = re.findall(r'state=["\']([^"\']+)["\']', block)
        seen = set()
        duplicates = []

        for s in states:
            if s in seen:
                duplicates.append(s)
            else:
                seen.add(s)

        if duplicates:
            duplicates_found[action_id] = (block, duplicates)

    if duplicates_found:
        logger.info(
            "%sDuplicate <when> states found inside <action> blocks:",
            LOGS_INDENTATION + "\t",
        )
        for action_id, (block, duplicates) in duplicates_found.items():
            logger.info(
                "%s• Action ID « %s »:", LOGS_INDENTATION + "\t\t", action_id
            )
            # Extract all <when ...> tags from the action block
            when_blocks = re.findall(r"(<when\b[^>]*?/>)", block)
            # Print only the duplicated states
            for when_tag in when_blocks:
                state_match = re.search(r'state=["\']([^"\']+)["\']', when_tag)
                if state_match and state_match.group(1) in duplicates:
                    logger.info(
                        "%s— %s", LOGS_INDENTATION + "\t\t\t", when_tag.strip()
                    )
        raise ValueError(
            "Some <action> blocks contain duplicate <when> states."
        )
    else:
        logger.success(
            "%sAll <when> states are unique within each <action>.",
            LOGS_INDENTATION + "\t",
        )


def check_terminators_when_states_unique(body: str) -> None:
    """
    Ensure that all <when> states inside the <terminators> block are unique.
    Raises ValueError if duplicate states are found.
    """
    logger.info(
        "%s🔹 Checking that <when> states are unique within <terminators>…",
        LOGS_INDENTATION,
    )

    # Extract the <terminators> block
    match = re.search(
        r"<terminators[^>]*>(.*?)</terminators>", body, flags=re.DOTALL
    )
    if not match:
        logger.warning(
            "%sNo <terminators> block found, skipping.",
            LOGS_INDENTATION + "\t",
        )
        return

    terminators_body = match.group(1)
    states = re.findall(r'state=["\']([^"\']+)["\']', terminators_body)
    seen = set()
    duplicates = []

    for s in states:
        if s in seen:
            duplicates.append(s)
        else:
            seen.add(s)

    if duplicates:
        logger.error(
            "%sDuplicate <when> states found inside <terminators>:",
            LOGS_INDENTATION + "\t",
        )
        for s in set(duplicates):
            logger.error('%s— state="%s"', LOGS_INDENTATION + "\t\t", s)
        raise ValueError(
            "Duplicate <when> states found in <terminators> block."
        )
    else:
        logger.success(
            "%sAll <when> states are unique within <terminators>.",
            LOGS_INDENTATION + "\t",
        )


def check_when_states_defined_in_terminators(body: str) -> None:
    """
    Ensure that every state used in a <when> inside <actions> is defined in the <terminators> block.
    Raises ValueError if any state is missing in <terminators>.
    """
    logger.info(
        "%s🔹 Checking that all <when> states in <actions> are defined in <terminators>…",
        LOGS_INDENTATION,
    )

    # Extract all states used in <when> inside <actions>
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        logger.warning(
            "%sNo <actions> block found, skipping.", LOGS_INDENTATION + "\t"
        )
        return
    _, actions_body, _ = actions_match.groups()
    when_states = set(
        re.findall(r'<when[^>]*state=["\']([^"\']+)["\']', actions_body)
    )

    # Extract all states defined in <terminators>
    terminators_match = re.search(
        r"<terminators[^>]*>(.*?)</terminators>", body, flags=re.DOTALL
    )
    if not terminators_match:
        logger.warning(
            "%sNo <terminators> block found, skipping.",
            LOGS_INDENTATION + "\t",
        )
        return
    terminators_body = terminators_match.group(1)
    terminator_states = set(
        re.findall(r'state=["\']([^"\']+)["\']', terminators_body)
    )

    # Exclude special states (like 'none') if needed
    special_states = {"none"}
    missing_states = [
        s
        for s in when_states
        if s not in terminator_states and s not in special_states
    ]

    if missing_states:
        logger.error(
            "%s<when> states in <actions> missing in <terminators>:",
            LOGS_INDENTATION + "\t",
        )
        for s in missing_states:
            logger.error('%s— state="%s"', LOGS_INDENTATION + "\t\t", s)
    else:
        logger.success(
            "%sAll <when> states in <actions> are defined in <terminators>.",
            LOGS_INDENTATION + "\t",
        )


def check_each_when_has_output_or_next(body: str) -> None:
    """
    Ensure that every <when> block inside <actions> has at least one of 'output' or 'next'.
    Raises ValueError if any <when> is missing both attributes.
    Displays the action ID and offending <when> blocks.
    """
    logger.info(
        "%s🔹 Checking that every <when> inside <actions> has at least one of output or next…",
        LOGS_INDENTATION,
    )

    # Extract the <actions> block
    match = re.search(r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL)
    if not match:
        logger.warning(
            "%sNo <actions> block found, skipping.", LOGS_INDENTATION + "\t"
        )
        return

    _, actions_body, _ = match.groups()

    # Find all <action>...</action> blocks
    action_blocks = re.findall(
        r"(<action\b.*?>.*?</action>)", actions_body, flags=re.DOTALL
    )

    violations = {}

    for action_block in action_blocks:
        id_match = re.search(r'id=["\']([^"\']+)["\']', action_block)
        action_id = id_match.group(1) if id_match else "<unknown>"

        # Find all <when> tags inside this action
        when_blocks = re.findall(r"(<when\b[^>]*?/>)", action_block)
        for when_tag in when_blocks:
            has_output = bool(
                re.search(r'output=["\']([^"\']+)["\']', when_tag)
            )
            has_next = bool(re.search(r'next=["\']([^"\']+)["\']', when_tag))

            # Violation if neither output nor next is present
            if not (has_output or has_next):
                violations.setdefault(action_id, []).append(when_tag)

    if violations:
        logger.error(
            "%s<when> blocks missing output or next detected:",
            LOGS_INDENTATION + "\t",
        )
        for action_id, whens in violations.items():
            logger.error(
                "%s• Action ID « %s »:", LOGS_INDENTATION + "\t\t", action_id
            )
            for when_tag in whens:
                logger.error(
                    "%s— %s", LOGS_INDENTATION + "\t\t\t", when_tag.strip()
                )
        raise ValueError(
            "Some <when> blocks inside <actions> are missing both output and next."
        )
    else:
        logger.success(
            "%sAll <when> blocks inside <actions> have at least one of output or next.",
            LOGS_INDENTATION + "\t",
        )
