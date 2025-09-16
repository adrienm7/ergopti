import re

# For now, keylayout files are created with KbdEdit 24.7.0.
# Some corrections here might become obsolete with future versions of KbdEdit.
# See http://www.kbdedit.com/release_notes.html

file_indentation = "\t"


def correct_keylayout(content: str) -> str:
    """
    Apply all necessary corrections and modifications to a keylayout content.
    Returns the fully corrected content.
    """
    print(f"{file_indentation}🔧 Starting keylayout corrections…")

    content = fix_invalid_symbols(content)
    content = swap_keys_10_and_50(content)

    print(f"{file_indentation}➕ Adding keymap 4…")
    _, block0, _ = split_keymap(content, 0)
    _, base_body0, _ = split_keymap_block(block0)
    new_keymap4 = modify_accented_letters_shortcuts(4, base_body0)
    content = replace_keymap(content, to_index=4, new_keymap=new_keymap4)
    content = fix_keymap4_symbols(content)

    print(f"{file_indentation}➕ Adding keymap 9…")
    content = add_keymap_select_9(content)
    _, block4, _ = split_keymap(content, 4)
    _, base_body4, _ = split_keymap_block(block4)
    new_keymap9 = modify_accented_letters_shortcuts(9, base_body4)
    content = add_keymap_9(content, new_keymap9)

    print(f"{file_indentation}🎨 Cosmetic ordering and sorting…")
    content = reorder_modifiers_and_attributes(content)
    content = sort_keys(content)

    print("✅ Keylayout corrections complete.")
    return content


def fix_invalid_symbols(content: str) -> str:
    """
    Fix invalid XML symbols for <, >, & only inside `output` attributes.

    This function scans the text once, finds each `output="..."` attribute,
    and replaces the characters &, <, and > with their XML entity equivalents:
        &  -> &#x0026;
        <  -> &#x003C;
        >  -> &#x003E;

    The rest of the content is left unchanged.

    Args:
        content (str): The raw keylayout XML content.

    Returns:
        str: The content with fixed symbols inside `output` attributes.
    """
    print(
        f"{file_indentation}\t🔹 Fixing invalid symbols in output attributes…"
    )

    result = []
    i = 0

    while True:
        # Find the start of the next output attribute
        start = content.find('output="', i)
        if start == -1:
            # No more output attributes, append the remainder
            result.append(content[i:])
            break

        # Find the closing quote of the output value
        end = content.find('"', start + len('output="'))
        if end == -1:
            # Malformed attribute, append the rest and exit
            result.append(content[i:])
            break

        # Append everything up to and including 'output="'
        result.append(content[i : start + len('output="')])

        # Extract the attribute value
        value = content[start + len('output="') : end]

        # Replace problematic characters
        value = value.replace("&lt;", "&#x003C;")
        value = value.replace("&gt;", "&#x003E;")
        value = value.replace("&amp;", "&#x0026;")

        # Append the fixed value and the closing quote
        result.append(value)
        result.append('"')

        # Move the index past this attribute
        i = end + 1

    return "".join(result)


def swap_keys_10_and_50(content: str) -> str:
    """Swap key codes 10 and 50."""
    print(f"{file_indentation}\t🔹 Swapping key codes 10 and 50…")
    content = re.sub(r'code="50"', "TEMP_CODE", content)
    content = re.sub(r'code="10"', 'code="50"', content)
    content = re.sub(r"TEMP_CODE", 'code="10"', content)
    return content


