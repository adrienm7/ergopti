"""Tests for validating a keylayout."""

import re

LOGS_INDENTATION = "\t"


def check_each_key_has_a_code(body: str) -> None:
    """
    Ensure that every <key> element inside <keyMap> blocks has a code attribute.
    Raises ValueError if any <key> is missing its code.
    Displays all <key> elements without a code.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that every <key> has a code…"
    )  # Needs double space after emoji

    missing_code_found = {}

    # Iterate over each <keyMap> block
    for keymap_match in re.finditer(
        r"<keyMap[^>]*>(.*?)</keyMap>", body, flags=re.DOTALL
    ):
        keymap_block = keymap_match.group(0)

        # Extract index for logging
        index_match = re.search(r'index=["\']([^"\']+)["\']', keymap_block)
        keymap_label = (
            f'index="{index_match.group(1)}"' if index_match else "<unknown>"
        )

        # Find all <key> elements in this keyMap
        key_tags = re.findall(r"(<key\b[^>]*>)", keymap_block)

        # Check each <key> for a code attribute
        for key_tag in key_tags:
            if not re.search(r'code=["\']([^"\']+)["\']', key_tag):
                if keymap_label not in missing_code_found:
                    missing_code_found[keymap_label] = []
                missing_code_found[keymap_label].append(key_tag)

    if missing_code_found:
        print(f"{LOGS_INDENTATION}\t❌ <key> elements missing code detected:")
        for keymap_name, tags in missing_code_found.items():
            print(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for tag in tags:
                print(f"{LOGS_INDENTATION}\t\t\t— {tag.strip()}")
        raise ValueError(
            "Some <key> elements are missing their code attribute."
        )

    print(f"{LOGS_INDENTATION}\t✅ All <key> elements have a code.")


def check_each_action_has_id(body: str) -> None:
    """
    Ensure that every <action> element inside the <actions> block has an ID attribute.
    Raises ValueError if any <action> is missing its ID.
    Displays all <action> elements without an ID.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that every <action> has an ID…"
    )  # Needs double space after emoji

    missing_id_found = {}

    # Extract the <actions> block
    match = re.search(r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL)
    if not match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping."
        )  # Needs double space after emoji
        return

    _, actions_body, _ = match.groups()

    # Find all <action> elements in the <actions> block
    action_tags = re.findall(
        r"(<action\b.*?>.*?</action>)", actions_body, flags=re.DOTALL
    )

    # Check each <action> for an ID attribute
    for action_tag in action_tags:
        if not re.search(r'id=["\']([^"\']+)["\']', action_tag):
            missing_id_found.setdefault("<actions>", []).append(action_tag)

    if missing_id_found:
        print(f"{LOGS_INDENTATION}\t❌ <action> elements missing ID detected:")
        for block_name, tags in missing_id_found.items():
            for tag in tags:
                print(f"{LOGS_INDENTATION}\t\t— {tag.strip()}")
        raise ValueError(
            "Some <action> elements are missing their ID attribute."
        )

    print(f"{LOGS_INDENTATION}\t✅ All <action> elements have an ID.")


