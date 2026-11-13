"""Shared core for the Ergopti XKB layout installers.

This module owns every rule that the clean and legacy installers must apply:

- canonical file contents (symbols default-section patch, ``rules/evdev.post``,
  registry XML) as pure functions of their inputs;
- structural validation of a layout package (symbols <-> types coherence), so a
  package whose symbols reference an undefined key type can never be installed;
- root resolution with environment overrides, which keeps every filesystem side
  effect injectable for tests and CI sandboxes.

The module is standard-library only and must stay importable without any XKB
tooling present on the host.
"""

from __future__ import annotations

import ast
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

PACKAGE_NAME = "ergopti"

# Supported variants. The historical "Ergopti++" variant saturates the XCompose
# table and is no longer proposed by the installer; its files remain in the
# repository for reference only.
VARIANT_STANDARD = "ergopti"
VARIANT_PLUS = "ergopti_plus"
SUPPORTED_VARIANTS = (VARIANT_STANDARD, VARIANT_PLUS)

# Namespaced key-type name shared by every Ergopti variant. The prefix keeps it
# collision-free inside the shared extensions-directory type namespace.
ERGOPTI_TYPE_NAME = "ERGOPTI_SEVEN_LEVEL"

# Environment overrides. They exist so tests and CI sandboxes can drive the
# installer against temporary roots; production defaults match the paths
# documented by libxkbcommon >= 1.13 and the historical X11 tree.
ENV_EXTENSIONS_ROOT = "ERGOPTI_XKB_EXTENSIONS_ROOT"
ENV_SYSTEM_ROOT = "ERGOPTI_XKB_SYSTEM_ROOT"
ENV_CACHE_DIR = "ERGOPTI_XKB_CACHE_DIR"

DEFAULT_EXTENSIONS_ROOT = Path("/usr/share/xkeyboard-config.d")
DEFAULT_SYSTEM_ROOT = Path("/usr/share/X11/xkb")
DEFAULT_CACHE_DIR = Path("/var/lib/xkb")

# Minimum versions for the clean method. libxkbcommon 1.13 introduced the XKB
# extensions directories and rules composition (<ruleset>.post); xkeyboard-
# config 2.45 moved the canonical root out of the legacy X11 tree.
MIN_LIBXKBCOMMON_CLEAN = (1, 13, 0)
MIN_XKEYBOARDCONFIG_CLEAN = (2, 45, 0)

# Installer exit codes (argparse owns 2 for usage errors).
EXIT_OK = 0
EXIT_VALIDATION = 3
EXIT_INSTALL_ABORTED = 4

_SYMBOLS_SECTION_RE = re.compile(r'xkb_symbols\s+"[^"]+"')
_TYPE_REFERENCE_RE = re.compile(r'type(?:\[[^\]]*\])?\s*=\s*"([^"]+)"')
_TYPE_DEFINITION_RE = re.compile(r'^\s*type\s+"([^"]+)"', re.MULTILINE)


@dataclass(frozen=True)
class InstallerRoots:
    """Filesystem roots used by the installers."""

    extensions_root: Path
    system_root: Path
    cache_dir: Path
    sandboxed: bool

    @property
    def package_dir(self) -> Path:
        return self.extensions_root / PACKAGE_NAME


def resolve_roots() -> InstallerRoots:
    """Resolve the installer roots, honouring the sandbox overrides."""
    extensions_root = os.environ.get(ENV_EXTENSIONS_ROOT)
    system_root = os.environ.get(ENV_SYSTEM_ROOT)
    cache_dir = os.environ.get(ENV_CACHE_DIR)
    sandboxed = bool(extensions_root or system_root or cache_dir)
    return InstallerRoots(
        extensions_root=Path(extensions_root) if extensions_root else DEFAULT_EXTENSIONS_ROOT,
        system_root=Path(system_root) if system_root else DEFAULT_SYSTEM_ROOT,
        cache_dir=Path(cache_dir) if cache_dir else DEFAULT_CACHE_DIR,
        sandboxed=sandboxed,
    )


# ---------------------------------------------------------------------------
# Desktop-environment activation helpers (pure, unit-testable)
# ---------------------------------------------------------------------------


def parse_gsettings_sources(text: str) -> list[tuple[str, str]] | None:
    """Parse ``gsettings get`` output for input-sources into (type, id) pairs.

    Handles the empty forms ``@a(ss) []`` and ``[]`` as well as populated
    lists like ``[('xkb', 'fr'), ('xkb', 'ergopti')]``. ``None`` means the
    value was not understood and must never be overwritten.
    """
    stripped = (text or "").strip()
    if not stripped or stripped in ("@a(ss) []", "[]"):
        return []
    if stripped.startswith("@a(ss) "):
        stripped = stripped[len("@a(ss) ") :].strip()
    pairs: list[tuple[str, str]] = []
    try:
        parsed = ast.literal_eval(stripped)
    except (SyntaxError, ValueError):
        return None
    if not isinstance(parsed, list):
        return None
    for row in parsed:
        if (
            not isinstance(row, tuple)
            or len(row) != 2
            or not all(isinstance(value, str) for value in row)
        ):
            return None
        pairs.append((row[0], row[1]))
    return pairs


def format_gsettings_sources(pairs: list[tuple[str, str]]) -> str:
    """Render (type, id) pairs back into a gsettings value string."""
    inner = ", ".join(f"('{kind}', '{identifier}')" for kind, identifier in pairs)
    return f"[{inner}]"


