import re
from pathlib import Path

# For the moment, keylayout files are created with KbdEdit 24.7.0
# Some issues corrected here won’t be needed to be corrected anymore if KbdEdit is upgraded
# See http://www.kbdedit.com/release_notes.html


# ================================
# ======= Common utilities =======
# ================================


def get_file_paths(
    input_path: str = None, directory_path: str = None, suffix: str = ""
):
    overwrite = False
    if directory_path:
        base_dir = Path(directory_path)
    else:
        base_dir = Path(__file__).parent

    if input_path:
        file_paths = [base_dir / input_path]
        overwrite = True
    else:
        file_paths = list(base_dir.glob(f"*{suffix}.keylayout"))
    return file_paths, overwrite


def read_file(file_path: Path) -> str:
    print(f"Processing: {file_path}")
    with file_path.open("r", encoding="utf-8") as f:
        return f.read()


def write_file(file_path: Path, content: str):
    with file_path.open("w", encoding="utf-8") as f:
        f.write(content)
    print(f"Modified and saved: {file_path}")


def extract_keymap(content, index):
    match = re.search(
        rf'(<keyMap index="{index}">)(.*?)(</keyMap>)', content, flags=re.DOTALL
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1), match.group(2), match.group(3)


def apply_key_substitutions(content, substitutions):
    for pattern, replacement in substitutions.items():
        content = re.sub(
            rf"\s*<key {pattern}", f"\n\t\t\t{replacement}", content
        )
    return content


# ========================================
# ======= 1/ Correct the keylayout =======
# ========================================


def correct_keylayout(input_path: str = None, directory_path: str = None):
    file_paths, overwrite = get_file_paths(
        input_path, directory_path, suffix="_v0"
    )

    for file_path in file_paths:
        new_file_path = file_path.with_name(
            file_path.stem.replace("_v0", "") + file_path.suffix
        )

        if not overwrite and new_file_path.exists():
            continue

        content = read_file(file_path)

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

        write_file(new_file_path, content)


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


# ===============================================
# ======= 2/ Create the "_plus" keylayout =======
# ===============================================


mappings = {
    "e_circumflex_deadkey": {
        "trigger": "ê",
        "map": [
            ("a", "â"),
            ("à", "œ"),
            ("é", "æ"),
            ("e", "oe"),
            ("é", "aî"),
            ("i", "î"),
            ("o", "ô"),
            ("u", "û"),
        ],
    },
    "comma_j_letters_sfbs": {
        "trigger": ",",
        "map": [
            ("à", "j"),
            ("a", "ja"),
            ("e", "je"),
            ("é", "jé"),
            ("i", "ji"),
            ("o", "jo"),
            ("u", "ju"),
            ("ê", "ju"),
            ("'", "j’"),
            ("’", "j’"),
            # Far letters
            ("è", "z"),
            ("y", "k"),
            ("c", "ç"),
            ("x", "où"),
            ("s", "qu"),
            # SFBs
            ("f", "fl"),
            ("g", "gl"),
            ("h", "ph"),
            ("z", "bj"),
            ("v", "dv"),
            ("n", "nl"),
            ("t", "pt"),
            ("r", "rq"),
            ("q", "qu’"),
            ("m", "ms"),
            ("d", "ds"),
            ("l", "cl"),
            ("p", "xp"),
        ],
    },
    "e": {
        "trigger": "e",
        "map": [
            ("ê", "eo"),
            ("é", "ez"),
        ],
    },
    "e_acute_sfbs": {
        "trigger": "é",
        "map": [
            ("ê", "â"),
        ],
    },
    "e_grave_y": {
        "trigger": "è",
        "map": [
            ("y", "ié"),
        ],
    },
    "y_e_grave": {
        "trigger": "y",
        "map": [
            ("è", "éi"),
        ],
    },
    "a_grave_suffixes": {
        "trigger": "à",
        "map": [
            # SFB with "bu" or "ub"
            ("★", "bu"),
            ("j", "bu"),
            ("u", "ub"),
            # Common suffixes
            ("a", "aire"),
            ("c", "ction"),
            ("cd", "could"),
            ("shd", "should"),
            ("d", "would"),
            ("é", "ying"),
            ("ê", "able"),
            ("f", "iste"),
            ("g", "ought"),
            ("h", "techn"),
            ("i", "ight"),
            ("k", "ique"),
            ("l", "elle"),
            ("p", "ence"),
            ("m", "isme"),
            ("n", "ation"),
            ("q", "ique"),
            ("r", "erre"),
            ("s", "ement"),
            ("t", "ettre"),
            ("v", "ment"),
            ("x", "ieux"),
            ("z", "ez-vous"),
            ("'", "ance"),
            ("’", "ance"),
        ],
    },
    "q_with_u": {
        "trigger": "q",
        "map": [
            ("a", "qua"),
            ("e", "que"),
            ("é", "qué"),
            ("è", "què"),
            ("ê", "quê"),
            ("i", "qui"),
            ("o", "quo"),
            ("'", "qu’"),
            ("’", "qu’"),
        ],
    },
    "typographic_apostrophe": {
        "trigger": "'",
        "map": [
            ("a", "’a"),
            ("e", "’e"),
            ("é", "’é"),
            ("è", "’è"),
            ("ê", "’ê"),
            ("i", "’i"),
            ("o", "’o"),
            ("t", "’t"),
            ("u", "’u"),
            ("y", "’y"),
        ],
    },
    "roll_ct": {
        "trigger": "p",
        "map": [
            ("'", "ct"),
        ],
    },
    "roll_ck": {
        "trigger": "c",
        "map": [
            ("x", "ck"),
        ],
    },
    "roll_sk": {
        "trigger": "s",
        "map": [
            ("x", "sk"),
        ],
    },
    "roll_wh": {
        "trigger": "h",
        "map": [
            ("c", "wh"),
        ],
    },
    "rolls_hashtag": {
        "trigger": "#",
        "map": [
            ("!", " := "),
            ("(", '")'),
            ("[", '"]'),
        ],
    },
    "rolls_left_parenthesis": {
        "trigger": "(",
        "map": [
            ("#", '("'),
        ],
    },
    "rolls_left_bracket": {
        "trigger": "[",
        "map": [
            ("#", '["'),
        ],
    },
    "rolls_right_bracket": {
        "trigger": "]",
        "map": [
            ("#", '"]'),
        ],
    },
    "rolls_exclamation_mark": {
        "trigger": "!",
        "map": [
            ("#", " != "),
        ],
    },
    "rolls_backslash": {
        "trigger": "\\",
        "map": [
            ('"', "/*"),
        ],
    },
    "rolls_quote": {
        "trigger": '"',
        "map": [
            ("\\", "*/"),
        ],
    },
    "rolls_dollar": {
        "trigger": "$",
        "map": [
            ("=", " => "),
        ],
    },
    "rolls_equal": {
        "trigger": "=",
        "map": [
            ("$", " <= "),
        ],
    },
    "rolls_plus": {
        "trigger": "+",
        "map": [
            ("?", " -> "),
        ],
    },
    "rolls_question_mark": {
        "trigger": "?",
        "map": [
            ("+", " <- "),
        ],
    },
}


