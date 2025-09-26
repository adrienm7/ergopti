import datetime
import html
import json
import os
import re

import yaml

try:
    from lxml import etree as LET
except ImportError:
    LET = None

with open(
    os.path.join(
        os.path.dirname(__file__), "data", "linux_to_macos_keycodes.json"
    ),
    "r",
    encoding="utf-8",
) as keycodes_file:
    LINUX_TO_MACOS_KEYCODES = json.load(keycodes_file)

yaml_path = os.path.join(os.path.dirname(__file__), "data", "key_sym.yaml")
with open(yaml_path, encoding="utf-8") as yaml_file:
    mappings = yaml.safe_load(yaml_file)


def main(keylayout_name="Ergopti_v2.2.0.keylayout", use_date_in_filename=False):
    macos_dir = os.path.abspath(
        os.path.join(os.path.dirname(__file__), "../../macos")
    )
    if not os.path.isdir(macos_dir):
        raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")

    # Déduire le préfixe de base (ex: Ergopti_v2.2.0)
    base_prefix = os.path.splitext(keylayout_name)[0]
    variants = [base_prefix, base_prefix + "_plus"]

    for variant in variants:
        keylayout_file = variant + ".keylayout"
        print(f"[INFO] Using keylayout: {keylayout_file}")
        # Lecture du keylayout et du template XKB
        print("[INFO] Reading keylayout file...")
        macos_data, keylayout_path = read_keylayout_file(
            macos_dir, keylayout_file
        )
        xkb_path = os.path.join(os.path.dirname(__file__), "data", "base.xkb")
        if not os.path.isfile(xkb_path):
            raise FileNotFoundError(f"base.xkb file not found: {xkb_path}")
        print("[INFO] Reading base.xkb template...")
        xkb_content = read_xkb_template(xkb_path)

        # Gestion du nom de layout et affichage
        if use_date_in_filename:
            now = datetime.datetime.now()
            layout_id = f"{variant}_{now.year}_{now.month:02d}_{now.day:02d}_{now.hour:02d}h{now.minute:02d}"
            layout_name = f"France - {variant.replace('_', ' ').title().replace('V', 'v')} {now.year}/{now.month:02d}/{now.day:02d} {now.hour:02d}:{now.minute:02d}"
        else:
            layout_id = variant
            # Ergopti_v2.2.0_plus -> Ergopti v2.2.0 Plus
            layout_name = "France - " + variant.replace(
                "_", " "
            ).title().replace("V", "v")

        # Remplacement du nom de la disposition et du nom affiché
        xkb_content = re.sub(
            r'xkb_symbols\s+"[^"]+"', f'xkb_symbols "{layout_id}"', xkb_content
        )
        xkb_content = re.sub(
            r'name\[Group1\]=\s*"[^"]+";',
            f'name[Group1]= "{layout_name}";',
            xkb_content,
        )

        # Extraction des keymaps (0,2,5,6,4,4)
        print("[INFO] Extracting keymaps for layers 0, 2, 5, 6, 4, 4...")
        keymaps = [extract_keymap_body(macos_data, i) for i in [0, 2, 5, 6, 4]]
        keymaps.append(keymaps[4])

        # Extraction des deadkeys
        print("[INFO] Building deadkey trigger map...")
        deadkey_triggers = extract_deadkey_triggers(keylayout_path)

        # deadkey_name -> unicode_symbol
        print("[INFO] Building deadkey symbol map...")
        deadkey_symbol = build_deadkey_symbol_map(keylayout_path)

        # Génération du XKB
        print("[INFO] Generating XKB content...")
        xkb_out_content = generate_xkb_content(
            xkb_content, keymaps, deadkey_triggers, deadkey_symbol
        )

        # Fichiers de sortie : même nom que le keylayout d'entrée (sans extension)
        base_name = variant
        xkb_out_path = os.path.join(
            os.path.dirname(__file__), "..", f"{base_name}.xkb"
        )
        xcompose_out_path = os.path.splitext(xkb_out_path)[0] + ".XCompose"

        # Écriture des fichiers
        print(f"[INFO] Writing XKB output to {xkb_out_path}")
        write_file(xkb_out_path, xkb_out_content)
        print(f"[INFO] Writing XCompose output to {xcompose_out_path}")
        parse_actions_for_xcompose(keylayout_path, xcompose_out_path)