def merge_gsettings_source(
    pairs: list[tuple[str, str]],
    new_entries: list[tuple[str, str]],
    make_primary: bool = False,
) -> tuple[list[tuple[str, str]], bool]:
    """Merge entries into the user's source list without ever dropping one.

    By default entries are appended, which preserves the existing order. GNOME
    types with the *first* source in the list, so appending leaves a freshly
    installed layout inactive until the user cycles input sources by hand;
    ``make_primary`` moves the requested entries to the front instead. Nothing
    is ever removed either way.

    Returns the merged list and whether the value changed.
    """
    if make_primary:
        wanted = list(dict.fromkeys(new_entries))
        remainder = [pair for pair in pairs if pair not in set(wanted)]
        merged = wanted + remainder
        return merged, merged != pairs
    existing = set(pairs)
    merged = list(pairs)
    added = False
    for entry in new_entries:
        if entry in existing:
            continue
        merged.append(entry)
        existing.add(entry)
        added = True
    return merged, added


@dataclass(frozen=True)
class LayoutSpec:
    """One XKB layout selection: a layout name and an optional variant.

    The clean method installs a standalone layout (``ergopti``); the legacy
    method registers a variant of the system ``fr`` layout
    (``fr`` + ``Ergopti_v2_2_1``). Desktops spell that pair differently:
    GNOME joins it with ``+``, KDE keeps two aligned lists, ``setxkbmap`` and
    every compositor take two separate settings. Modelling the pair once keeps
    each spelling derivable and testable.
    """

    layout: str
    variant: str = ""

    @classmethod
    def parse(cls, identifier: str) -> "LayoutSpec":
        """Parse the GNOME spelling ``layout`` or ``layout+variant``."""
        layout, _, variant = (identifier or "").partition("+")
        validate_component_identifier(layout)
        if variant:
            validate_component_identifier(variant)
        return cls(layout, variant)

    @property
    def gnome_id(self) -> str:
        return f"{self.layout}+{self.variant}" if self.variant else self.layout

    @property
    def rmlvo_variant(self) -> str:
        return self.variant


def is_ergopti_source(identifier: str) -> bool:
    """Whether a desktop layout identifier belongs to any Ergopti install."""
    return "ergopti" in (identifier or "").lower()


def parse_localectl_x11(text: str | None) -> LayoutSpec | None:
    """Read the system-wide X11 keymap pair out of ``localectl status``.

    ``localectl`` reports the persistent keyboard configuration
    (``/etc/X11/xorg.conf.d/00-keyboard.conf``), which is a different thing from
    the session's current layout. Display managers and several compositors seed
    a session from it, so a stale pair here outlives every session-level fix.
    """
    if not text:
        return None
    layout = ""
    variant = ""
    for line in text.splitlines():
        key, _, value = line.partition(":")
        key = key.strip().lower()
        value = value.strip()
        if key == "x11 layout":
            layout = value
        elif key == "x11 variant":
            variant = value
    if not layout:
        return None
    try:
        validate_component_identifier(layout)
        if variant:
            validate_component_identifier(variant)
    except ValueError:
        return None
    return LayoutSpec(layout, variant)


def stale_x11_keymap(text: str | None, installed: LayoutSpec) -> LayoutSpec | None:
    """The system X11 keymap when it names an Ergopti install other than ours.

    Issue #84 came back through this exact door. The reporter's machine still
    carried ``X11 Layout: fr`` / ``X11 Variant: Ergopti_v2_2_1`` from an older
    release. Selecting that entry loads the OLD symbols with no custom type, so
    Shift and AltGr are dead again — the very bug we had just fixed, reappearing
    from a file the installer never looked at and never mentioned.

    Only a pair that names Ergopti and differs from what we just installed is
    reported: a user who deliberately points the system at our current layout is
    doing the right thing, and a non-Ergopti keymap is none of our business.

    @param text: raw ``localectl status`` output.
    @param installed: the pair this installer just made available.
    @return: the stale pair, or ``None`` when there is nothing to warn about.
    """
    configured = parse_localectl_x11(text)
    if configured is None:
        return None
    if not (is_ergopti_source(configured.layout) or is_ergopti_source(configured.variant)):
        return None
    if configured.layout == installed.layout and configured.variant == installed.variant:
        return None
    if (
        installed.layout == PACKAGE_NAME
        and installed.variant in SUPPORTED_VARIANTS
        and configured == LayoutSpec("fr", installed.variant)
    ):
        return None
    return configured


def parse_kde_layout_list(text: str | None) -> list[str]:
    """Split ``kreadconfig LayoutList`` output on commas."""
    if not text:
        return []
    return [part.strip() for part in text.split(",") if part.strip()]


def merge_kde_layout_list(current: list[str], new_ids: list[str]) -> tuple[list[str], bool]:
    """Append missing layout ids; returns merged list and whether it changed."""
    existing = set(current)
    merged = list(current)
    added = False
    for identifier in new_ids:
        if identifier in existing:
            continue
        merged.append(identifier)
        existing.add(identifier)
        added = True
    return merged, added