def add_uppercase_mappings(orig_mappings):
    """
    Generate mappings for uppercase triggers.
    - Alphabetic triggers become uppercase.
    - Special triggers can be replaced by one or more alternatives defined in `special_upper_triggers`.
    - All outputs are capitalized (titlecase).
    """
    # Define special triggers and their uppercase replacements (can be multiple)
    special_upper_triggers = {
        ",": [";", ":"],
    }

    new_mappings = orig_mappings.copy()  # Keep the original intact
    for key, data in orig_mappings.items():
        trigger = data["trigger"]
        new_map = [(k, v.title()) for k, v in data["map"]]

        if trigger in special_upper_triggers:
            # Create a mapping for each replacement
            for i, replacement in enumerate(special_upper_triggers[trigger]):
                upper_key = f"{key}_upper{i}"
                new_mappings[upper_key] = {
                    "trigger": replacement,
                    "map": new_map,
                }
        elif trigger.isalpha():
            upper_key = key + "_upper"
            new_mappings[upper_key] = {
                "trigger": trigger.upper(),
                "map": new_map,
            }

    return new_mappings


def escape_quotes_in_mappings(mappings):
    """
    Go through all mappings and replace every " character
    in the outputs with &#x0022; to avoid XML issues.
    """
    new_mappings = {}
    for key, data in mappings.items():
        trigger = data["trigger"]
        fixed_map = []
        for trig, out in data["map"]:
            fixed_out = out.replace('"', "&#x0022;")
            fixed_map.append((trig, fixed_out))
        new_mappings[key] = {
            "trigger": trigger,
            "map": fixed_map,
        }
    return new_mappings


mappings = add_uppercase_mappings(mappings)
mappings = escape_quotes_in_mappings(mappings)