def build_deadkey_symbol_map(keylayout_path):
    """Construit la table deadkey_name -> unicode_symbol."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    deadkey_symbol = {}
    if actions is not None:
        for action in actions.findall("action"):
            action_id = action.attrib.get("id")
            for when in action.findall("when"):
                state = when.attrib.get("state")
                output = when.attrib.get("output")
                if not output:
                    continue
                if state and state.startswith("s") and state[1:].isdigit():
                    deadkey_name = f"dead_{int(state[1:])}"
                    if action_id and action_id not in deadkey_symbol:
                        deadkey_symbol[deadkey_name] = output
    return deadkey_symbol


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
    """Parse the <actions> block and write a .XCompose file, only for deadkey states (state != none), with blank lines between deadkey groups. Deadkey names are replaced by their real Unicode symbol or deadkey_<name> if found in YAML mapping."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return
    print(
        f"[INFO] Parsing actions from {keylayout_path} and writing XCompose to {xcompose_path}"
    )
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
    xml_text = clean_invalid_xml_chars(xml_text)
    tree = LET.fromstring(xml_text.encode("utf-8"))
    actions = tree.find(".//actions")
    if actions is None:
        print("[WARNING] No <actions> block found.")
        return
    # Build deadkey_name -> unicode_symbol mapping
    deadkey_symbol = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            output = when.attrib.get("output")
            if not output:
                continue
            if state and state.startswith("s") and state[1:].isdigit():
                deadkey_name = f"dead_{int(state[1:])}"
                # The symbol that triggers the deadkey is the output of the action with next=sX
                if action_id and action_id not in deadkey_symbol:
                    deadkey_symbol[deadkey_name] = output
    # Build Compose lines
    lines = []
    # Ajout des règles de fraction vers séquence multi-caractère
    if hasattr(generate_xkb_content, "fraction_map"):
        for frac, seq in generate_xkb_content.fraction_map.items():
            left = mappings.get(frac, f"U{ord(frac):04X}")
            lines.append(f'<{left}> : "{seq}"')
    lines.append(f'<{mappings.get("«", "guillemotleft")}> : "« "')
    lines.append(f'<{mappings.get("»", "guillemotright")}> : " »"')
    lines.append("")
    by_deadkey = {}
    for action in actions.findall("action"):
        action_id = action.attrib.get("id")
        for when in action.findall("when"):
            state = when.attrib.get("state")
            output = when.attrib.get("output")
            if not output:
                continue
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
            # Replace <dead_X> by its real Unicode symbol or deadkey_<name> if found in YAML
            if deadkey in deadkey_symbol:
                symbol = deadkey_symbol[deadkey]
                xkb_name = mappings.get(symbol)
                # Forcer dead_currency si le symbole est U+20B0
                codepoint = (
                    ord(symbol[0]) if symbol and len(symbol) > 0 else None
                )
                if codepoint == 0x20B0:
                    seq.append("<dead_currency>")
                # Forcer dead_diaeresis si le symbole est U+2792 (ou U+00A8)
                elif codepoint == 0x2792 or codepoint == 0x00A8:
                    seq.append("<dead_diaeresis>")
                # Forcer <mu> si le symbole est U+2126
                elif codepoint == 0x2126:
                    seq.append("<mu>")
                # Forcer <uparrow> si le symbole est U+02FA
                elif codepoint == 0x02FA:
                    seq.append("<uparrow>")
                # Forcer <downarrow> si le symbole est U+02FC
                elif codepoint == 0x02FC:
                    seq.append("<downarrow>")
                # Forcer <infinity> si le symbole est U+27E7
                elif codepoint == 0x27E7:
                    seq.append("<infinity>")
                elif xkb_name:
                    # Correction du nom deadkey_asciicircum -> dead_circumflex
                    if xkb_name == "asciicircum":
                        seq.append("<dead_circumflex>")
                    elif xkb_name == "currency":
                        seq.append("<dead_currency>")
                    elif xkb_name == "diaeresis":
                        seq.append("<dead_diaeresis>")
                    else:
                        seq.append(f"<deadkey_{xkb_name}>")
                else:
                    # Utiliser le mapping YAML si possible
                    left = mappings.get(
                        symbol,
                        f"U{ord(symbol[0]):04X}" if symbol else "NoSymbol",
                    )
                    seq.append(f"<{left}>")
            else:
                # Utiliser le mapping YAML si possible
                left = mappings.get(deadkey, deadkey)
                seq.append(f"<{left}>")
            if action_id:
                # Utiliser le mapping YAML si possible pour action_id
                left_action = mappings.get(action_id, action_id)
                seq.append(f"<{left_action}>")
            # On ne garde que le caractère entre guillemets pour la sortie XCompose
            out = f'"{output}"'
            # Remplacer < > par <space> dans la séquence
            seq = ["<space>" if s == "< >" else s for s in seq]
            lines.append(f"{' '.join(seq)}\t: {out}")
    content = 'include "%L"\n\n' + "\n".join(lines) + "\n"
    with open(xcompose_path, "w", encoding="utf-8") as file_out:
        file_out.write(content)


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
    """Extract the symbol (output or action) for a given macOS key code in a keyMap body. Returns the value (e.g. 'a', 'A', etc) or '' if not found. Décode les entités XML."""
    match = re.search(
        rf'<key[^>]*code="{macos_code}"[^>]*(output|action)="([^"]+)"',
        keymap_body,
    )
    if match:
        return html.unescape(match.group(2))
    return ""


