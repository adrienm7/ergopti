import os
import re
import shutil
import zipfile
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


# ===============================
# ======= Bundle creation =======
# ===============================


def create_bundle(
    version: str,
    *keylayout_files: str,
    directory_path: str = None,
    zip_bundle: bool = True,
    cleanup: bool = True,
):
    """
    Create a .bundle package for macOS keyboard layouts.
    Each keylayout gets a corresponding logo with the same name.
    """
    base_dir = Path(directory_path) if directory_path else Path(__file__).parent
    bundle_name = f"Ergopti_{version}.bundle"
    bundle_path = base_dir / bundle_name

    if bundle_path.exists():
        shutil.rmtree(bundle_path)

    resources_path = bundle_path / "Contents" / "Resources"
    resources_path.mkdir(parents=True, exist_ok=True)

    info_plist_entries = []
    for f in keylayout_files:
        src = Path(base_dir) / f
        if not src.exists():
            raise FileNotFoundError(f"Keylayout file not found: {src}")
        info_plist_entries.append(
            copy_keylayout_and_logo(src, base_dir, resources_path)
        )

    # Write Info.plist
    info_plist_content = generate_info_plist(version, info_plist_entries)
    info_plist_path = bundle_path / "Contents" / "Info.plist"
    info_plist_path.write_text(info_plist_content, encoding="utf-8")

    # Write version.plist
    version_plist_content = generate_version_plist(version)
    version_plist_path = bundle_path / "Contents" / "version.plist"
    version_plist_path.write_text(version_plist_content, encoding="utf-8")

    zip_path = None
    if zip_bundle:
        zip_path = bundle_path.with_suffix(".bundle.zip")
        zip_bundle_folder(bundle_path, zip_path)
        if cleanup:
            shutil.rmtree(bundle_path)

    return bundle_path if not cleanup else None, zip_path


def copy_keylayout_and_logo(
    src: Path, base_dir: Path, resources_path: Path
) -> str:
    """Copy the keylayout and its logo, renaming the logo to match the keylayout filename."""

    # Copy keylayout file
    dest_layout = resources_path / src.name
    shutil.copy(src, dest_layout)

    # Determine logo to use based on keyboard name containing "plus" (case-insensitive)
    content = src.read_text(encoding="utf-8")
    match = re.search(r'<keyboard\b[^>]*\bname="([^"]+)"', content)
    keyboard_name_in_xml = match.group(1) if match else src.stem

    if "plus" in keyboard_name_in_xml.lower():
        logo_filename = "logo_ergopti_plus.icns"
    else:
        logo_filename = "logo_ergopti.icns"

    logo_path = base_dir / logo_filename
    if logo_path.exists():
        # Rename logo to match keylayout filename
        dest_logo = resources_path / f"{src.stem}.icns"
        shutil.copy(logo_path, dest_logo)
        icon_tag = f"""
        <key>TISIconIsTemplate</key>
        <false/>
        <key>ICNS</key>
        <string>{dest_logo.name}</string>"""
        print(f"Added logo {logo_filename} as {dest_logo.name}")
    else:
        print(f"⚠️ Logo file not found: {logo_filename}, continuing without it")
        icon_tag = ""

    # Use keylayout filename as the plist key
    plist_key = f"KLInfo_{src.stem}"

    # Generate Info.plist entry
    return f"""
    <key>{plist_key}</key>
    <dict>
        <key>TICapsLockLanguageSwitchCapable</key>
        <true/>{icon_tag}
        <key>TISInputSourceID</key>
        <string>org.sil.ukelele.keyboardlayout.ergopti.{src.stem.lower()}</string>
        <key>TISIntendedLanguage</key>
        <string>fr</string>
    </dict>"""


def generate_info_plist(version: str, entries: list[str]) -> str:
    """Generate the full Info.plist content without localized translations."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.sil.ukelele.keyboardlayout.ergopti</string>
    <key>CFBundleName</key>
    <string>Ergopti</string>
    <key>CFBundleVersion</key>
    <string>{version}</string>
    {"".join(entries)}
</dict>
</plist>
"""