def parse_kde_layouts(layout_list: str | None, variant_list: str | None) -> list[LayoutSpec]:
    """Combine Plasma's aligned ``LayoutList`` and ``VariantList`` values.

    ``VariantList`` is index-aligned with ``LayoutList`` and may be shorter or
    absent; a missing entry means "no variant". Empty layout entries are
    dropped because Plasma ignores them as well.
    """
    layouts = [part.strip() for part in (layout_list or "").split(",")]
    variants = [part.strip() for part in (variant_list or "").split(",")]
    specs: list[LayoutSpec] = []
    for index, layout in enumerate(layouts):
        if not layout:
            continue
        variant = variants[index] if index < len(variants) else ""
        specs.append(LayoutSpec(layout, variant))
    return specs


def format_kde_layouts(specs: list[LayoutSpec]) -> tuple[str, str]:
    """Render specs back into aligned ``LayoutList`` and ``VariantList`` values."""
    return (
        ",".join(spec.layout for spec in specs),
        ",".join(spec.variant for spec in specs),
    )


def merge_layout_specs(
    current: list[LayoutSpec], wanted: list[LayoutSpec]
) -> tuple[list[LayoutSpec], bool]:
    """Put ``wanted`` first without dropping any existing spec.

    The first layout is the one a desktop activates at login, so a freshly
    installed layout that is merely appended stays inactive until the user
    cycles layouts by hand.
    """
    ordered = list(dict.fromkeys(wanted))
    remainder = [spec for spec in current if spec not in set(ordered)]
    merged = ordered + remainder
    return merged, merged != current


def remove_layout_specs(
    current: list[LayoutSpec], owned: "Callable[[LayoutSpec], bool]"
) -> tuple[list[LayoutSpec], bool]:
    """Drop the specs ``owned`` accepts; keep the order of the others."""
    kept = [spec for spec in current if not owned(spec)]
    return kept, kept != current


def is_ergopti_spec(spec: LayoutSpec) -> bool:
    return is_ergopti_source(spec.layout) or is_ergopti_source(spec.variant)


def patch_symbols_default(content: str) -> str:
    """Rename the symbols section to ``default`` so GUI pickers resolve it.

    Idempotent: running it twice yields the same text.
    """
    patched = _SYMBOLS_SECTION_RE.sub('xkb_symbols "default"', content, count=1)
    if 'xkb_symbols "default"' not in patched:
        raise ValueError("symbols file declares no xkb_symbols section")
    if re.search(r"(?m)^default\s+partial alphanumeric_keys\s*$", patched):
        return patched
    bare_marker = re.compile(r"(?m)^partial alphanumeric_keys\s*$")
    if bare_marker.search(patched):
        return bare_marker.sub("default partial alphanumeric_keys", patched, count=1)
    return "default partial alphanumeric_keys\n" + patched


def add_variant_alias(content: str, variant_id: str, layout_id: str = PACKAGE_NAME) -> str:
    """Expose the package's single section under a named XKB variant as well.

    The clean method ships one standalone layout, so the only way to select it
    was ``layout=ergopti`` with an empty variant. Desktop and input-method
    tooling does not always accept that: several editors enumerate
    ``layout(variant)`` PAIRS and offer no way to pick a layout that has no
    variant, which is what the reporter of issue #84 hit when trying to keep
    Ergopti alongside a Japanese input source. The legacy method never had the
    problem because it registers under ``fr`` as a real variant.

    This alias belongs to the standalone layout. Pickers restricted to French
    additionally need the section produced by ``build_french_variant_symbols``.

    Adding a named section that includes the default one costs nothing at
    compile time and makes both spellings resolve to the same keymap, so
    ``localectl set-x11-keymap ergopti pc105 ergopti`` and every picker that
    wants a pair now work. Idempotent: running it twice yields the same text.

    @param content: symbols file text, already patched to expose ``default``.
    @param variant_id: the variant name to publish.
    @param layout_id: the symbols file name the include resolves against.
    @return: the symbols text with the alias section appended.
    """
    safe_variant = validate_component_identifier(variant_id)
    safe_layout = validate_component_identifier(layout_id)
    if 'xkb_symbols "default"' not in content:
        raise ValueError("symbols file exposes no default section to alias")
    if f'xkb_symbols "{safe_variant}"' in content:
        return content
    body = content if content.endswith("\n") else content + "\n"
    return f"{body}\n" + build_variant_symbols(safe_variant, safe_layout)


def build_variant_symbols(variant_id: str, layout_id: str) -> str:
    """Expose a named section referencing the canonical layout symbols."""
    safe_variant = validate_component_identifier(variant_id)
    safe_layout = validate_component_identifier(layout_id)
    return (
        "partial alphanumeric_keys\n"
        f'xkb_symbols "{safe_variant}" {{\n'
        f'    include "{safe_layout}(default)"\n'
        "};\n"
    )


def build_french_variant_symbols(variant_id: str, layout_id: str) -> str:
    """Add the French variant while delegating the default to the system file.

    A system symbols/fr with only an implicit default would otherwise lose to
    our first section. The explicit system include also prevents recursion.
    Other named French sections continue resolving through the include paths.
    """
    return (
        "default partial alphanumeric_keys\n"
        'xkb_symbols "ergopti_system_default" {\n'
        '    include "%S/fr"\n'
        "};\n\n"
    ) + build_variant_symbols(variant_id, layout_id)


# XKB supports at most four simultaneous layouts (groups).
MAX_XKB_LAYOUTS = 4


