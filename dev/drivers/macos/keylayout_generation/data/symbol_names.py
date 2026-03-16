# ENTITY_TO_ALIAS: hex entity -> [character, named entity]
ENTITY_TO_ALIAS = {
    "&#x003C;": ["<", "&lt;"],
    "&#x003E;": [">", "&gt;"],
    "&#x0026;": ["&", "&amp;"],
    "&#x0022;": ['"', "&quot;"],
    "&#x0027;": ["'", "&apos;"],
}
# ALIAS_TO_ENTITY: character or named entity -> hex entity
ALIAS_TO_ENTITY = {
    alias: entity
    for entity, aliases in ENTITY_TO_ALIAS.items()
    for alias in aliases
}

SYMBOL_TO_NAME = {
    "˙": "abovedot",
    "˚": "abovering",
    "'": "apostrophe",
    "\\": "backslash",
    "˘": "breve",
    "ˇ": "caron",
    "^": "circumflex",
    ":": "colon",
    ",": "comma",
    "¤": "currency",
    "¨": "diaeresis",
    "$": "dollar",
    ".": "dot",
    "=": "equal",
    "!": "exclamation",
    "µ": "greek",
    "#": "hashtag",
    "?": "interrogation",
    "[": "left_bracket",
    "<": "left_chevron",
    "(": "left_parenthesis",
    "¯": "macron",
    "-": "minus",
    " ": "nnbsp",
    " ": "nbsp",
    " ": "nnbsp",
    "˛": "ogonek",
    "+": "plus",
    '"': "quote",
    "]": "right_bracket",
    ">": "right_chevron",
    ")": "right_parenthesis",
    "ℝ": "RR",
    ";": "semicolon",
    "/": "slash",
    "ᵢ": "subscript",
    "ᵉ": "superscript",
    "~": "tilde",
}
