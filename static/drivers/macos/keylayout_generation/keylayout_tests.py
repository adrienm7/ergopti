"""Tests for validating a keylayout."""

import re

from keylayout_sorting import sort_key

LOGS_INDENTATION = "\t"


def validate_keylayout(content: str) -> None:
    """
    Run all validation checks on the provided keylayout content.
    Raises ValueError if any check fails.
    """
    print(f"{LOGS_INDENTATION}🔎 Validating keylayout…")

    check_each_key_has_a_code(content)
    check_each_action_has_id(content)

    check_unique_codes_in_keymaps(content)
    check_unique_action_ids(content)

    check_each_action_in_keymaps_defined_in_actions(content)
    # check_each_action_in_keymaps_is_used(content)

    check_each_action_has_when_state_none(content)
    check_each_action_when_states_unique(content)
    check_each_when_has_output_or_next(content)

    check_each_key_has_either_output_or_action(content)
    check_xml_attribute_errors(content)

    check_indentation_consistency(content)
    check_no_empty_lines(content)

    check_ascending_keymaps(content)
    check_ascending_keys_in_keymaps(content)
    check_ascending_actions(content)

    print(f"{LOGS_INDENTATION}✅ Keylayout validation passed.")


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


def check_each_action_in_keymaps_defined_in_actions(body: str) -> None:
    """
    Ensure that all action names used in keyMaps are defined as <action id="..."> in <actions>.
    Raises ValueError if any keyMap action is missing in <actions>.
    Displays all missing action references.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that all keyMap actions exist in <actions>…"
    )  # Needs double space after emoji

    # Extract all action IDs defined in <actions>
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping."
        )  # Needs double space after emoji
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
        print(
            f"{LOGS_INDENTATION}\t❌ KeyMap actions not defined in <actions> detected:"
        )
        for keymap_name, tags in missing_actions_found.items():
            print(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for tag in tags:
                print(f"{LOGS_INDENTATION}\t\t\t— {tag.strip()}")
        raise ValueError("Some keyMap actions are missing in <actions>.")

    print(
        f"{LOGS_INDENTATION}\t✅ All keyMap actions are defined in <actions>."
    )


def check_each_action_in_keymaps_is_used(body: str) -> None:
    """
    Ensure that every <action id="..."> in <actions> is referenced by at least one <key> in keyMaps.
    Raises ValueError if any <action> is defined but never used.
    Displays all unused <action> blocks.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking that all <actions> are used in keyMaps…"
    )  # Needs double space after emoji

    # Extract the <actions> block
    actions_match = re.search(
        r"(<actions.*?>)(.*?)(</actions>)", body, flags=re.DOTALL
    )
    if not actions_match:
        print(
            f"{LOGS_INDENTATION}\t\t⚠️  No <actions> block found, skipping."
        )  # Needs double space after emoji
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
        print(f"{LOGS_INDENTATION}\t❌ Unused <action> blocks detected:")
        for action_id in unused_action_ids:
            print(
                f"{LOGS_INDENTATION}\t\t— {defined_actions[action_id].strip()}"
            )
        raise ValueError(
            "Some <action> blocks are defined but never used in keyMaps."
        )

    print(f"{LOGS_INDENTATION}\t✅ All <action> blocks are used in keyMaps.")


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