def generate_version_plist(version: str) -> str:
    """Generate the version.plist content dynamically."""
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" 
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>BuildVersion</key>
    <string>{version}</string>
    <key>ProjectName</key>
    <string>Ergopti</string>
    <key>SourceVersion</key>
    <string>{version}</string>
</dict>
</plist>
"""


def zip_bundle_folder(bundle_path: Path, zip_path: Path):
    """Zip the entire bundle folder so that unzipping preserves the bundle folder."""
    if zip_path.exists():
        zip_path.unlink()
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, _, files in os.walk(bundle_path):
            for file in files:
                file_path = Path(root) / file
                # Relative path from the parent of the bundle folder to keep the bundle folder itself
                relative_path = file_path.relative_to(bundle_path.parent)
                zipf.write(file_path, relative_path)
    print(f"Zipped bundle at: {zip_path}")


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


# ===============================================
# ======= 2/ Create the "_plus" keylayout =======
# ===============================================


mappings = {
    "e_circumflex_deadkey": {
        "trigger": "ê",
        "map": [
            ("à", "æ"),
            ("a", "â"),
            ("é", "aî"),
            ("e", "oe"),
            ("i", "î"),
            ("j", "œu"),
            ("★", "œu"),
            ("o", "ô"),
            ("u", "û"),
        ],
    },
    "comma_j_letters_sfbs": {
        "trigger": ",",
        "map": [
            ("à", "j"),
            ("a", "ja"),
            ("é", "jé"),
            ("ê", "ju"),
            ("e", "je"),
            ("i", "ji"),
            ("o", "jo"),
            ("u", "ju"),
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
            ("é", "ez"),
            ("ê", "eo"),
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
            ("j", "bu"),
            ("★", "bu"),
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
            ("h", "’h"),
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
    "rolls_chevron_left": {
        "trigger": "<",
        "map": [
            ("@", "</"),
            # ("%", " <= "),
        ],
    },
    "rolls_chevron_right": {
        "trigger": ">",
        "map": [
            ("%", " >= "),
        ],
    },
    "rolls_parenthesis_left": {
        "trigger": "(",
        "map": [
            ("#", '("'),
        ],
    },
    "rolls_bracket_left": {
        "trigger": "[",
        "map": [
            ("#", '["'),
            (")", ' = "'),
        ],
    },
    "rolls_bracket_right": {
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
        if len(data["map"]) == 0:
            continue
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


def escape_symbols_in_mappings(orig_mappings):
    """
    Go through all mappings and replace every " character
    in the outputs with &#x0022; to avoid XML issues.
    """
    new_mappings = {}
    for key, data in orig_mappings.items():
        trigger = data["trigger"]
        fixed_map = []
        if len(data["map"]) == 0:
            new_mappings[key] = {
                "trigger": trigger,
                "map": [],
            }
            continue
        for trig, out in data["map"]:
            fixed_out = out.replace('"', "&#x0022;").replace("<", "&#x003C;")
            fixed_map.append((trig, fixed_out))
        new_mappings[key] = {
            "trigger": trigger,
            "map": fixed_map,
        }
    return new_mappings


mappings = add_uppercase_mappings(mappings)
mappings = escape_symbols_in_mappings(mappings)


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
        content = ergopti_plus_altgr_symbols(content)
        content = ergopti_plus_shiftaltgr_symbols(content)

        start_layer = find_next_available_layer(content)
        for i, (feature, data) in enumerate(mappings.items()):
            layer = start_layer + i
            trigger_key = data["trigger"]
            print(
                f"Adding feature '{feature}' with trigger '{trigger_key}' at layer s{layer}"
            )

            if len(data["map"]) == 0:
                continue

            # Assign trigger key to this layer
            content = ensure_action_block(content, trigger_key, trigger_key)
            content = assign_action_layer(content, trigger_key, layer)

            # Add trigger key as dead key
            content = add_terminator_state(content, layer, trigger_key)

            # Add all feature actions
            for action_id, output in data["map"]:
                print(f"  - action '{action_id}' → '{output}'")

                # Ensure any <key ... output="action_id"> is converted to action="action_id"
                # This preserves key codes/modifiers and avoids having <key ... output="..."> which would break action linking
                content = ensure_key_uses_action(content, action_id)

                # Now add the when state to the corresponding <action id="..."> (ensure_action_block is called inside)
                content = add_action_state(content, action_id, layer, output)

        # Correct problem of the " character
        content = (
            content.replace('id="""', "id='\"'")
            .replace('output="""', "output='\"'")
            .replace(
                '<key code="8" output=\'"\'/>', '<key code="8" action=\'"\'/>'
            )
            .replace('"/>"/>', '"/>')
            .replace('output="<"', 'output="&#x003C;"')
        )

        write_file(new_file_path, content)


