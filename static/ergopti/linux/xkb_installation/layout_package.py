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
        extensions_root=Path(extensions_root)
        if extensions_root
        else DEFAULT_EXTENSIONS_ROOT,
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


# XKB supports at most four simultaneous layouts (groups).
MAX_XKB_LAYOUTS = 4


def build_evdev_post(layout_id: str) -> str:
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
    sections = ["! layout\t=\ttypes\n" f"  {identifier}\t=\t+{identifier}\n"]
    for index in range(1, MAX_XKB_LAYOUTS + 1):
        sections.append(
            f"! layout[{index}]\t=\ttypes\n" f"  {identifier}\t=\t+{identifier}\n"
        )
    return "".join(sections)


def build_registry_xml(
    layout_id: str,
    description: str,
    variants: list[tuple[str, str]],
) -> str:
    """Build the ``rules/evdev.xml`` registry entry for GUI discovery.

    ``variants`` is a list of ``(variant_id, description)`` pairs.
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
        errors.append(
            f"symbols reference undefined key type '{name}'"
        )
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
    match = re.search(
        r"symbols\[\s*(?:Group)?" + str(group) + r"\s*\]\s*=\s*\[([^\]]*)\]", block
    )
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
    match = re.search(
        r"map\s*\[\s*" + re.escape(modifier) + r"\s*\]\s*=\s*(?:Level)?(\d+)", block
    )
    return int(match.group(1)) if match else None


def keymap_type_preserves(keymap: str, type_name: str, modifier: str) -> bool:
    """Whether ``type_name`` keeps ``modifier`` in the event after selecting a level."""
    block = keymap_type_block(keymap, type_name)
    if block is None:
        return False
    return (
        re.search(
            r"preserve\s*\[\s*" + re.escape(modifier) + r"\s*\]\s*=\s*" + re.escape(modifier) + r"\b",
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
        existing = re.compile(
            r'type\s+"' + re.escape(name) + r'"\s*\{.*?\};', re.DOTALL
        )
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


def strip_ergopti_rule_lines(rules_content: str) -> tuple[str, int]:
    """Remove rule lines previously injected for Ergopti by older installers.

    Only assignment lines (they contain ``=``) mentioning ``ergopti`` are
    removed; section headers and unrelated content are preserved. Returns the
    cleaned content and the number of removed lines.
    """
    kept: list[str] = []
    removed = 0
    for line in rules_content.splitlines(keepends=True):
        if "=" in line and "ergopti" in line.lower():
            removed += 1
            continue
        kept.append(line)
    return "".join(kept), removed


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
