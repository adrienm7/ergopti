import html
import os
import re

import yaml

try:
    from lxml import etree as LET
except ImportError:
    LET = None


def main(keylayout_name="Ergopti_v2.2.0.keylayout"):
    print(f"[INFO] Using keylayout: {keylayout_name}")
    macos_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../macos")
    )
    if not os.path.isdir(macos_dir):
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")

    # Read keylayout file
    print("[INFO] Reading keylayout file...")
    macos_data, keylayout_path = read_keylayout_file(macos_dir, keylayout_name)

    # Check base.xkb file
    xkb_path = os.path.join(os.path.dirname(__file__), "base.xkb")
    if not os.path.isfile(xkb_path):
        raise FileNotFoundError(f"base.xkb file not found: {xkb_path}")
    print("[INFO] Reading base.xkb template...")
    xkb_content = read_xkb_template(xkb_path)

    # Load unicode to Linux symbol mapping from YAML
    yaml_path = os.path.join(os.path.dirname(__file__), "key_sym.yaml")
    print("[INFO] Loading YAML mapping (not used directly)...")
    load_yaml_mapping(yaml_path)

    # Extract keymaps for layers 0 to 4 (indexes 0 to 4)
    print("[INFO] Extracting keymaps for layers 0, 3, 5, 6, 4...")
    keymaps = [extract_keymap_body(macos_data, i) for i in [0, 3, 5, 6, 4]]

    # Build deadkey trigger map
    print("[INFO] Building deadkey trigger map...")
    deadkey_triggers = extract_deadkey_triggers(keylayout_path)

    # Generate XKB content
    print("[INFO] Generating XKB content...")
    xkb_out_content = generate_xkb_content(
        xkb_content, keymaps, deadkey_triggers
    )

    # Determine output file names
    base_name = os.path.splitext(os.path.basename(keylayout_name))[0]
    xkb_out_path = os.path.join(os.path.dirname(__file__), f"{base_name}.xkb")
    xcompose_out_path = os.path.splitext(xkb_out_path)[0] + ".XCompose"

    # Write XKB file
    print(f"[INFO] Writing XKB output to {xkb_out_path}")
    write_file(xkb_out_path, xkb_out_content)

    # Write XCompose file
    print(f"[INFO] Writing XCompose output to {xcompose_out_path}")
    parse_actions_for_xcompose(keylayout_path, xcompose_out_path)


def unicode_repr(s):
    """Return a string as a quoted char and Uxxxx code(s) for XCompose comment."""
    if not s:
        return '""'
    return f'"{s}" ' + " ".join(f"U{ord(c):04X}" for c in s)


def clean_invalid_xml_chars(xml_text):
    """Remove invalid XML char references (e.g. &#x0008;) except tab, LF, CR."""

    def repl(match):
        val = int(match.group(1), 16)
        if val in (0x09, 0x0A, 0x0D):
            return match.group(0)
        if val < 0x20:
            return ""
        return match.group(0)

    return re.sub(r"&#x([0-9A-Fa-f]{1,6});", repl, xml_text)