def ensure_key_uses_action(content: str, action_id: str) -> str:
    """
    Ensure that in <keyMap index="1|2|3|5"> blocks,
    any <key ... output="action_id" or action="action_id"> becomes
    <key ... action="action_id"> (preserving other attributes).
    Only modifies <key> tags that actually reference the action_id;
    leaves other keyMaps untouched.
    """

    literal = re.escape(action_id)
    hex_variants = []
    if len(action_id) == 1:
        codepoint = ord(action_id)
        hex_variants = [f"&#x{codepoint:04X};", f"&#x{codepoint:04x};"]

    def process_keymap(match):
        # use explicit group access to avoid unpacking issues
        header = match.group(1)
        body = match.group(2)
        footer = match.group(3)

        def repl_key(tag_match):
            tag = tag_match.group(0)
            found = False
            if re.search(rf'\b(?:output|action)="{literal}"', tag):
                found = True
            else:
                for hv in hex_variants:
                    if re.search(
                        rf'\b(?:output|action)="{re.escape(hv)}"', tag
                    ):
                        found = True
                        break

            if not found:
                return tag  # leave untouched

            # remove only output="..." and action="..."
            new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", tag)

            # insert the unified action="..."
            if new_tag.endswith("/>"):
                new_tag = new_tag[:-2].rstrip() + f' action="{action_id}"/>'
            else:
                new_tag = new_tag[:-1].rstrip() + f' action="{action_id}">'
            return new_tag

        body = re.sub(r"<key\b[^>]*\/?>", repl_key, body)
        return f"{header}{body}{footer}"

    # NON-CAPTURING group for the index alternation to ensure exactly 3 capture groups
    pattern = r'(<keyMap index="(?:1|2|3|5)">)(.*?)(</keyMap>)'
    return re.sub(pattern, process_keymap, content, flags=re.DOTALL)


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


def ergopti_plus_altgr_symbols(content: str) -> str:
    """
    In <keyMap index="5">:
      - If a <key ...> has output="ç" or action="ç", replace its output/action attributes
        with a single action="!" (preserving other attributes such as code/modifiers).
      - If a <key ...> has output="œ" or action="œ", replace its output/action attributes
        with a single action="%".
      - Do NOT touch other <key> elements.
    After the keyMap modification, ensure <action id="!"> and <action id="%"> exist
    (they are inserted before the first </actions> if missing).
    """

    def replace_in_keymap(match):
        header, body, footer = match.groups()

        def repl_key(key_match):
            key_tag = key_match.group(0)
            # If this key contains ç (either as output or action)
            if re.search(r'(?:\boutput|\baction)="ç"', key_tag):
                # remove only output="..." and action="..." attributes from this key
                new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", key_tag)
                # insert action="!" before the final > or />
                if new_tag.endswith("/>"):
                    new_tag = new_tag[:-2].rstrip() + ' action="!"/>'
                else:
                    new_tag = new_tag[:-1].rstrip() + ' action="!">'
                return new_tag

            # If this key contains œ (either as output or action)
            if re.search(r'(?:\boutput|\baction)="œ"', key_tag):
                new_tag = re.sub(r'\s+(?:output|action)="[^"]*"', "", key_tag)
                if new_tag.endswith("/>"):
                    new_tag = new_tag[:-2].rstrip() + ' action="%"/>'
                else:
                    new_tag = new_tag[:-1].rstrip() + ' action="%">'
                return new_tag

            # Otherwise leave the key unchanged
            return key_tag

        # Replace only <key ...> elements inside this keyMap body
        body_fixed = re.sub(r"<key\b[^>]*\/?>", repl_key, body)
        return f"{header}{body_fixed}{footer}"

    # Apply only to keyMap index="5"
    pattern = r'(<keyMap index="5">)(.*?)(</keyMap>)'
    fixed = re.sub(pattern, replace_in_keymap, content, flags=re.DOTALL)

    fixed = ensure_action_block(fixed, "!", "!")
    fixed = ensure_action_block(fixed, "%", "%")

    return fixed