def build_evdev_post(layout_id: str, variant_id: str = "") -> str:
    """Build the composable ``rules/evdev.post`` fragment.

    libxkbcommon >= 1.13 appends this file after the main ruleset, which binds
    our custom types to the layout without ever touching the system rules file.

    Rules semantics that are easy to get wrong: an unindexed ``layout`` rule
    only matches configurations with a *single* layout, and ``layout[N]`` only
    matches multi-layout configurations. GNOME and KDE compile every configured
    input source into one keymap, so a user who keeps ``us`` next to Ergopti
    needs the indexed rules or the custom types are never loaded and every key
    falls back to ONE_LEVEL (dead Shift and AltGr, issue #84).
    """
    identifier = validate_component_identifier(layout_id)
    sections = [f"! layout\t=\ttypes\n  {identifier}\t=\t+{identifier}\n"]
    for index in range(1, MAX_XKB_LAYOUTS + 1):
        sections.append(f"! layout[{index}]\t=\ttypes\n  {identifier}\t=\t+{identifier}\n")
    if variant_id:
        variant = validate_component_identifier(variant_id)
        for suffix in [""] + [f"[{index}]" for index in range(1, MAX_XKB_LAYOUTS + 1)]:
            sections.append(
                f"! layout{suffix} variant{suffix}\t=\ttypes\n  fr {variant}\t=\t+{identifier}\n"
            )
    return "".join(sections)


def build_registry_xml(
    layout_id: str,
    description: str,
    variants: list[tuple[str, str]],
    parent_layout: str = "",
) -> str:
    """Build the ``rules/evdev.xml`` registry entry for GUI discovery.

    ``variants`` is a list of ``(variant_id, description)`` pairs.
    ``parent_layout`` also registers those variants under an existing layout,
    without replacing that layout's system-provided description or variants.
    """
    identifier = validate_component_identifier(layout_id)
    variant_blocks: list[str] = []
    for variant_id, variant_description in variants:
        safe_variant = validate_component_identifier(variant_id)
        variant_blocks.append(
            "        <variant>\n"
            "          <configItem>\n"
            f"            <name>{safe_variant}</name>\n"
            f"            <description>{variant_description}</description>\n"
            "          </configItem>\n"
            "        </variant>"
        )
    variants_xml = ""
    if variant_blocks:
        joined = "\n".join(variant_blocks)
        variants_xml = f"      <variantList>\n{joined}\n      </variantList>\n"
    parent_xml = ""
    if parent_layout and variants_xml:
        parent = validate_component_identifier(parent_layout)
        parent_xml = (
            "    <layout>\n"
            f"      <configItem><name>{parent}</name></configItem>\n"
            f"{variants_xml}"
            "    </layout>\n"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE xkbConfigRegistry SYSTEM "xkb.dtd">\n'
        '<xkbConfigRegistry version="1.1">\n'
        "  <layoutList>\n"
        "    <layout>\n"
        "      <configItem>\n"
        f"        <name>{identifier}</name>\n"
        "        <shortDescription>Ergo</shortDescription>\n"
        f"        <description>{description}</description>\n"
        "        <languageList><iso639Id>fra</iso639Id></languageList>\n"
        "      </configItem>\n"
        f"{variants_xml}"
        "    </layout>\n"
        f"{parent_xml}"
        "  </layoutList>\n"
        "</xkbConfigRegistry>\n"
    )


def validate_component_identifier(identifier: str) -> str:
    """Reject identifiers that could escape their filename or rules slot."""
    if not re.fullmatch(r"[A-Za-z0-9._-]{1,80}", identifier or ""):
        raise ValueError(f"Unsafe XKB component identifier: {identifier!r}")
    return identifier


def extract_referenced_types(symbols_content: str) -> set[str]:
    """Return every key-type name referenced by a symbols file."""
    return set(_TYPE_REFERENCE_RE.findall(symbols_content))


def extract_defined_types(types_content: str) -> set[str]:
    """Return every key-type name defined by a types file."""
    return set(_TYPE_DEFINITION_RE.findall(types_content))


def validate_layout_files(symbols_content: str, types_content: str) -> list[str]:
    """Validate a layout package before installation.

    Returns the list of problems found; an empty list means the package is
    structurally coherent. The check exists because a symbols file referencing
    an undefined type makes the whole keymap fail to compile, which is exactly
    how issue #84 (a dead Shift layer) reached users.
    """
    errors: list[str] = []
    if not symbols_content.strip():
        errors.append("symbols file is empty")
    if not types_content.strip():
        errors.append("types file is empty")
    referenced = extract_referenced_types(symbols_content)
    defined = extract_defined_types(types_content)
    for name in sorted(referenced - defined):
        errors.append(f"symbols reference undefined key type '{name}'")
    if referenced and not defined:
        errors.append("types file defines no key type at all")
    return errors


def variant_for_filename(filename: str) -> str | None:
    """Map a generated layout filename to its supported variant id."""
    lowered = filename.lower()
    if "_plus_plus" in lowered:
        # Ergopti++ is no longer proposed: keep repository files but refuse
        # them at installation time.
        return None
    if "_plus" in lowered:
        return VARIANT_PLUS
    return VARIANT_STANDARD


def base_name_for_variant(version_dir: str, variant: str) -> str:
    """Return the canonical non-ANSI basename for a variant."""
    suffix = "" if variant == VARIANT_STANDARD else "_plus"
    return f"Ergopti_{version_dir}{suffix}"


