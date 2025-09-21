import os
import re

import yaml


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
    """
    Extract the symbol (output or action) for a given macOS key code in a keyMap body.
    Returns the value (e.g. 'a', 'A', etc) or '' if not found.
    """
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


# Check ../macos directory and print its contents
macos_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "../macos"))
if not os.path.isdir(macos_dir):
    raise FileNotFoundError(f"macos directory does not exist: {macos_dir}")

print("macos directory contents:")
for fname in os.listdir(macos_dir):
    print(" -", fname)

# Read keylayout file
with open(
    os.path.join(macos_dir, "Ergopti_v2.2.0.keylayout"), encoding="utf-8"
) as f:
    macos_data = f.read()

# Check base.xkb file
xkb_path = os.path.join(os.path.dirname(__file__), "base.xkb")
if not os.path.isfile(xkb_path):
    raise FileNotFoundError(f"base.xkb file not found: {xkb_path}")

with open(xkb_path, encoding="utf-8") as f:
    xkb_content = f.read()

# Load unicode to Linux symbol mapping from YAML
with open(
    os.path.join(os.path.dirname(__file__), "key_sym.yaml"), encoding="utf-8"
) as f:
    unicode_to_linux = yaml.safe_load(f)


def symbol_to_linux_name(symbol):
    """
    Convert a symbol to its Linux name using the YAML mapping.
    If not found, return the original symbol.
    """
    if not symbol or symbol == "NoSymbol":
        return "NoSymbol"
    if symbol in unicode_to_linux.values():
        return symbol
    if len(symbol) != 1:
        return symbol
    codepoint = ord(symbol)
    key = f"\\u{codepoint:04x}"
    return unicode_to_linux.get(key, symbol)


# Extract keymaps for layers 0 to 4 (indexes 0 to 4)
keymaps = [extract_keymap_body(macos_data, i) for i in [0, 3, 5, 6, 4]]

# Generate mapping for each key
for xkb_key, macos_code in linux_to_macos_keycodes:
    symbols = []
    original_symbols = []
    for layer, keymap_body in enumerate(keymaps):
        symbol = get_symbol(keymap_body, macos_code)
        linux_name = symbol_to_linux_name(symbol)
        symbols.append(linux_name)
        original_symbols.append(symbol if symbol else "")
    # Replace the line in xkb_content
    pattern = rf"key {re.escape(xkb_key)}[^{chr(10)}]*;"
    quoted_symbols = [f'"{s}"' for s in symbols]
    # Add right-side comment with the actual symbols for each layer
    comment = " // " + " ".join(original_symbols)
    replacement = f'key {xkb_key} {{ type[group1] = "FOUR_LEVEL_SEMIALPHABETIC_CONTROL", [{", ".join(quoted_symbols)}] }};{comment}'
    xkb_content = re.sub(pattern, replacement, xkb_content)

# Write the result to the script directory
output_path = os.path.join(os.path.dirname(__file__), "ergopti.xkb")
with open(output_path, "w", encoding="utf-8") as f:
    f.write(xkb_content)