def ensure_action_block(doc: str, action_id: str, output_value: str) -> str:
    """
    Ensure an <action id="..."> block exists.
    - Matches <action ... id="ID" ...> or <action ... id='ID' ...> wherever the id attribute is placed.
    - If missing, inserts the block before the first </actions>, using the same indentation.
    """
    if action_id == "<":
        action_id = "&lt;"
    if action_id == ">":
        action_id = "&gt;"
    # Match <action ... id="action_id" ...> or with single quotes, id can be anywhere in the tag
    pattern = rf'<action\b[^>]*\bid\s*=\s*(["\']){re.escape(action_id)}\1'

    if not re.search(pattern, doc):
        # Try to detect indentation of the closing </actions> to keep style consistent
        m = re.search(r"^(?P<indent>\s*)</actions>", doc, flags=re.MULTILINE)
        indent = m.group("indent") if m else "\t"

        block = (
            f'{indent}<action id="{action_id}">\n'
            f'{indent}\t\t<when state="none" output="{output_value}"/>\n'
            f"{indent}\t</action>\n{indent}"
        )

        # Insert the block right before the first </actions>
        doc = re.sub(r"(</actions>)", block + r"\1", doc, count=1)

    return doc


def ergopti_plus_shiftaltgr_symbols(content):
    # This code replaces specific outputs in keymap index 6 = Shift + AltGr
    def replace_in_keymap(match):
        header, body, footer = match.groups()
        # output="Ç" → " !" (avec espace fine insécable avant le !)
        body = re.sub(r'(<key[^>]*(output|action)=")Ç(")', r"\1 !\3", body)
        return f"{header}{body}{footer}"

    content = re.sub(
        r'(<keyMap index="6">)(.*?)(</keyMap>)',
        replace_in_keymap,
        content,
        flags=re.DOTALL,
    )
    content = re.sub(
        r'(<keyMap index="7">)(.*?)(</keyMap>)',
        replace_in_keymap,
        content,
        flags=re.DOTALL,
    )

    return content


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
    content = ensure_action_block(content, action_id, action_id)

    def repl(match):
        header, body, footer = match.groups()

        # Check if the state already exists
        if re.search(rf'state="s{state_number}"', body):
            raise ValueError(
                f'Action "{action_id}" already has state s{state_number} defined.'
            )

        new_line = f'\t<when state="s{state_number}" output="{output}"/>'
        return f"{header}{body}{new_line}\n\t\t{footer}"

    content = re.sub(pattern, repl, content, flags=re.DOTALL)
    return content


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
    Works even if action_id is encoded as &lt; or &#x003C; in the XML.
    """
    # autoriser id="<" OU id="&lt;" OU id="&#x003C;"
    if action_id == "<":
        id_pattern = r"(?:<|&lt;|&#x003C;)"
    elif action_id == ">":
        id_pattern = r"(?:>|&gt;|&#x003E;)"
    else:
        id_pattern = re.escape(action_id)

    pattern = rf'(<action id="{id_pattern}">)(.*?)(</action>)'

    def repl(match):
        header, body, footer = match.groups()
        body = re.sub(
            r'<when state="none"[^>]*>',
            f'<when state="none" next="s{layer_num}"/>',
            body,
        )
        return f"{header}{body}{footer}"

    return re.sub(pattern, repl, content, flags=re.DOTALL)


# ===========================
# ======= Launch code =======
# ===========================

if __name__ == "__main__":
    # correct_keylayout()
    correct_keylayout("Ergopti_v2.2.0_v0.keylayout")
    create_keylayout_plus("Ergopti_v2.2.0.keylayout")
    create_bundle(
        "v2.2.0",
        "Ergopti_v2.2.0.keylayout",
        "Ergopti_v2.2.0_plus.keylayout",
        zip_bundle=True,
    )