def ansi_base_name_for_variant(version_dir: str, variant: str) -> str:
    """Return the ANSI physical-layout basename for a variant."""
    suffix = "" if variant == VARIANT_STANDARD else "_plus"
    return f"Ergopti_{version_dir}{suffix}_ansi"


# ---------------------------------------------------------------------------
# Compiled keymap inspection
# ---------------------------------------------------------------------------
#
# Both compilers dump a keymap as text, with two spellings: libxkbcommon
# numbers groups and levels (``type[1]=``, ``map[Shift]= 3``) while Xorg's
# xkbcomp keeps the symbolic names (``type[Group1]=``, ``map[Shift]= Level3``).
# Every helper accepts both. They exist because "the keymap compiled" proves
# nothing: a key whose type is unknown silently falls back to ONE_LEVEL, which
# users experience as a dead Shift key (issue #84).

_KEY_TYPE_RE = re.compile(r'type(?:\[\s*(?:Group)?(\d+)\s*\])?\s*=\s*"([^"]+)"')


def _component_name(key: str) -> str:
    name = key.strip()
    return name if name.startswith("<") else f"<{name}>"


def keymap_defines_type(keymap: str, type_name: str) -> bool:
    """Whether the compiled keymap carries a definition of ``type_name``."""
    return re.search(r'type\s+"' + re.escape(type_name) + r'"\s*\{', keymap) is not None


def keymap_key_block(keymap: str, key: str) -> str | None:
    """Return the body of ``key <NAME> { ... };`` or ``None`` when absent."""
    pattern = re.compile(r"key\s+" + re.escape(_component_name(key)) + r"\s*\{(.*?)\};", re.DOTALL)
    match = pattern.search(keymap)
    return match.group(1) if match else None


def keymap_key_type(keymap: str, key: str, group: int = 1) -> str | None:
    """Return the key type bound to ``key`` for ``group`` (1-based).

    A ``type=`` entry without an index applies to every group; an indexed
    entry wins for its own group. ``None`` means the key is absent or has no
    explicit type.
    """
    block = keymap_key_block(keymap, key)
    if block is None:
        return None
    default = None
    for index, name in _KEY_TYPE_RE.findall(block):
        if not index:
            default = name
        elif int(index) == group:
            return name
    return default


def keymap_key_symbols(keymap: str, key: str, group: int = 1) -> list[str]:
    """Return the keysym names bound to ``key`` for ``group`` (1-based)."""
    block = keymap_key_block(keymap, key)
    if block is None:
        return []
    match = re.search(r"symbols\[\s*(?:Group)?" + str(group) + r"\s*\]\s*=\s*\[([^\]]*)\]", block)
    if not match:
        return []
    return [part.strip() for part in match.group(1).split(",") if part.strip()]


def keymap_type_block(keymap: str, type_name: str) -> str | None:
    """Return the body of ``type "NAME" { ... };`` or ``None`` when absent."""
    pattern = re.compile(r'type\s+"' + re.escape(type_name) + r'"\s*\{(.*?)\};', re.DOTALL)
    match = pattern.search(keymap)
    return match.group(1) if match else None


def keymap_type_level(keymap: str, type_name: str, modifier: str) -> int | None:
    """Return the level ``modifier`` alone selects in ``type_name``; ``None`` if unmapped."""
    block = keymap_type_block(keymap, type_name)
    if block is None:
        return None
    match = re.search(r"map\s*\[\s*" + re.escape(modifier) + r"\s*\]\s*=\s*(?:Level)?(\d+)", block)
    return int(match.group(1)) if match else None


def keymap_type_preserves(keymap: str, type_name: str, modifier: str) -> bool:
    """Whether ``type_name`` keeps ``modifier`` in the event after selecting a level."""
    block = keymap_type_block(keymap, type_name)
    if block is None:
        return False
    return (
        re.search(
            r"preserve\s*\[\s*"
            + re.escape(modifier)
            + r"\s*\]\s*=\s*"
            + re.escape(modifier)
            + r"\b",
            block,
        )
        is not None
    )


def parse_version(text: str) -> tuple[int, ...] | None:
    """Extract the first ``major.minor[.patch]`` version found in ``text``."""
    match = re.search(r"(\d+)\.(\d+)(?:\.(\d+))?", text or "")
    if not match:
        return None
    return tuple(int(part or 0) for part in match.groups())


def format_version(version: tuple[int, ...]) -> str:
    return ".".join(str(part) for part in version)


# ---------------------------------------------------------------------------
# Previous-installation migration
# ---------------------------------------------------------------------------
#
# Two generations of installers preceded the current one and both left
# artefacts outside the extensions package directory:
#
# - generation 1 (legacy): edited /usr/share/X11/xkb files in place, keeping
#   numbered backups;
# - generation 2 (clean v1): created per-file-stem symlinks inside the legacy
#   X11 tree and appended "<stem> = +<stem>" lines to the system rules/evdev.
#
# An upgrade must neutralise those leftovers or two competing type mappings
# can coexist for the same layout.


_TYPE_BLOCK_RE = re.compile(r'type\s+"([^"]+)"\s*\{.*?\};', re.DOTALL)