def split_keymap(content: str, index: int):
    """Split content into before, the full keyMap block, and after."""
    match = re.search(
        rf'(<keyMap index="{index}">.*?</keyMap>)',
        content,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    before = content[: match.start()]
    block = match.group(1)
    after = content[match.end() :]
    return before, block, after


def split_keymap_block(block: str):
    """Split a keyMap block into header, body, and footer."""
    match = re.search(
        r'(<keyMap index="\d+">)(.*?)(</keyMap>)',
        block,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError("Invalid keyMap block structure.")
    return match.group(1), match.group(2), match.group(3)


def apply_key_substitutions(content: str, substitutions: dict) -> str:
    """Apply regex substitutions to the keys in a keyMap body."""
    for pattern, replacement in substitutions.items():
        content = re.sub(
            rf"\s*<key {pattern}", f"\n\t\t\t{replacement}", content
        )
    return content


def modify_accented_letters_shortcuts(index: int, base_body: str) -> str:
    """Build a custom keymap with specified substitutions for certain codes."""
    print(f"{file_indentation}\t🔹 Building custom keymap index {index}…")
    substitutions = {
        'code="6"[^>]*?/>': '<key code="6" output="c"/>',
        'code="7"[^>]*?/>': '<key code="7" action="v"/>',
        'code="50"[^>]*?/>': '<key code="50" output="x"/>',
        'code="12"[^>]*?/>': '<key code="12" action="z"/>',
    }
    new_body = apply_key_substitutions(base_body, substitutions)
    return f'<keyMap index="{index}">{new_body}\n\t\t</keyMap>'


def replace_keymap(content: str, to_index: int, new_keymap: str) -> str:
    """Replace an existing keymap with a new one."""
    print(f"{file_indentation}\t🔹 Replacing keymap {to_index}…")
    return re.sub(
        rf'<keyMap index="{to_index}">.*?</keyMap>',
        new_keymap,
        content,
        flags=re.DOTALL,
    )


def fix_keymap4_symbols(content: str) -> str:
    """Correct keymap 4 symbols for Ctrl + and Ctrl - shortcuts."""
    print(f"{file_indentation}\t🔹 Fixing keymap 4 symbols…")

    def replace_in_keymap(match):
        header, body, footer = match.groups()
        body = re.sub(
            r'(<key code="24"[^>]*(output|action)=")[^"]*(")',
            r"\1+\3",
            body,
        )
        body = re.sub(
            r'(<key code="27"[^>]*(output|action)=")[^"]*(")',
            r"\1-\3",
            body,
        )
        return f"{header}{body}{footer}"

    return re.sub(
        r'(<keyMap index="4">)(.*?)(</keyMap>)',
        replace_in_keymap,
        content,
        flags=re.DOTALL,
    )


def add_keymap_9(content: str, new_keymap9: str) -> str:
    """Add keymap index 9 by inserting a prepared keymap after index 8."""
    print(f"{file_indentation}\t🔹 Adding keymap 9…")
    if '<keyMap index="9">' in content:
        print(f"{file_indentation}\t\t⚠️ Keymap 9 already exists, skipping.")
        return content

    # Convert actions to outputs
    keymap_9 = re.sub(r'action="([^"]+)"', r'output="\1"', new_keymap9)

    return re.sub(
        r'(<keyMap index="8">.*?</keyMap>)',
        r"\1\n\t\t" + keymap_9,
        content,
        flags=re.DOTALL,
    )


def add_keymap_select_9(content: str) -> str:
    """Add <keyMapSelect> entry for mapIndex 9."""
    print(f"{file_indentation}\t🔹 Adding keymapSelect for index 9…")
    key_map_select = """\t\t<keyMapSelect mapIndex="9">
\t\t\t<modifier keys="command caps? anyOption? control?"/>
\t\t\t<modifier keys="control caps? anyOption?"/>
\t\t</keyMapSelect>"""
    return re.sub(
        r'(<keyMapSelect mapIndex="8">.*?</keyMapSelect>)',
        r"\1\n" + key_map_select,
        content,
        flags=re.DOTALL,
    )


def reorder_modifiers_and_attributes(content: str) -> str:
    """Reorder modifiers and attributes for cosmetic consistency."""
    print(f"{file_indentation}\t🔹 Reordering modifiers and attributes…")
    content = re.sub(r'encoding="utf-8"', 'encoding="UTF-8"', content)
    content = re.sub(r'maxout="1"\s+(name="[^"]+")', r'\1 maxout="3"', content)
    content = re.sub(r'keys="anyOption caps"', 'keys="caps anyOption"', content)
    content = re.sub(
        r'keys="anyOption caps anyShift"',
        'keys="anyShift caps anyOption"',
        content,
    )
    content = re.sub(
        r'keys="anyOption anyShift"', 'keys="anyShift anyOption"', content
    )
    content = re.sub(r'keys="caps anyShift"', 'keys="anyShift caps"', content)
    content = content.replace(
        """\t\t\t<modifier keys="command caps? anyOption? control?"/>\n\t\t\t<modifier keys="control caps? anyOption?"/>""",
        """\t\t\t<modifier keys="caps? anyOption? command anyControl?"/>\n\t\t\t<modifier keys="caps? anyOption? anyControl"/>""",
    )
    return content


def sort_keys(content: str) -> str:
    """Sort all <key> elements in each keyMap by their code attribute."""
    print(f"{file_indentation}\t🔹 Sorting keys by code…")

    def sort_block(match):
        header = match.group(1)
        body = match.group(2)
        keys = re.findall(r"(\s*<key[^>]+/>)", body)
        keys_sorted = sorted(
            keys, key=lambda k: int(re.search(r'code="(\d+)"', k).group(1))
        )
        return f"{header}" + "".join(keys_sorted) + "\n\t\t</keyMap>"

    return re.sub(
        r'(<keyMap index="\d+">)(.*?)(\n\t\t</keyMap>)',
        sort_block,
        content,
        flags=re.DOTALL,
    )
