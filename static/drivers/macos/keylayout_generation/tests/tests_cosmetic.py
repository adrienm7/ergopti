"""Tests for validating a keylayout."""

import re
import unicodedata

LOGS_INDENTATION = "\t"


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
    first_line_idx = next(
        (idx for idx, line in enumerate(lines) if line.strip()), 0
    )
    last_line_idx = (
        len(lines)
        - 1
        - next(
            (idx for idx, line in enumerate(reversed(lines)) if line.strip()), 0
        )
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


def sort_key(id_str: str):
    """
    Key function for sorting or comparison:
    - Lowercase letters = 0
    - Uppercase letters = 1
    - Symbols/numbers = 2
    """

    def normalize_id(id_str: str) -> str:
        """
        Normalize ID for sorting:
        - Strip accents to base letters
        - Preserve original case (so lowercase sorts before uppercase)
        """
        nfkd = unicodedata.normalize("NFKD", id_str)
        return "".join([c for c in nfkd if not unicodedata.combining(c)])

    normalized = normalize_id(id_str)
    key = []
    for c in normalized:
        if c.islower():
            key.append((0, c))
        elif c.isupper():
            key.append((1, c))
        else:
            key.append((2, c))
    return tuple(key)


def check_attribute_order(body: str) -> None:
    """
    Checks that attributes always appear in the same order in <key>, <action>, <when>.
    """
    print(f"{LOGS_INDENTATION}\t➡️  Checking attribute order…")

    import re

    expected_orders = {
        "key": ["code", "output", "action"],
        "action": ["id"],
        "when": ["state", "output", "next"],
    }

    for tag, expected in expected_orders.items():
        # Regex to match the opening tag and capture attributes
        pattern = re.compile(rf"<{tag}\s+([^>/]+?)[/?>]")
        for match in pattern.finditer(body):
            attrs_str = match.group(1)
            # Extract attribute names in order
            attrs = re.findall(r"(\w+)=", attrs_str)
            if len(attrs) > 1:
                filtered = [a for a in expected if a in attrs]
                actual = [a for a in attrs if a in expected]
                if actual != filtered:
                    print(
                        f"{LOGS_INDENTATION}\t❌ Attribute order incorrect in <{tag}>: {attrs} (expected: {expected})"
                    )
                    raise ValueError(
                        f"Attribute order incorrect in <{tag}>: {attrs}"
                    )

    print(f"{LOGS_INDENTATION}\t✅ Attribute order is correct.")
