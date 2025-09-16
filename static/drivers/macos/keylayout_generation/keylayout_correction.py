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

    print(f"{file_indentation}➕ Modifying keymap 4…")
    _, keymap_0, _ = retrieve_keymap(content, 0)
    _, keymap_0_content, _ = retrieve_keymap_content(keymap_0)
    _, keymap_4, _ = retrieve_keymap(content, 4)
    keymap_4_header, _, keymap_4_footer = retrieve_keymap_content(keymap_4)

    new_keymap_4_content = modify_accented_letters_shortcuts(keymap_0_content)
    new_keymap_4_content = fix_keymap4_symbols_body(new_keymap_4_content)
    new_keymap_4 = keymap_4_header + new_keymap_4_content + keymap_4_footer
    content = replace_keymap(content, to_index=4, new_keymap=new_keymap_4)

    print(f"{file_indentation}➕ Adding keymap 9…")
    content = add_keymap_select_9(content)
    _, keymap_4, _ = retrieve_keymap(content, 4)
    _, keymap_4_content, _ = retrieve_keymap_content(keymap_4)
    content = add_keymap_9(content, keymap_4_content)

    print(f"{file_indentation}🎨 Cosmetic ordering and sorting…")
    content = reorder_modifiers_and_attributes(content)
    content = sort_keys(content)

    print("✅ Keylayout corrections complete.")
    return content


def fix_invalid_symbols(content: str) -> str:
    """Fix invalid XML symbols for <, > and &."""
    print(f"{file_indentation}\t🔹 Fixing invalid symbols for <, > and &…")
    content = content.replace("&lt;", "&#x003C;")
    content = content.replace("&gt;", "&#x003E;")
    content = content.replace("&amp;", "&#x0026;")
    return content


def swap_keys_10_and_50(content: str) -> str:
    """Swap key codes 10 and 50."""
    print(f"{file_indentation}\t🔹 Swapping key codes 10 and 50…")
    content = re.sub(r'code="50"', "TEMP_CODE", content)
    content = re.sub(r'code="10"', 'code="50"', content)
    content = re.sub(r"TEMP_CODE", 'code="10"', content)
    return content


def retrieve_keymap(content: str, index: int):
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


def retrieve_keymap_content(block: str):
    """Split a keyMap block into header, body, and footer."""
    match = re.search(
        r'(<keyMap index="\d+">)(.*?)(</keyMap>)',
        block,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError("Invalid keyMap block structure.")
    return match.group(1), match.group(2), match.group(3)


def modify_accented_letters_shortcuts(base_body: str) -> str:
    """Build a custom keymap with specified substitutions for certain codes."""

    def apply_key_substitutions(content: str, substitutions: dict) -> str:
        """Apply regex substitutions to the keys in a keyMap body."""
        for pattern, replacement in substitutions.items():
            content = re.sub(
                rf"\s*<key {pattern}", f"\n\t\t\t{replacement}", content
            )
        return content

    print(
        f"{file_indentation}\t🔹 Building custom keymap with specified substitutions for certain codes…"
    )
    substitutions = {
        'code="6"[^>]*?/>': '<key code="6" output="c"/>',
        'code="7"[^>]*?/>': '<key code="7" action="v"/>',
        'code="50"[^>]*?/>': '<key code="50" output="x"/>',
        'code="12"[^>]*?/>': '<key code="12" action="z"/>',
    }
    new_body = apply_key_substitutions(base_body, substitutions)
    return new_body


def replace_keymap(content: str, to_index: int, new_keymap: str) -> str:
    """Replace an existing keymap with a new one."""
    print(f"{file_indentation}\t🔹 Replacing keymap {to_index}…")
    return re.sub(
        rf'<keyMap index="{to_index}">.*?</keyMap>',
        new_keymap,
        content,
        flags=re.DOTALL,
    )


def fix_keymap4_symbols_body(body: str) -> str:
    """
    Correct the symbols for Ctrl + and Ctrl - shortcuts inside a keymap body.
    Expects only the inner content of the keyMap, without <keyMap> tags.
    """
    print(f"{file_indentation}\t🔹 Fixing keymap 4 symbols in body…")

    # Replace output/action for code 24 with '+'
    body = re.sub(
        r'(<key code="24"[^>]*(output|action)=")[^"]*(")',
        r"\1+\3",
        body,
    )
    # Replace output/action for code 27 with '-'
    body = re.sub(
        r'(<key code="27"[^>]*(output|action)=")[^"]*(")',
        r"\1-\3",
        body,
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
        r'\1\n\t\t<keyMap index="9">' + keymap_9 + "</keyMap>",
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
