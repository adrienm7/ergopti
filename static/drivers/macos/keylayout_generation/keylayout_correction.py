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
    content = replace_keymap_index(content, from_index=0, to_index=4)
    content = fix_keymap4_symbols(content)

    print(f"{file_indentation}➕ Adding keymap 9…")
    content = add_keymap_select_9(content)
    content = add_keymap_9(content)

    print(f"{file_indentation}🎨 Cosmetic ordering and sorting…")
    content = reorder_modifiers_and_attributes(content)
    content = sort_keys(content)

    print("✅ Keylayout corrections complete.")
    return content


def fix_invalid_symbols(content: str) -> str:
    """Fix invalid XML symbols for <, >, & in action outputs."""
    print(f"{file_indentation}\t🔹 Fixing invalid symbols for <, >, &…")
    content = content.replace(
        """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&lt;"/>""",
        """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&#x003C;"/>""",
    )
    content = content.replace(
        """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&gt;"/>""",
        """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&#x003E;"/>""",
    )
    content = content.replace(
        """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&amp;"/>""",
        """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&#x0026;"/>""",
    )
    return content


def swap_keys_10_and_50(content: str) -> str:
    """Swap key codes 10 and 50 in the content."""
    print(f"{file_indentation}\t🔹 Swapping key codes 10 and 50…")
    content = re.sub(r'code="50"', "TEMP_CODE", content)
    content = re.sub(r'code="10"', 'code="50"', content)
    content = re.sub(r"TEMP_CODE", 'code="10"', content)
    return content


def build_custom_keymap(index: int, base_body: str) -> str:
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


def extract_keymap(content: str, index: int):
    """Extract the header, body, and footer of a keyMap by index."""
    match = re.search(
        rf'(<keyMap index="{index}">)(.*?)(</keyMap>)', content, flags=re.DOTALL
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1), match.group(2), match.group(3)


def apply_key_substitutions(content: str, substitutions: dict) -> str:
    """Apply regex substitutions to the keys in a keyMap body."""
    for pattern, replacement in substitutions.items():
        content = re.sub(
            rf"\s*<key {pattern}", f"\n\t\t\t{replacement}", content
        )
    return content


def replace_keymap_index(content: str, from_index: int, to_index: int) -> str:
    """Copy a keymap from one index to another, building a new keymap block."""
    print(
        f"{file_indentation}\t🔹 Replacing keymap {to_index} based on {from_index}…"
    )
    _, base_body, _ = extract_keymap(content, from_index)
    new_keymap = build_custom_keymap(to_index, base_body)
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
            r'(<key code="24"[^>]*(output|action)=")[^"]*(")', r"\1+\3", body
        )
        body = re.sub(
            r'(<key code="27"[^>]*(output|action)=")[^"]*(")', r"\1-\3", body
        )
        return f"{header}{body}{footer}"

    return re.sub(
        r'(<keyMap index="4">)(.*?)(</keyMap>)',
        replace_in_keymap,
        content,
        flags=re.DOTALL,
    )


def add_keymap_9(content: str) -> str:
    """Add keymap index 9 by copying keymap 4, convert actions to outputs."""
    print(f"{file_indentation}\t🔹 Adding keymap 9…")
    if '<keyMap index="9">' in content:
        print(f"{file_indentation}\t\t⚠️ Keymap 9 already exists, skipping.")
        return content

    _, base_body, _ = extract_keymap(content, 4)
    keymap_9 = build_custom_keymap(9, base_body)
    keymap_9 = re.sub(r'action="([^"]+)"', r'output="\1"', keymap_9)

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