def check_xml_attribute_errors(body: str) -> None:
    """
    Ensure XML attributes are well-formed.
    Raises ValueError if malformed attributes are found.
    Displays the offending lines.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking for malformed XML attributes…"
    )  # Needs double space after emoji

    lines = body.splitlines()
    errors = []

    for i, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue

        # Find all attribute assignments
        # Match pattern: key = "value" or key = 'value'
        attr_matches = re.findall(r'(\w+\s*=\s*["\'].*?["\']?)', line)
        for attr in attr_matches:
            # Must contain =
            if "=" not in attr:
                errors.append((i, line.strip(), "Missing '=' in attribute"))
                continue

            name, value = attr.split("=", 1)
            value = value.strip()

            # Value must start and end with same quote
            if not (
                (value.startswith('"') and value.endswith('"'))
                or (value.startswith("'") and value.endswith("'"))
            ):
                errors.append(
                    (i, line.strip(), "Attribute value not properly quoted")
                )

        # Check for unclosed quotes anywhere in the line
        # Count total " and ' not escaped
        double_quotes = line.count('"')
        single_quotes = line.count("'")
        if double_quotes % 2 != 0:
            errors.append((i, line.strip(), "Unmatched double quote in line"))
        if single_quotes % 2 != 0:
            errors.append((i, line.strip(), "Unmatched single quote in line"))

    if errors:
        print(f"{LOGS_INDENTATION}\t❌ Malformed XML attributes detected:")
        for line_num, content, reason in errors:
            print(f"{LOGS_INDENTATION}\t\t— Line {line_num}: {reason}")
            print(f"{LOGS_INDENTATION}\t\t\t{content}")
        raise ValueError("Malformed XML attributes found.")

    print(f"{LOGS_INDENTATION}\t✅ All XML attributes appear well-formed.")


# ===============================
# ======= Cosmetic checks =======
# ===============================


def check_indentation_consistency(body: str) -> None:
    """
    Check that all lines in the body have consistent indentation.
    Self-closing tags (<tag ... />) are considered children but not pushed to the stack.
    Opening and closing tags of the same block must align exactly.
    Children must be indented at least one space more than their parent.
    Top-level tags (opening or closing) may have zero indentation.
    Raises ValueError if inconsistencies are found.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking overall indentation consistency…")

    lines = body.splitlines()
    stack = []  # Stack to track (tag, indentation)
    inconsistencies = []

    opening_tag_re = re.compile(r"<(\w+)(\s[^>]*)?>")
    closing_tag_re = re.compile(r"</(\w+)>")
    self_closing_re = re.compile(r"<\w+[^>]*/>")

    for line_number, line in enumerate(lines, start=1):
        stripped = line.lstrip()
        if not stripped:
            continue  # Skip empty lines

        current_indent = len(line) - len(stripped)
        parent_indent = stack[-1][1] if stack else 0

        # Self-closing tag
        if self_closing_re.match(stripped):
            if stack and current_indent <= parent_indent:
                inconsistencies.append(
                    (line_number, parent_indent, current_indent, line.strip())
                )
            continue

        # Closing tag
        closing_match = closing_tag_re.match(stripped)
        if closing_match:
            tag = closing_match.group(1)
            if not stack:
                # Top-level closing tag allowed at zero indentation
                if current_indent != 0:
                    inconsistencies.append(
                        (line_number, None, current_indent, line.strip())
                    )
                continue
            parent_tag, opening_indent = stack.pop()
            if tag != parent_tag or current_indent != opening_indent:
                inconsistencies.append(
                    (line_number, opening_indent, current_indent, line.strip())
                )
            continue

        # Opening tag
        opening_match = opening_tag_re.match(stripped)
        if opening_match:
            tag = opening_match.group(1)
            # Allow top-level opening tags at zero indent
            if stack and current_indent <= parent_indent:
                inconsistencies.append(
                    (line_number, parent_indent, current_indent, line.strip())
                )
            stack.append((tag, current_indent))
            continue

        # Regular content line inside a block
        if stack and current_indent <= parent_indent:
            inconsistencies.append(
                (line_number, parent_indent, current_indent, line.strip())
            )

    if inconsistencies:
        print(f"{LOGS_INDENTATION}\t❌ Indentation inconsistencies detected:")
        for line_number, parent, current, content_line in inconsistencies:
            parent_str = parent if parent is not None else 0
            print(
                f"{LOGS_INDENTATION}\t\t— Line {line_number}: Indentation {current} "
                f"too shallow relative to parent {parent_str}:\n"
                f"{LOGS_INDENTATION}\t\t\t{content_line}"
            )
        raise ValueError("Indentation errors found in body.")

    print(f"{LOGS_INDENTATION}\t✅ Indentation consistency verified.")


