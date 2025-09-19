"""Tests for validating a keylayout."""

import re

LOGS_INDENTATION = "\t"


def check_each_action_has_when_state_none(body: str) -> None:
    """
    Ensure that every <action> block contains at least one <when> with state="none".
    Raises ValueError if any <action> is missing a 'state="none"' definition.
    Displays all offending <action> blocks.
    """
    print(
        f'{LOGS_INDENTATION}\t➡️  Checking that each <action> has a <when state="none">…'
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
        print(
            f'{LOGS_INDENTATION}\t❌ Some <action> blocks are missing a <when state="none">:'
        )
        for action_id, block in offending_actions:
            print(f"{LOGS_INDENTATION}\t\t— {block.strip()}")
        raise ValueError(
            'Some <action> blocks do not contain a <when state="none">.'
        )

    print(
        f'{LOGS_INDENTATION}\t✅ All <action> blocks have at least one <when state="none">.'
    )


def check_each_action_when_states_unique(body: str) -> None:
    """
    Ensure that within each <action> block, all <when> states are unique.
    Raises ValueError if duplicate states are found inside the same <action>.
    Displays all duplicates.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that <when> states are unique within each <action>…"
    )  # Needs double space after emoji

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
        print(
            f"{LOGS_INDENTATION}\t❌ Duplicate <when> states found inside <action> blocks:"
        )
        for action_id, (block, duplicates) in duplicates_found.items():
            print(f"{LOGS_INDENTATION}\t\t• Action ID « {action_id} »:")

            # Extract all <when ...> tags from the action block
            when_blocks = re.findall(r"(<when\b[^>]*?/>)", block)

            # Print only the duplicated states
            for when_tag in when_blocks:
                state_match = re.search(r'state=["\']([^"\']+)["\']', when_tag)
                if state_match and state_match.group(1) in duplicates:
                    print(f"{LOGS_INDENTATION}\t\t\t— {when_tag.strip()}")

        raise ValueError(
            "Some <action> blocks contain duplicate <when> states."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <when> states are unique within each <action>."
    )


def check_terminators_when_states_unique(body: str) -> None:
    """
    Ensure that all <when> states inside the <terminators> block are unique.
    Raises ValueError if duplicate states are found.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that <when> states are unique within <terminators>…"
    )  # Needs double space after emoji

    # Extract the <terminators> block
    match = re.search(
        r"<terminators[^>]*>(.*?)</terminators>", body, flags=re.DOTALL
    )
    if not match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <terminators> block found, skipping."
        )  # Needs double space after emoji
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
        print(
            f"{LOGS_INDENTATION}\t❌ Duplicate <when> states found inside <terminators>:"
        )
        for s in set(duplicates):
            print(f'{LOGS_INDENTATION}\t\t— state="{s}"')
        raise ValueError(
            "Duplicate <when> states found in <terminators> block."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <when> states are unique within <terminators>."
    )


def check_when_states_defined_in_terminators(body: str) -> None:
    """
    Ensure that every state used in a <when> inside <actions> is defined in the <terminators> block.
    Raises ValueError if any state is missing in <terminators>.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that all <when> states in <actions> are defined in <terminators>…"
    )

    # Extract all states used in <when> inside <actions>
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        print(f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping.")
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
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <terminators> block found, skipping."
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
        print(
            f"{LOGS_INDENTATION}\t❌ <when> states in <actions> missing in <terminators>:"
        )
        for s in missing_states:
            print(f'{LOGS_INDENTATION}\t\t— state="{s}"')
        raise ValueError(
            "Some <when> states in <actions> are not defined in <terminators> block."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <when> states in <actions> are defined in <terminators>."
    )


def check_each_when_has_output_or_next(body: str) -> None:
    """
    Ensure that every <when> block inside <actions> has at least one of 'output' or 'next'.
    Raises ValueError if any <when> is missing both attributes.
    Displays the action ID and offending <when> blocks.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that every <when> inside <actions> has at least one of output or next…"
    )  # Needs double space after emoji

    # Extract the <actions> block
    match = re.search(r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL)
    if not match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping."
        )  # Needs double space after emoji
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
        print(
            f"{LOGS_INDENTATION}\t❌ <when> blocks missing output or next detected:"
        )
        for action_id, whens in violations.items():
            print(f"{LOGS_INDENTATION}\t\t• Action ID « {action_id} »:")
            for when_tag in whens:
                print(f"{LOGS_INDENTATION}\t\t\t— {when_tag.strip()}")
        raise ValueError(
            "Some <when> blocks inside <actions> are missing both output and next."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <when> blocks inside <actions> have at least one of output or next."
    )