def parse_actions_for_xcompose(keylayout_path, xcompose_path):
    """Parse the <actions> block and write a .XCompose file, only for deadkey states (state != none), with blank lines between deadkey groups."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return
    print(
        f"[INFO] Parsing actions from {keylayout_path} and writing XCompose to {xcompose_path}"
    )
    with open(keylayout_path, encoding="utf-8") as f:
        xml_text = f.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    if actions is None:
        print("[WARNING] No <actions> block found.")
        return
    lines = []
    by_deadkey = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            output = when.attrib.get("output")
            if not output:
                continue
            # Only keep deadkey states (not none)
            if state and state.startswith("s") and state[1:].isdigit():
                state = f"dead_{int(state[1:])}"
            if state and state != "none":
                by_deadkey.setdefault(state, []).append((action_id, output))
    first = True
    for deadkey in sorted(by_deadkey.keys()):
        if not first:
            lines.append("")  # blank line between deadkey groups
        first = False
        for action_id, output in sorted(by_deadkey[deadkey]):
            seq = []
            if deadkey:
                seq.append(f"<{deadkey}>")
            if action_id:
                seq.append(f"<{action_id}>")
            out = unicode_repr(output)
            lines.append(f"{' '.join(seq)}\t: {out} # {output}")
    with open(xcompose_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def extract_keymap_body(body: str, index: int) -> str:
    """Extract the inner body of a keyMap by index."""
    match = re.search(
        rf'<keyMap index="{index}">(.*?)</keyMap>',
        body,
        flags=re.DOTALL,
    )
    if not match:
        raise ValueError(f'<keyMap index="{index}"> block not found.')
    return match.group(1)


def get_symbol(keymap_body: str, macos_code: int) -> str:
    """Extract the symbol (output or action) for a given macOS key code in a keyMap body. Returns the value (e.g. 'a', 'A', etc) or '' if not found."""
    match = re.search(
        rf'<key[^>]*code="{macos_code}"[^>]*(output|action)="([^"]+)"',
        keymap_body,
    )
    return match.group(2) if match else ""


# Linux <-> macOS keycode mapping (XKB key, macOS code)
linux_to_macos_keycodes = [
    ("<SPCE>", 49),
    ("<TLDE>", 10),
    ("<AE01>", 18),
    ("<AE02>", 19),
    ("<AE03>", 20),
    ("<AE04>", 21),
    ("<AE05>", 23),
    ("<AE06>", 22),
    ("<AE07>", 26),
    ("<AE08>", 28),
    ("<AE09>", 25),
    ("<AE10>", 29),
    ("<AE11>", 27),
    ("<AE12>", 24),
    ("<AD01>", 12),
    ("<AD02>", 13),
    ("<AD03>", 14),
    ("<AD04>", 15),
    ("<AD05>", 17),
    ("<AD06>", 16),
    ("<AD07>", 32),
    ("<AD08>", 34),
    ("<AD09>", 31),
    ("<AD10>", 35),
    ("<AD11>", 33),
    ("<AD12>", 30),
    ("<AC01>", 0),
    ("<AC02>", 1),
    ("<AC03>", 2),
    ("<AC04>", 3),
    ("<AC05>", 5),
    ("<AC06>", 4),
    ("<AC07>", 38),
    ("<AC08>", 40),
    ("<AC09>", 37),
    ("<AC10>", 41),
    ("<AC11>", 39),
    ("<BKSL>", 42),
    ("<LSGT>", 50),
    ("<AB01>", 6),
    ("<AB02>", 7),
    ("<AB03>", 8),
    ("<AB04>", 9),
    ("<AB05>", 11),
    ("<AB06>", 45),
    ("<AB07>", 46),
    ("<AB08>", 43),
    ("<AB09>", 47),
    ("<AB10>", 44),
]


def symbol_to_linux_name(symbol):
    """Convert a symbol to its Unicode codepoint in Uxxxx format (e.g., U2076). If the symbol is empty or 'NoSymbol', return 'NoSymbol'. If the symbol is more than one character, return a space-separated list of Uxxxx for each character."""
    if not symbol or symbol == "NoSymbol":
        return "NoSymbol"
    decoded = html.unescape(symbol)
    return " ".join(f"U{ord(c):04X}" for c in decoded)


def load_yaml_mapping(yaml_path):
    """Load a YAML mapping file (not used directly)."""
    with open(yaml_path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def read_keylayout_file(macos_dir, keylayout_name):
    """Read the keylayout file and return its content and path."""
    keylayout_path = os.path.join(macos_dir, keylayout_name)
    with open(keylayout_path, encoding="utf-8") as f:
        return f.read(), keylayout_path


def read_xkb_template(xkb_path):
    """Read the base XKB template file."""
    with open(xkb_path, encoding="utf-8") as f:
        return f.read()


def generate_xkb_content(xkb_content, keymaps, deadkey_triggers):
    """Generate the XKB output content from the keymaps and deadkey triggers."""
    for xkb_key, macos_code in linux_to_macos_keycodes:
        symbols = []
        comment_symbols = []
        for layer, keymap_body in enumerate(keymaps):
            symbol = get_symbol(keymap_body, macos_code)
            if symbol in deadkey_triggers:
                linux_name = f"<{deadkey_triggers[symbol]}>"
            else:
                linux_name = symbol_to_linux_name(symbol)
            symbols.append(linux_name)
            if symbol:
                decoded = html.unescape(symbol)
                if len(decoded) > 1:
                    comment_symbols.append(f'"{decoded}"')
                else:
                    comment_symbols.append(decoded)
            else:
                comment_symbols.append("")
        pattern = rf"key {re.escape(xkb_key)}[^{chr(10)}]*;"
        quoted_symbols = [f'"{s}"' for s in symbols]
        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
        xkb_content = re.sub(pattern, replacement, xkb_content)
    return xkb_content


def write_file(path, content):
    """Write content to a file."""
    print(f"[INFO] Writing file: {path}")
    with open(path, "w", encoding="utf-8") as f:
        f.write(content)


def extract_deadkey_triggers(keylayout_path):
    """Return a dict: macOS action id -> deadkey name (dead_1, dead_2, ...) if next='sX' is present."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    print(f"[INFO] Extracting deadkey triggers from {keylayout_path}")
    with open(keylayout_path, encoding="utf-8") as f:
        xml_text = f.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    deadkey_map = {}
    if actions is not None:
        for action in actions.findall("action"):
            action_id = action.attrib.get("id")
            for when in action.findall("when"):
                next_attr = when.attrib.get("next")
                if (
                    next_attr
                    and next_attr.startswith("s")
                    and next_attr[1:].isdigit()
                ):
                    deadkey_map[action_id] = f"dead_{int(next_attr[1:])}"
    return deadkey_map


if __name__ == "__main__":
    main()