def insert_type_sections(destination: str, source: str) -> tuple[str, list[str]]:
    """Insert or replace the ``type`` blocks of ``source`` inside ``destination``.

    ``destination`` is a system types file such as ``types/extra``: one or
    more ``xkb_types "name" { ... };`` sections. A ``type`` block is only valid
    *inside* such a section, so new blocks are inserted before the closing
    ``};`` of the last section; appending after it makes Xorg's ``xkbcomp``
    reject the whole ``complete`` types file and makes libxkbcommon silently
    drop the type, which is exactly how the Shift and AltGr layers died.

    Existing blocks with the same type name are replaced in place. Returns the
    new content and the names of the inserted or replaced types.
    """
    blocks = _TYPE_BLOCK_RE.findall(source)
    if not blocks:
        raise ValueError("source types file defines no type block")
    content = destination
    handled: list[str] = []
    for match in _TYPE_BLOCK_RE.finditer(source):
        name = match.group(1)
        block = match.group(0)
        existing = re.compile(r'type\s+"' + re.escape(name) + r'"\s*\{.*?\};', re.DOTALL)
        if existing.search(content):
            content = existing.sub(lambda _m, b=block: b, content, count=1)
        else:
            closing = content.rstrip().rfind("};")
            if closing == -1:
                raise ValueError("destination types file has no xkb_types section")
            indented = "\n".join(
                ("    " + line) if line.strip() else line for line in block.splitlines()
            )
            head = content[:closing].rstrip("\n")
            tail = content[closing:]
            content = f"{head}\n\n{indented}\n{tail}"
        handled.append(name)
    if not content.endswith("\n"):
        content += "\n"
    return content, handled


_RULE_HEADER_RE = re.compile(r"^\s*!")


def strip_ergopti_rule_lines(rules_content: str) -> tuple[str, int]:
    """Remove rule lines previously injected for Ergopti by older installers.

    Only assignment lines (they contain ``=``) mentioning ``ergopti`` are
    removed, together with the ``= types`` section headers those installers
    appended when the removal leaves them without any entry; headers that
    still hold entries and unrelated content are preserved, and a file that
    carried nothing of ours is returned untouched. Returns the cleaned content
    and the number of removed lines.
    """
    kept: list[str] = []
    removed = 0
    for line in rules_content.splitlines(keepends=True):
        if "=" in line and "ergopti" in line.lower():
            removed += 1
            continue
        kept.append(line)
    if removed == 0:
        return rules_content, 0
    result: list[str] = []
    index = 0
    while index < len(kept):
        line = kept[index]
        if _RULE_HEADER_RE.match(line) and "=" in line and "types" in line:
            end = index + 1
            while end < len(kept) and not _RULE_HEADER_RE.match(kept[end]):
                end += 1
            body = kept[index + 1 : end]
            if not any(entry.strip() and not entry.lstrip().startswith("//") for entry in body):
                # An emptied section is what the generation-2 installer left
                # behind: dropping it with its blank lines restores the file.
                removed += 1
                index = end
                continue
        result.append(line)
        index += 1
    cleaned = "".join(result)
    return cleaned.rstrip("\n") + "\n" if cleaned.strip() else "", removed


def find_stale_bridge_links(system_root: Path) -> list[Path]:
    """Find generation-2 symlinks/files left in the legacy XKB tree.

    Name and resolved-path comparisons are case-insensitive: the historical
    installers wrote CamelCase file names (``Ergopti_…``) under a lowercase
    package id.
    """
    stale: list[Path] = []
    for component in ("symbols", "types"):
        component_dir = system_root / component
        if not component_dir.is_dir():
            continue
        for entry in component_dir.iterdir():
            name_lower = entry.name.lower()
            if PACKAGE_NAME not in name_lower and "ergopti" not in name_lower:
                continue
            try:
                resolved_str = str(entry.resolve()).lower()
            except OSError:
                resolved_str = ""
            if entry.is_symlink() or entry.is_file():
                if (
                    PACKAGE_NAME in resolved_str
                    or "ergopti" in resolved_str
                    or "xkeyboard-config.d" in resolved_str
                ):
                    stale.append(entry)
    return stale


def strip_legacy_evdev_patch(system_root: Path) -> int:
    """Neutralise the generation-2 patch of the system rules file.

    Returns the number of removed lines. Failures are reported through the
    returned count only: callers decide whether the cleanup is fatal (it never
    is — the extensions-directory mechanism does not depend on this file).
    """
    rules_path = system_root / "rules" / "evdev"
    if not rules_path.is_file():
        return 0
    try:
        original = rules_path.read_text(encoding="utf-8")
    except OSError:
        return 0
    cleaned, removed = strip_ergopti_rule_lines(original)
    if removed == 0:
        return 0
    try:
        rules_path.write_text(cleaned, encoding="utf-8")
    except OSError:
        return 0
    return removed


# The system files the legacy method edits in place, each beside its numbered
# backups. ``rules/evdev`` is not here: it has its own line-level cleanup above.
LEGACY_TOUCHED_FILES = (
    ("symbols", "fr"),
    ("types", "extra"),
    ("rules", "evdev.lst"),
    ("rules", "evdev.xml"),
)


def pristine_backup(target: Path) -> Path | None:
    """The ``.1`` snapshot taken before the very first legacy modification."""
    numbered: list[tuple[int, Path]] = []
    for candidate in target.parent.glob(f"{target.name}.*"):
        suffix = candidate.name[len(target.name) + 1 :]
        if suffix.isdigit():
            numbered.append((int(suffix), candidate))
    if not numbered:
        return None
    numbered.sort()
    return numbered[0][1]


