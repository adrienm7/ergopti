import re

file_indentation = "\t"


def correct_keylayout(content: str) -> str:
    """
    Apply all necessary corrections and modifications to a keylayout content.
    Returns the fully corrected content.
    """
    print(f"{file_indentation}🔧 Starting keylayout corrections…")

    content = fix_invalid_symbols(content)
    content = swap_keys_10_and_50(content)

    print(f"{file_indentation}➕ Modifying keymap 4…")
    keymap_0_content = extract_keymap_body(content, 0)
    keymap_4_content = modify_accented_letters_shortcuts(keymap_0_content)
    keymap_4_content = fix_keymap_4_symbols(keymap_4_content)
    keymap_4_content = convert_actions_to_outputs(
        keymap_4_content
    )  # Ctrl shortcuts can be directly set to output, as they don’t trigger other states
    content = replace_keymap(content, 4, keymap_4_content)

    print(f"{file_indentation}➕ Adding keymap 9…")
    content = add_keymap_select_9(content)
    keymap_4_content = extract_keymap_body(content, 4)
    content = add_keymap(content, 9, keymap_4_content)

    print(f"{file_indentation}🎨 Cosmetic ordering and sorting…")
    content = reorder_modifiers_and_attributes(content)
    content = sort_keys(content)
    content = sort_keymaps(content)

    print("✅ Keylayout corrections complete.")
    return content


def fix_invalid_symbols(content: str) -> str:
    """Fix invalid XML symbols for <, > and &."""
    print(f"{file_indentation}\t🔹 Fixing invalid symbols for <, > and &…")
    content = content.replace("&lt;", "&#x003C;")  # <
    content = content.replace("&gt;", "&#x003E;")  # >
    content = content.replace("&amp;", "&#x0026;")  # &
    return content


def swap_keys_10_and_50(content: str) -> str:
    """Swap key codes 10 and 50."""
    print(f"{file_indentation}\t🔹 Swapping key codes 10 and 50…")
    content = re.sub(r'code="50"', "TEMP_CODE", content)
    content = re.sub(r'code="10"', 'code="50"', content)
    content = re.sub(r"TEMP_CODE", 'code="10"', content)
    return content


def extract_keymap_body(content: str, index: int) -> str:
    """Extract only the inner body of a keyMap by index."""
    match = re.search(
        rf'<keyMap index="{index}">(.*?)</keyMap>',
        content,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1)


def modify_accented_letters_shortcuts(body: str) -> str:
    """Replace the output value for accented letters key codes."""
    print(f"{file_indentation}\t🔹 Modifying accented letter shortcuts…")

    replacements = {
        "6": "c",
        "7": "v",
        "50": "x",
        "12": "z",
    }

    for code, new_value in replacements.items():
        # Replace the content inside output or action for the given code
        body = re.sub(
            rf'(<key code="{code}"[^>]*(output|action)=")[^"]*(")',
            rf"\1{new_value}\3",
            body,
        )

    return body


def convert_actions_to_outputs(body: str) -> str:
    """Convert all action="..." attributes to output="..." while keeping their values."""
    print(f"{file_indentation}\t🔹 Converting action attributes to output…")
    return re.sub(r'action="([^"]+)"', r'output="\1"', body)


def replace_keymap(content: str, index: int, new_body: str) -> str:
    """Replace an existing keyMap body while keeping the original <keyMap> tags."""
    print(f"{file_indentation}\t🔹 Replacing keymap {index}…")
    return re.sub(
        rf'(<keyMap index="{index}">).*?(</keyMap>)',
        rf"\1{new_body}\2",
        content,
        flags=re.DOTALL,
    )


def fix_keymap_4_symbols(body: str) -> str:
    """Correct the symbols for Ctrl + and Ctrl - in a keyMap body."""
    print(f"{file_indentation}\t🔹 Fixing keymap 4 symbols in body…")
    body = re.sub(
        r'(<key code="24"[^>]*(output|action)=")[^"]*(")', r"\1+\3", body
    )
    body = re.sub(
        r'(<key code="27"[^>]*(output|action)=")[^"]*(")', r"\1-\3", body
    )
    return body


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