def check_unique_keymap_indices(body: str) -> None:
    """
    Checks that no <keyMap> index is duplicated.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking unique <keyMap> indices…")
    indices = re.findall(r'<keyMap\s+index=["\'](\d+)["\']', body)
    duplicates = set([x for x in indices if indices.count(x) > 1])
    if duplicates:
        print(
            f"{LOGS_INDENTATION}\t❌ Duplicate <keyMap> indices: {', '.join(duplicates)}"
        )
        raise ValueError("Duplicate <keyMap> indices found.")
    print(f"{LOGS_INDENTATION}\t✅ All <keyMap> indices are unique.")


def check_unique_codes_in_keymaps(body: str) -> None:
    """
    Ensure that within each <keyMap>...</keyMap>, all key code attributes are unique.
    Raises ValueError if duplicates are found.
    Displays all occurrences of duplicate codes with their output/action values.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking for duplicate key codes inside each keyMap…"
    )  # Needs double space after emoji

    duplicates_found = {}

    # Iterate over each <keyMap> block
    for keymap_match in re.finditer(
        r"<keyMap[^>]*>(.*?)</keyMap>", body, flags=re.DOTALL
    ):
        keymap_block = keymap_match.group(0)

        # Extract index
        index_match = re.search(r'index=["\']([^"\']+)["\']', keymap_block)
        keymap_label = (
            f'index="{index_match.group(1)}"' if index_match else "<unknown>"
        )

        # Find all <key> elements and their code attributes
        key_matches = re.findall(
            r'(<key[^>]*code=["\']([^"\']+)["\'][^>]*/>)', keymap_block
        )
        key_codes_dict = {}

        # Iterate over all matches of <key> elements and their code attributes
        for full_key_tag, key_code in key_matches:
            if key_code not in key_codes_dict:
                # If this code is not yet in the dictionary, create a new list for it
                key_codes_dict[key_code] = []

            # Append the full <key ... /> tag to the list corresponding to this code
            key_codes_dict[key_code].append(full_key_tag)

        # After all <key> tags are processed, check for duplicates = lists with more than one entry
        for key_code, full_key_tags in key_codes_dict.items():
            # If there is more than one <key> tag with the same code, it's a duplicate
            if len(full_key_tags) > 1:
                # Ensure there is a dictionary for this keymap in duplicates_found
                if keymap_label not in duplicates_found:
                    duplicates_found[keymap_label] = {}

                # Store the list of all <key> tags that share this duplicate code
                duplicates_found[keymap_label][key_code] = full_key_tags

    if duplicates_found:
        print(f"{LOGS_INDENTATION}\t❌ Duplicate key codes detected:")
        for keymap_name, code_tags in duplicates_found.items():
            print(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for key_code, duplicated_tags in code_tags.items():
                for key_code_tag in duplicated_tags:
                    print(f"{LOGS_INDENTATION}\t\t\t— {key_code_tag}")
        raise ValueError("Duplicate key codes found in <keyMap> blocks.")

    print(f"{LOGS_INDENTATION}\t✅ No duplicate key codes in each keyMap.")


def check_unique_action_ids(body: str) -> None:
    """
    Ensure that all <action id="..."> blocks inside <actions> have unique ids.
    Raises ValueError if duplicates are found.
    Displays all occurrences of duplicate IDs with their full <action> content.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking for duplicate action IDs inside <actions>…"
    )  # Needs double space after emoji

    # Extract the <actions> block
    match = re.search(r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL)
    if not match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping."
        )  # Needs double space after emoji
        return body

    _, actions_body, _ = match.groups()

    # Find all <action>...</action> blocks (including nested content)
    action_blocks = re.findall(
        r"(\s*<action\b.*?>.*?</action>)", actions_body, flags=re.DOTALL
    )
    ids_dict = {}

    # Iterate over all <action> blocks and map by ID
    for action_block in action_blocks:
        id_match = re.search(r'id=["\']([^"\']+)["\']', action_block)
        action_id = id_match.group(1) if id_match else "<unknown>"
        if action_id not in ids_dict:
            ids_dict[action_id] = []
        ids_dict[action_id].append(action_block)

    duplicates_found = {
        action_id: blocks
        for action_id, blocks in ids_dict.items()
        if len(blocks) > 1
    }

    if duplicates_found:
        print(f"{LOGS_INDENTATION}\t❌ Duplicate action IDs detected:")
        for action_id, blocks in duplicates_found.items():
            print(f"{LOGS_INDENTATION}\t\t• ID « {action_id} »:")
            for block in blocks:
                print(f"{LOGS_INDENTATION}\t\t\t— {block.strip()}")
        raise ValueError("Duplicate action IDs found in <actions> block.")

    print(f"{LOGS_INDENTATION}\t✅ No duplicate action IDs.")


def check_each_key_has_either_output_or_action(body: str) -> None:
    """
    Ensure that each <key> element in all <keyMap> blocks has either an output or an action defined, but not both.
    Raises ValueError if any <key> violates this rule.
    Displays all offending <key> elements.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that each <key> has either output or action (exclusive)…"
    )  # Needs double space after emoji

    violations = {}

    # Iterate over each <keyMap> block
    for keymap_match in re.finditer(
        r"<keyMap[^>]*>(.*?)</keyMap>", body, flags=re.DOTALL
    ):
        keymap_block = keymap_match.group(0)
        index_match = re.search(r'index=["\']([^"\']+)["\']', keymap_block)
        keymap_label = (
            f'index="{index_match.group(1)}"' if index_match else "<unknown>"
        )

        # Find all <key> elements
        key_tags = re.findall(r"(<key[^>]+/>)", keymap_block)

        for key_tag in key_tags:
            has_output = bool(re.search(r'output=["\'][^"\']+["\']', key_tag))
            has_action = bool(re.search(r'action=["\'][^"\']+["\']', key_tag))

            if not has_output and not has_action:
                # Neither output nor action
                violations.setdefault(keymap_label, []).append(
                    f"{key_tag.strip()} — missing output/action"
                )
            elif has_output and has_action:
                # Both output and action
                violations.setdefault(keymap_label, []).append(
                    f"{key_tag.strip()} — both output and action"
                )

    if violations:
        print(f"{LOGS_INDENTATION}\t❌ Violations detected in <key> elements:")
        for keymap_name, tags in violations.items():
            print(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for tag in tags:
                print(f"{LOGS_INDENTATION}\t\t\t— {tag}")
        raise ValueError(
            "Some <key> elements have invalid output/action configuration."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <key> elements have valid output/action configuration."
    )