def retire_legacy_installation(system_root: Path) -> list[str]:
    """Restore every legacy-touched system file from its pristine snapshot.

    A clean install used to strip only the ``rules/evdev`` lines and the
    generation-2 links, which left the legacy variant HALF removed: its section
    survived in ``symbols/fr`` and its entries in ``rules/evdev.lst`` and
    ``rules/evdev.xml``, while its custom type was gone from ``types/extra``.

    That state is strictly worse than leaving the old install alone. The variant
    is still advertised, so a picker still offers it, but nothing defines
    ERGOPTI_SEVEN_LEVEL any more, so every key falls back to ONE_LEVEL and Shift
    and AltGr are dead — the original issue #84 symptom, reappearing on a machine
    that had just been "fixed". The reporter hit exactly this: `fr+Ergopti_v2_2_1`
    compiled and was unusable while the new `ergopti` package was perfect.

    Only a file that still mentions Ergopti AND has the installer's own pristine
    snapshot is touched, so a distribution file we never edited is never
    overwritten. Stale snapshots beside an already-clean file are dropped, since
    they would make a later run believe an installation is still present.

    @param system_root: the XKB tree root (``/usr/share/X11/xkb``).
    @return: human-readable descriptions of what was retired.
    """
    retired: list[str] = []
    for parts in LEGACY_TOUCHED_FILES:
        target = system_root.joinpath(*parts)
        backup = pristine_backup(target)
        if backup is None:
            continue
        try:
            still_ours = "ergopti" in target.read_text(encoding="utf-8", errors="replace").lower()
        except OSError:
            continue
        if still_ours:
            try:
                target.write_text(
                    backup.read_text(encoding="utf-8", errors="replace"),
                    encoding="utf-8",
                )
            except OSError:
                continue
            retired.append("/".join(parts))
        for candidate in sorted(target.parent.glob(f"{target.name}.*")):
            suffix = candidate.name[len(target.name) + 1 :]
            if suffix.isdigit():
                try:
                    candidate.unlink()
                except OSError:
                    pass
    return retired


def remove_generation_two_links(system_root: Path) -> int:
    """Delete stale generation-2 bridge links; returns the removal count."""
    removed = 0
    for entry in find_stale_bridge_links(system_root):
        try:
            if entry.is_symlink() or entry.is_file():
                entry.unlink()
                removed += 1
        except OSError:
            continue
    return removed


# ---------------------------------------------------------------------------
# Owned ~/.XCompose block
# ---------------------------------------------------------------------------

# GTK 3's built-in input method (gtk-im-context-simple, used wherever IBus is
# not) reads only the rules written in ~/.XCompose itself and ignores an
# ``include`` of another file, while libX11 and Qt read includes. Its table
# also overflows on a large set of multi-character outputs (Bépo's 21,742
# abort GTK 3 applications with "buffer overflow detected"). The owned block
# therefore includes each layout file, as libX11 and Qt need, then repeats its
# single-character rules inline for GTK 3; multi-character outputs stay
# libX11's and Qt's (IBus and GTK 4 read includes). The repeated rules are the
# included file's own, in its order, so libX11 and Qt end in the same state.
LOCALE_INCLUDE = 'include "%L"'
_COMPOSE_VALUE = re.compile(r':\s*"((?:[^"\\]|\\.)*)"')


def compose_include_line(path: Path) -> str:
    """An XCompose include of one file."""
    escaped = str(path).replace("\\", "\\\\").replace('"', '\\"')
    return f'include "{escaped}"'


def single_character_rules(text: str) -> list[str]:
    """The rules of one XCompose file whose output is one character."""
    rules = []
    for line in text.splitlines():
        match = _COMPOSE_VALUE.search(line)
        if match and len(re.sub(r"\\(.)", r"\1", match.group(1))) == 1:
            rules.append(line)
    return rules


def xcompose_end_marker(marker: str) -> str:
    """The line closing an owned block opened by ``marker`` ("# X" -> "# End of X")."""
    return "# End of " + marker.lstrip("# ")


def inline_xcompose_block(marker: str, composes: list[tuple[Path, str]]) -> list[str]:
    """The owned block: the marker, the locale include, then per layout file its
    include and its single-character rules, then the end marker.

    ``composes`` holds each layout's generated XCompose path and text.
    """
    if not composes:
        return []
    lines = [marker, LOCALE_INCLUDE]
    for path, text in composes:
        lines.append(compose_include_line(path))
        lines.extend(single_character_rules(text))
    lines.append(xcompose_end_marker(marker))
    return lines


def strip_xcompose_block(content: str, marker: str) -> tuple[list[str], bool]:
    """Removes the owned block, never adjacent user lines.

    A block that has an end marker runs to it; one written before the rules
    were inlined is the marker and the include lines right after it.
    """
    lines = content.splitlines()
    end = xcompose_end_marker(marker)
    kept: list[str] = []
    removed = False
    index = 0
    while index < len(lines):
        if lines[index].strip() != marker:
            kept.append(lines[index])
            index += 1
            continue
        removed = True
        closing = next(
            (
                position
                for position in range(index + 1, len(lines))
                if lines[position].strip() == end
            ),
            None,
        )
        if closing is not None:
            index = closing + 1
            continue
        index += 1
        while index < len(lines) and lines[index].lstrip().startswith('include "'):
            index += 1
    return kept, removed


# ---------------------------------------------------------------------------
# Compose input method for GTK 3
# ---------------------------------------------------------------------------