def check_no_empty_lines(body: str) -> None:
    """
    Ensure there are no empty lines in the body, ignoring leading and trailing empty lines.
    Raises ValueError if empty lines are found.
    Displays the preceding line for context.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking for empty lines…"
    )  # Needs double space after emoji

    lines = body.splitlines()

    # Find first and last non-empty lines
    first_line_idx = next((i for i, l in enumerate(lines) if l.strip()), 0)
    last_line_idx = (
        len(lines)
        - 1
        - next((i for i, l in enumerate(reversed(lines)) if l.strip()), 0)
    )
    relevant_lines = lines[first_line_idx : last_line_idx + 1]

    empty_lines_info = []

    for i, line in enumerate(relevant_lines, start=first_line_idx + 1):
        if not line.strip():
            prev_line_content = (
                lines[i - 2].strip() if i - 2 >= 0 else "<start of file>"
            )
            empty_lines_info.append((i, prev_line_content))

    if empty_lines_info:
        print(f"{LOGS_INDENTATION}\t❌ Empty lines detected:")
        for line_number, prev_content in empty_lines_info:
            print(
                f"{LOGS_INDENTATION}\t\t— Line {line_number} after: {prev_content}"
            )
        raise ValueError("Empty lines found in body.")

    print(f"{LOGS_INDENTATION}\t✅ No empty lines detected.")


# ===============================
# ======= Ordering checks =======
# ===============================


def check_ascending_keymaps(body: str) -> None:
    """
    Ensure that all <keyMap> blocks are defined in ascending order by their index.
    Raises ValueError if any keyMap is out of order.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking ascending order of <keyMap> indices…"
    )  # Needs double space after emoji

    keymap_matches = re.findall(r'<keyMap\s+index=["\'](\d+)["\']', body)
    indices = [int(idx) for idx in keymap_matches]

    last_index = -1
    out_of_order = []

    # Detect out-of-order keyMaps
    for i, idx in enumerate(indices):
        if idx <= last_index:
            out_of_order.append((i, last_index, idx))
        last_index = idx

    if out_of_order:
        print(
            f"{LOGS_INDENTATION}\t❌ KeyMap indices out of ascending order detected:"
        )
        for pos, prev, current in out_of_order:
            print(
                f"{LOGS_INDENTATION}\t\t— Position {pos}: index {current} follows {prev}"
            )
        raise ValueError("KeyMap indices are not in ascending order.")

    print(
        f"{LOGS_INDENTATION}\t✅ All <keyMap> indices are in ascending order."
    )


def check_ascending_keys_in_keymaps(body: str) -> None:
    """
    Ensure that all <key> elements inside each <keyMap> are in ascending order by code.
    Raises ValueError if any <key> is out of order.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking ascending order of <key> codes inside each <keyMap>…"
    )  # Needs double space after emoji

    issues_found = {}

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

        # Extract codes from <key> elements
        key_matches = re.findall(r'<key[^>]*code=["\'](\d+)["\']', keymap_block)
        codes = [int(code) for code in key_matches]

        # Check order
        last_code = -1
        for i, code in enumerate(codes):
            if code <= last_code:
                issues_found.setdefault(keymap_label, []).append(
                    (i, code, last_code)
                )
            last_code = code

    if issues_found:
        print(f"{LOGS_INDENTATION}\t❌ Out-of-order <key> codes detected:")
        for keymap_name, problems in issues_found.items():
            print(f"{LOGS_INDENTATION}\t\t• KeyMap {keymap_name}:")
            for pos, code, prev in problems:
                print(
                    f"{LOGS_INDENTATION}\t\t\t— Position {pos}: code {code} follows {prev}"
                )
        raise ValueError(
            "Some <key> elements are not in ascending order by code."
        )

    print(
        f"{LOGS_INDENTATION}\t✅ All <key> codes are in ascending order inside each <keyMap>."
    )


def check_ascending_actions(body: str) -> None:
    """
    Verify that all <action> blocks inside <actions> blocks are in alphabetical order by ID.
    Uses the same sort_key logic as sort_actions.
    Raises ValueError if any action is out of order.
    """
    print(
        f"{LOGS_INDENTATION}\t➡️  Checking alphabetical order of <action> IDs…"
    )  # Needs double space after emoji

    action_matches = re.findall(r'<action\s+id=["\']([^"\']+)["\']', body)
    last_key = None
    out_of_order = []

    for i, action_id in enumerate(action_matches):
        current_key = sort_key(action_id)
        if last_key and current_key < last_key:
            out_of_order.append((i, action_matches[i - 1], action_id))
        last_key = current_key

    if out_of_order:
        print(
            f"{LOGS_INDENTATION}\t❌ Action IDs out of alphabetical order detected:"
        )
        for pos, prev, current in out_of_order:
            print(
                f"{LOGS_INDENTATION}\t\t— Position {pos}: ID « {current} » follows « {prev} »"
            )
        raise ValueError("Action IDs are not in alphabetical order.")

    print(f"{LOGS_INDENTATION}\t✅ All <action> IDs are in alphabetical order.")