def add_keymap(content: str, index: int, keymap_body: str) -> str:
    """
    Add a keyMap with a given index just before the closing </keyMapSet> tag.
    If a keyMap with the same index already exists, the new keyMap is not added.
    """
    print(f"{file_indentation}\t🔹 Adding keymap {index}…")
    if f'<keyMap index="{index}">' in content:
        print(
            f"{file_indentation}\t\t⚠️ Keymap {index} already exists, skipping."
        )
        return content

    insertion = f'\n\t\t<keyMap index="{index}">{keymap_body}</keyMap>\n'
    # Insert just before the closing </keyMapSet> tag
    return re.sub(
        r"(</keyMapSet>)", insertion + r"\1", content, flags=re.DOTALL
    )


def reorder_modifiers_and_attributes(content: str) -> str:
    """Standardize encoding, maxout, and key/modifier orders for cosmetic consistency."""
    print(f"{file_indentation}\t🔹 Reordering modifiers and attributes…")

    # Standardize encoding
    content = content.replace('encoding="utf-8"', 'encoding="UTF-8"')

    # Increase maxout from 1 to 3
    content = re.sub(r'maxout="1"', 'maxout="3"', content)

    # Standardize key orders and specific modifier blocks
    key_replacements = {
        'keys="anyOption caps anyShift"': 'keys="anyShift caps anyOption"',
        'keys="anyOption anyShift"': 'keys="anyShift anyOption"',
        'keys="anyOption caps"': 'keys="caps anyOption"',
        'keys="caps anyShift"': 'keys="anyShift caps"',
        'keys="command caps? anyOption? control?"': 'keys="caps? anyOption? command anyControl?"',
        'keys="control caps? anyOption?"': 'keys="caps? anyOption? anyControl"',
    }
    for old, new in key_replacements.items():
        content = content.replace(old, new)

    return content


def sort_keys(content: str) -> str:
    """Sort all <key> elements in each <keyMap> block by their code attribute."""
    print(f"{file_indentation}\t🔹 Sorting keys by code…")

    def sort_block(match):
        header, body, footer = match.groups()
        # Extract all <key .../> elements
        keys = re.findall(r"(\s*<key[^>]+/>)", body)
        # Sort keys numerically by their code attribute
        keys_sorted = sorted(
            keys, key=lambda k: int(re.search(r'code="(\d+)"', k).group(1))
        )
        # Reconstruct the block
        return f"{header}{''.join(keys_sorted)}\n\t\t{footer}"

    return re.sub(
        r'(<keyMap index="\d+">)(.*?)(</keyMap>)',
        sort_block,
        content,
        flags=re.DOTALL,
    )


def sort_keymaps(content: str) -> str:
    """Sort all <keyMap> blocks numerically by their index inside <keyMapSet>."""
    print(f"{file_indentation}\t🔹 Sorting keyMaps inside keyMapSet…")

    # Extract the keyMapSet block
    match = re.search(
        r"(<keyMapSet.*?>)(.*?)(</keyMapSet>)", content, flags=re.DOTALL
    )
    if not match:
        return content  # Nothing to sort if no keyMapSet found

    header, body, footer = match.groups()

    # Extract all keyMap blocks in the body
    keymaps = re.findall(
        r'(<keyMap index="(\d+)">.*?</keyMap>)', body, flags=re.DOTALL
    )
    if not keymaps:
        return content  # No keymaps to sort

    # Sort by index numerically
    keymaps_sorted = sorted(keymaps, key=lambda k: int(k[1]))

    # Reconstruct the keyMapSet with sorted keyMaps
    new_body = "".join("\n\t\t" + k[0] for k in keymaps_sorted)
    sorted_keymapset = header + new_body + "\n\t" + footer

    # Replace the old keyMapSet in content
    content = re.sub(
        r"(<keyMapSet.*?>.*?</keyMapSet>)",
        sorted_keymapset,
        content,
        flags=re.DOTALL,
    )
    return content