# The inlined single-character rules above are all GTK 3's built-in input
# method can compose; IBus reads the whole ~/.XCompose, includes and
# multi-character outputs too. When the session runs no input method at all,
# the user installer therefore points GTK at IBus (GTK_IM_MODULE through
# systemd's environment.d, read at the next login) and starts its daemon with
# the session, keeping the system layout. An active input method is never
# replaced: fcitx5 or any other is left alone and an Ergopti IBus setting
# already written is withdrawn. Decided by the agent on 2026-11-13, to review
# by the maintainer: GTK_IM_MODULE only (Qt and libX11 read the includes),
# and only from the user installer, which runs inside the session; the site's
# system installer runs as root and cannot see the session's input method.
IM_ENVIRONMENT_FILE = Path("environment.d") / "90-ergopti-ibus.conf"
IM_AUTOSTART_FILE = Path("autostart") / "ergopti-ibus.desktop"
IM_OWNER_MARKER = "# Ergopti: IBus for Compose, written while no input method was active"
IM_ENVIRONMENT_TEXT = IM_OWNER_MARKER + "\nGTK_IM_MODULE=ibus\n"
IM_AUTOSTART_TEXT = (
    "[Desktop Entry]\n"
    + IM_OWNER_MARKER
    + "\nType=Application\nName=IBus (Ergopti Compose)\nNoDisplay=true\n"
    # IBus keeps the system layout rather than imposing its engine's own.
    + "Exec=sh -c 'gsettings set org.freedesktop.ibus.general use-system-keyboard-layout true;"
    + " exec ibus-daemon --daemonize'\n"
)
# Process names (as /proc/<pid>/comm spells them) of input methods other than IBus.
OTHER_INPUT_METHODS = ("fcitx5", "fcitx", "uim-xim", "kime", "nimf", "scim", "hime", "gcin")
# GTK_IM_MODULE values that are GTK's own built-in method, not an input method.
GTK_BUILTIN_MODULES = ("", "simple", "gtk-im-context-simple")

# The states publish_compose_input_method reports.
IM_STATE_NONE = "none"
IM_STATE_IBUS_ACTIVE = "ibus_active"
IM_STATE_IBUS_ENABLED = "ibus_enabled"
IM_STATE_OTHER_ACTIVE = "other_active"
IM_STATE_NO_IBUS = "no_ibus"


def running_process_names(proc: Path = Path("/proc")) -> set[str]:
    """The command names of the processes this user can see."""
    names = set()
    for entry in proc.iterdir() if proc.is_dir() else ():
        if not entry.name.isdigit():
            continue
        try:
            names.add((entry / "comm").read_text(encoding="utf-8").strip())
        except OSError:
            continue
    return names


def session_input_method(environ: dict[str, str], running: set[str]) -> str | None:
    """The input method the session runs: "ibus", another one's name, or None.

    Another input method wins over IBus: a session showing both is one where
    the user chose the other, and Ergopti must not compete with it.
    """
    module = environ.get("GTK_IM_MODULE", "").strip().lower()
    xmodifiers = environ.get("XMODIFIERS", "").strip().lower()
    xim = xmodifiers[len("@im=") :] if xmodifiers.startswith("@im=") else ""
    for name in OTHER_INPUT_METHODS:
        if name in running:
            return name
    for value in (module, xim):
        if value and value not in GTK_BUILTIN_MODULES and value not in ("ibus", "none"):
            return value
    desktops = environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
    # GNOME Shell runs IBus itself and routes every toolkit's input through it.
    if module == "ibus" or xim == "ibus" or "ibus-daemon" in running or "gnome" in desktops:
        return "ibus"
    return None


def _owned(path: Path) -> bool:
    try:
        return IM_OWNER_MARKER in path.read_text(encoding="utf-8")
    except OSError:
        return False


def publish_compose_input_method(
    config_home: Path,
    wanted: bool,
    environ: dict[str, str],
    running: set[str],
    ibus_daemon: str | None,
    write: Callable[[Path, str], None],
) -> str:
    """Writes or withdraws the Ergopti IBus setting and says which state holds.

    ``wanted`` is whether a managed Compose block exists; ``ibus_daemon`` the
    path of ibus-daemon, None when IBus is not installed. A file of the same
    name the user wrote (no owner marker) is never touched.
    """
    paths = (config_home / IM_ENVIRONMENT_FILE, config_home / IM_AUTOSTART_FILE)
    ours = [path for path in paths if path.exists() and _owned(path)]

    def withdraw() -> None:
        for path in ours:
            path.unlink()

    if not wanted:
        withdraw()
        return IM_STATE_NONE
    active = session_input_method(environ, running)
    if active is not None and active != "ibus":
        withdraw()
        return IM_STATE_OTHER_ACTIVE
    if len(ours) == len(paths):
        return IM_STATE_IBUS_ENABLED
    if active == "ibus":
        return IM_STATE_IBUS_ACTIVE
    if ibus_daemon is None:
        withdraw()
        return IM_STATE_NO_IBUS
    for path, text in zip(paths, (IM_ENVIRONMENT_TEXT, IM_AUTOSTART_TEXT)):
        if path.exists() and not _owned(path):
            raise OSError(f"{path} exists and was not written by Ergopti")
    for path, text in zip(paths, (IM_ENVIRONMENT_TEXT, IM_AUTOSTART_TEXT)):
        write(path, text)
    return IM_STATE_IBUS_ENABLED
