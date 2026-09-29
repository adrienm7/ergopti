# tools/build/launcher_localizations.py
"""Print the launcher's CFBundleLocalizations entries from the shared locale list.

A bundle that declares no localization resolves to its development region, and
the frameworks it hosts follow it: Sparkle's remaining windows stayed English
whatever the driver or the system language. The launcher therefore declares
every language the driver ships (_shared/data/locale_order.json), in the
identifiers macOS uses for them.
"""

import json
from pathlib import Path
import re
import sys


LOCALE_ORDER = (
    Path(__file__).resolve().parents[2] / "static/ergopti_plus/_shared/data/locale_order.json"
)

# The driver's locale codes macOS spells differently: Norwegian is Bokmål
# ("nb") and the driver's Chinese is Simplified ("zh-Hans").
APPLE_IDENTIFIERS = {"no": "nb", "zh": "zh-Hans"}


def launcher_localizations(path=LOCALE_ORDER):
    """Return the macOS localization identifiers of every shipped locale, in order."""
    order = json.loads(Path(path).read_text(encoding="utf-8")).get("order")
    if not isinstance(order, list) or not order:
        raise ValueError("locale_order.json declares no locale order")
    identifiers = []
    for code in order:
        if not isinstance(code, str) or not re.fullmatch(r"[a-z]{2}", code):
            raise ValueError(f"Invalid locale code in locale_order.json: {code!r}")
        identifiers.append(APPLE_IDENTIFIERS.get(code, code))
    if len(set(identifiers)) != len(identifiers):
        raise ValueError("Two locales map to the same macOS localization")
    return identifiers


def main():
    """Print one plist <string> element per localization, for the Info.plist array."""
    print("".join(f"<string>{identifier}</string>" for identifier in launcher_localizations()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