def symbol_to_linux_name(symbol):
    """Convert a symbol to its XKB keysym name using direct character keys from the YAML mapping."""
    if not symbol or symbol == "NoSymbol":
        return "NoSymbol"

    decoded = html.unescape(symbol)
    for char in decoded:
        # Force uparrow/downarrow for ᵉ/ᵢ or U+02FA/U+02FC
        if ord(char) in (0x02FA, 0x1D49):  # ᵉ
            return "uparrow"
        if ord(char) in (0x02FC, 0x1D62):  # ᵢ
            return "downarrow"
        if char in mappings:
            return mappings[char]
        else:
            print(
                f"[WARNING] No mapping for {repr(char)} (U+{ord(char):04X}), using Unicode codepoint."
            )
            return f"U{ord(char):04X}"
    return "NoSymbol"


def read_keylayout_file(macos_dir, keylayout_name):
    """Read the keylayout file and return its content and path."""
    keylayout_path = os.path.join(macos_dir, keylayout_name)
    with open(keylayout_path, encoding="utf-8") as file_in:
        return file_in.read(), keylayout_path


def read_xkb_template(xkb_path):
    """Read the base XKB template file."""
    with open(xkb_path, encoding="utf-8") as file_in:
        return file_in.read()


def generate_xkb_content(
    xkb_content, keymaps, deadkey_triggers, deadkey_symbol_map=None
):
    """Génère le contenu XKB avec le type FOUR_LEVEL_SEMIALPHABETIC_CONTROL pour chaque touche."""
    # Liste des fractions Unicode à utiliser pour les substitutions multi-caractères
    fraction_symbols = [
        "⅓",
        "⅔",
        "⅕",
        "⅖",
        "⅗",
        "⅘",
        "⅙",
        "⅚",
        "⅛",
        "⅜",
        "⅝",
        "⅞",
    ]
    fraction_map = {}  # fraction_symbol -> original sequence
    fraction_idx = 0
    for xkb_key, macos_code in LINUX_TO_MACOS_KEYCODES:
        symbols = []
        comment_symbols = []
        for layer, keymap_body in enumerate(keymaps):
            symbol = get_symbol(keymap_body, macos_code)
            # Correction : ne remplacer que la couche 5 si « ou »
            # Cas particulier : forcer « et » sur la couche 5
            if layer == 4 and symbol == "«":
                linux_name = mappings.get("«", "guillemotleft")
                symbols.append(linux_name)
                comment_symbols.append("«")
                continue
            if layer == 4 and symbol == "»":
                linux_name = mappings.get("»", "guillemotright")
                symbols.append(linux_name)
                comment_symbols.append("»")
                continue
            # Substitution fraction généralisée pour tout symbole multi-caractère sauf « et »
            if symbol and len(symbol) >= 2 and symbol not in ("«", "»"):
                frac = fraction_symbols[fraction_idx % len(fraction_symbols)]
                if frac not in fraction_map:
                    fraction_map[frac] = symbol
                linux_name = mappings.get(frac, f"U{ord(frac):04X}")
                symbols.append(linux_name)
                comment_symbols.append(f'"{symbol}"')
                fraction_idx += 1
                continue
            # Gestion deadkey pour currency et asciicircum
            if symbol in deadkey_triggers:
                deadkey_name = deadkey_triggers[symbol]
                if deadkey_symbol_map and deadkey_name in deadkey_symbol_map:
                    unicode_sym = deadkey_symbol_map[deadkey_name]
                    xkb_name = mappings.get(unicode_sym)
                    if xkb_name == "currency":
                        linux_name = "dead_currency"
                    elif xkb_name == "asciicircum":
                        # Couche 5 : forcer le ^ normal
                        if layer == 4:
                            linux_name = "asciicircum"
                        else:
                            linux_name = "dead_circumflex"
                    elif xkb_name:
                        linux_name = f"deadkey_{xkb_name}"
                    else:
                        if unicode_sym and len(unicode_sym) > 0:
                            linux_name = f"U{ord(unicode_sym[0]):04X}"
                        else:
                            linux_name = "NoSymbol"
                else:
                    linux_name = deadkey_name
            else:
                # Forcer uparrow/downarrow pour U+02FA/U+1D49 et U+02FC/U+1D62
                comment_symbol = None
                if symbol and (any(ord(c) in (0x02FA, 0x1D49) for c in symbol)):
                    linux_name = "uparrow"
                    comment_symbol = "ᵉ"
                elif symbol and (
                    any(ord(c) in (0x02FC, 0x1D62) for c in symbol)
                ):
                    linux_name = "downarrow"
                    comment_symbol = "ᵢ"
                else:
                    linux_name = symbol_to_linux_name(symbol)
                    if linux_name == "currency":
                        linux_name = "dead_currency"
                # Si le symbole est ^ (asciicircum) sur la couche 5, forcer le normal
                if linux_name == "dead_circumflex" and layer == 4:
                    linux_name = "asciicircum"
            symbols.append(linux_name)
            # Remplacement du commentaire pour uparrow/downarrow
            if comment_symbol:
                comment_symbols.append(comment_symbol)
            elif symbol:
                decoded = html.unescape(symbol)
                if len(decoded) > 1:
                    comment_symbols.append(f'"{decoded}"')
                else:
                    comment_symbols.append(decoded)
            else:
                comment_symbols.append("")
        # Stocke le mapping pour XCompose (après la boucle sur les layers)
        generate_xkb_content.fraction_map = fraction_map
        pattern = rf"key {re.escape(xkb_key)}[^\n]*;"

        # Remplacement final dans la ligne XKB : U02FA → uparrow, U02FC → downarrow
        # Correction spéciale pour <BKSL> : deadkey uniquement en 1ère position, sinon asciicircum
        if xkb_key == "<BKSL>":
            quoted_symbols = [
                "dead_circumflex"
                if i == 0
                else "asciicircum"
                if s == "dead_circumflex"
                else s
                for i, s in enumerate(symbols)
            ]
        elif xkb_key == "<LSGT>":
            quoted_symbols = [
                s
                if i not in (2, 3)
                else ("asciicircum" if i == 2 else "dead_circumflex")
                if s == "dead_circumflex"
                else s
                for i, s in enumerate(symbols)
            ]
        elif xkb_key == "<AD12>":
            quoted_symbols = [
                "dead_diaeresis"
                if i == 0 and s in ("U2792", "diaeresis")
                else s
                for i, s in enumerate(symbols)
            ]
            quoted_symbols = [
                "dead_currency" if s == "U20B0" else s for s in quoted_symbols
            ]
        else:
            symbol_map = {
                "U02FA": "uparrow",
                "U02FC": "downarrow",
                "U27E7": "infinity",
                "U20B0": "dead_currency",
            }
            quoted_symbols = [symbol_map.get(s, s) for s in symbols]

        comment = " // " + " ".join(comment_symbols)
        replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
        xkb_content = re.sub(pattern, replacement, xkb_content)
    return xkb_content


def write_file(path, content):
    """Write content to a file."""
    print(f"[INFO] Writing file: {path}")
    with open(path, "w", encoding="utf-8") as file_out:
        file_out.write(content)


def extract_deadkey_triggers(keylayout_path):
    """Return a dict: macOS action id -> deadkey name (dead_1, dead_2, ...) if next='sX' is present."""
    if LET is None:
        print(
            "[ERROR] lxml is required for robust XML parsing. Please install it with 'pip install lxml'."
        )
        return {}
    print(f"[INFO] Extracting deadkey triggers from {keylayout_path}")
    with open(keylayout_path, encoding="utf-8") as file_in:
        xml_text = file_in.read()
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
    main(use_date_in_filename=False)
