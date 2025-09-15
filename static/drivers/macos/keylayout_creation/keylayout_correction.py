import re

from common import (
    apply_key_substitutions,
    extract_keymap,
)

# For the moment, keylayout files are created with KbdEdit 24.7.0
# Some issues corrected here won’t be needed to be corrected anymore if KbdEdit is upgraded
# See http://www.kbdedit.com/release_notes.html


def keylayout_corrector(content):
    content = fix_invalid_symbols(content)
    content = swap_keys_10_and_50(content)

    # Add keymap 4
    content = replace_keymap_index(content, from_index=0, to_index=4)
    content = fix_keymap4_symbols(content)

    # Add keymap 9
    content = add_keymap_select_9(content)
    content = add_keymap_9(content)

    # Cosmetic changes to match what tools like Ukulele would output
    content = reorder_modifiers_and_attributes(content)
    content = sort_keys(content)

    return content


def fix_invalid_symbols(content):
    return (
        content.replace(
            """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&lt;"/>""",
            """\t\t<action id="&lt;">\n\t\t\t<when state="none" output="&#x003C;"/>""",
        )
        .replace(
            """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&gt;"/>""",
            """\t\t<action id="&gt;">\n\t\t\t<when state="none" output="&#x003E;"/>""",
        )
        .replace(
            """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&amp;"/>""",
            """\t\t<action id="&amp;">\n\t\t\t<when state="none" output="&#x0026;"/>""",
        )
    )


def swap_keys_10_and_50(content):
    content = re.sub(r'code="50"', "TEMP_CODE", content)
    content = re.sub(r'code="10"', 'code="50"', content)
    return re.sub(r"TEMP_CODE", 'code="10"', content)


def build_custom_keymap(index, base_body):
    substitutions = {
        'code="6"[^>]*?/>': '<key code="6" output="c"/>',
        'code="7"[^>]*?/>': '<key code="7" action="v"/>',
        'code="50"[^>]*?/>': '<key code="50" output="x"/>',
        'code="12"[^>]*?/>': '<key code="12" action="z"/>',
    }
    new_body = apply_key_substitutions(base_body, substitutions)
    return f'<keyMap index="{index}">{new_body}\n\t\t</keyMap>'


def replace_keymap_index(content, from_index, to_index):
    _, base_body, _ = extract_keymap(content, from_index)
    new_keymap = build_custom_keymap(to_index, base_body)
    return re.sub(
        rf'<keyMap index="{to_index}">.*?</keyMap>',
        new_keymap,
        content,
        flags=re.DOTALL,
    )


def fix_keymap4_symbols(content):
    # This code is for getting the Ctrl + and Ctrl - zoom shortcuts working
    def replace_in_keymap(match):
        # Replace only in this keymap (index 4)
        header, body, footer = match.groups()
        # code 24: "+" instead of "$"
        body = re.sub(
            r'(<key code="24"[^>]*(output|action)=")[^"]*(")', r"\1+\3", body
        )
        # code 27: "-" instead of "%"
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


def add_keymap_9(content):
    if '<keyMap index="9">' in content:
        return content
    _, base_body, _ = extract_keymap(content, 4)
    keymap_9 = build_custom_keymap(9, base_body)

    # Convert all action="..." to output="..." inside this new keyMap
    # Otherwise trying to do comamnd s for example will activate the action, so the deadkey on ergoptiplus, and not save
    keymap_9 = re.sub(r'action="([^"]+)"', r'output="\1"', keymap_9)

    return re.sub(
        r'(<keyMap index="8">.*?</keyMap>)',
        r"\1\n\t\t" + keymap_9,
        content,
        flags=re.DOTALL,
    )


def add_keymap_select_9(content):
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


def reorder_modifiers_and_attributes(content):
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


def sort_keys(content):
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