def create_keylayout_plus(input_path: str, directory_path: str = None):
    """
    Create a '_plus' variant of the corrected keylayout, with extra actions.
    """
    file_paths, overwrite = get_file_paths(input_path, directory_path)

    for file_path in file_paths:
        new_file_path = file_path.with_name(
            file_path.stem + "_plus" + file_path.suffix
        )

        if not overwrite and new_file_path.exists():
            continue

        content = read_file(file_path)
        content = append_plus_to_keyboard_name(content)
        start_layer = find_next_available_layer(content)

        for i, (feature, data) in enumerate(mappings.items()):
            layer = start_layer + i
            trigger_key = data["trigger"]

            # Assign trigger key to this layer
            content = assign_action_layer(content, trigger_key, layer)

            # Add trigger key as dead key
            content = add_terminator_state(content, layer, trigger_key)

            # Add all feature actions
            for action_id, output in prepare_mapping(data["map"]):
                content = add_action_state(content, action_id, layer, output)

        write_file(new_file_path, content)


def append_plus_to_keyboard_name(content: str) -> str:
    """
    Appends ' Plus' to the keyboard name in the <keyboard> tag.
    """
    pattern = r'(<keyboard\b[^>]*\bname=")([^"]+)(")'

    def repl(match):
        prefix, name, suffix = match.groups()
        if not name.endswith(" Plus"):
            name += " Plus"
        return f"{prefix}{name}{suffix}"

    return re.sub(pattern, repl, content)


def find_next_available_layer(content: str) -> int:
    """
    Scans the keylayout content to find the highest layer number in use
    and returns the next available layer number.
    """
    # Find all 'when state="sX"' numbers
    state_indices = [int(m) for m in re.findall(r'state="s(\d+)"', content)]
    # Find all 'next="sX"' numbers
    next_indices = [int(m) for m in re.findall(r'next="s(\d+)"', content)]

    max_layer = max(state_indices + next_indices, default=0)
    next_layer = max_layer + 1
    print(f"Next available layer: s{next_layer}")
    return next_layer


def prepare_mapping(mapping):
    """
    Given a base mapping, return a merged mapping including:
    - original mapping
    - automatically generated uppercase mapping
    - no duplicate keys
    """

    def merge_mappings(*mappings):
        seen = set()
        merged = []
        for m in mappings:
            for key, output in m:
                if key not in seen:
                    merged.append((key, output))
                    seen.add(key)
        return merged

    mapping_upper = create_uppercase_mapping(mapping)
    return merge_mappings(mapping, mapping_upper)


def create_uppercase_mapping(mapping, titlecase=False):
    """
    Given a mapping of lowercase keys to outputs, generate a mapping for uppercase keys.
    Only letters are uppercased; other symbols are left unchanged.
    """
    uppercase_mapping = []
    for key, output in mapping:
        # Uppercase the key if it is a letter
        key_upper = key.upper() if key.isalpha() else key

        # Uppercase the output if it starts with a letter
        if output and output[0].isalpha():
            if titlecase:
                output_upper = output[0].upper() + output[1:]
            else:
                output_upper = output.upper()
        else:
            output_upper = output

        uppercase_mapping.append((key_upper, output_upper))
    return uppercase_mapping


def add_action_state(
    content: str, action_id: str, state_number: int, output: str
) -> str:
    """
    Insert a new <when state="sX" output="..."/> line inside the <action id="..."> block.
    Raises a ValueError if a <when> with the same state already exists.
    """
    pattern = rf'(<action id="{re.escape(action_id)}">)(.*?)(</action>)'

    def repl(match):
        header, body, footer = match.groups()

        # Check if the state already exists
        if re.search(rf'state="s{state_number}"', body):
            raise ValueError(
                f'Action "{action_id}" already has state s{state_number} defined.'
            )

        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t\t{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)


def add_terminator_state(content: str, state_number: int, output: str) -> str:
    """
    Add a <when state="sX" output="..."/> line inside the <terminators> block.
    Raises ValueError if the state already exists.
    """
    pattern = r"(<terminators>)(.*?)(</terminators>)"

    def repl(match):
        header, body, footer = match.groups()
        # Check if state already exists
        if re.search(rf'<when state="s{state_number}"', body):
            raise ValueError(
                f"State s{state_number} already exists in <terminators> block."
            )
        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)


def assign_action_layer(content: str, action_id: str, layer_num: int) -> str:
    """
    Assigns a next state (layer) to a single <action id="..."> in the content.
    Modifies the default <when state="none"/> line to include a 'next' state.
    """
    pattern = rf'(<action id="{re.escape(action_id)}">)(.*?)(</action>)'

    def repl(match):
        full_header, body, footer = match.groups()
        # Replace default state="none" with next layer
        body = re.sub(
            r'<when state="none"[^>]*>',
            f'<when state="none" next="s{layer_num}"/>',
            body,
        )
        return f"{full_header}{body}{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)


# ===========================
# ======= Launch code =======
# ===========================

if __name__ == "__main__":
    # correct_keylayout()
    correct_keylayout("Ergopti_v2.2.0_v0.keylayout")
    create_keylayout_plus("Ergopti_v2.2.0.keylayout")
