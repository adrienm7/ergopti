"""User-level installer for the keyboard layouts of the registry (no sudo).

libxkbcommon reads ``$XDG_CONFIG_HOME/xkb`` (default ``~/.config/xkb``)
first on its include path, as an XKB tree of its own: ``symbols/``,
``types/``, ``rules/``. A ``rules/evdev`` there replaces the system ruleset
for every libxkbcommon client (every Wayland session), so the one this module
writes starts with ``! include %S/evdev`` and only appends the rules that bind
each layout's key types, the same fragment the system package installs as
``evdev.post``. ``rules/evdev.xml`` registers the layouts for the desktop
pickers (libxkbregistry merges it with the system registry). Xorg's
``xkbcomp`` never reads this tree: an X11 session needs the system installer
(``install.sh``).

The ErgoptiPlus daemon runs this module to install what it converted, in Lua
(``layouts/xkb_converter.lua``), from a registry ``.keylayout``:

    user_layout_installer.py install --layout-id ergol --display-name "Ergo-L" \
        --source-dir ~/.config/ergopti_plus/layouts/ergol
    user_layout_installer.py uninstall --layout-id ergol
    user_layout_installer.py activate --layout-id ergol

Ownership: this module only ever writes files it created. A manifest in the
tree lists the layouts it installed and the rules files carry an owner marker;
an existing file it does not own is a conflict and nothing is written. A
failed installation (a write error, or a layout that does not compile) puts
back what the layout owned before, so the desktop never lists a layout the
daemon reported as failed. The last line printed is a JSON report
({"ok", "verified", "detail"}).

Exit codes: 0 success, 2 invalid arguments, 3 conflicting or inconsistent
package (nothing written), 4 installation aborted by a filesystem error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, str(Path(__file__).resolve().parent))

from desktop_activation import (  # noqa: E402
    WAYLAND_SELECT_REFUSED,
    WAYLAND_SESSION_UNSUPPORTED,
    CleanupStatus,
    activate_layout,
    apply_x11_user_tree,
    compile_rmlvo,
    deactivate_layouts,
    keymap_has_type,
    live_readback_refusal,
    live_slots,
    read_desktop_selection,
    running_as_root,
    select_live_slot,
    wayland_live_desktop,
)
from layout_package import (  # noqa: E402
    ERGOPTI_TYPE_NAME,
    EXIT_INSTALL_ABORTED,
    EXIT_OK,
    EXIT_VALIDATION,
    LayoutSpec,
    build_evdev_post,
    patch_symbols_default,
    validate_layout_files,
)

EXIT_ARGUMENTS = 2

# The session type logind publishes: "x11" for a pure Xorg session.
ENV_SESSION_TYPE = "XDG_SESSION_TYPE"
# The kind of refusal the daemon turns into a message about the session.
KIND_XORG_SESSION = "xorg_session"

# Overrides of the user tree and home, for sandboxed tests.
ENV_USER_ROOT = "ERGOPTI_XKB_USER_ROOT"
ENV_USER_HOME = "ERGOPTI_XKB_USER_HOME"

# A registry id: the rule of tools/build/build-layouts-index.cjs.
LAYOUT_ID_RE = re.compile(r"^[a-z][a-z0-9_]*$")

MANIFEST_NAME = ".ergopti_plus_layouts.json"
MANIFEST_SCHEMA = 1
RULES_MARKER = "// ErgoptiPlus managed rules: registry layouts"
REGISTRY_MARKER = "<!-- ErgoptiPlus managed registry: registry layouts -->"
FILE_MARKER = "// ErgoptiPlus managed layout: "
XCOMPOSE_MARKER = "# ErgoptiPlus managed layouts XCompose"

# ISO 639-1 codes of the registry to the ISO 639-2 codes libxkbregistry reads.
ISO639_2 = {
    "de": "ger",
    "en": "eng",
    "es": "spa",
    "fr": "fra",
    "it": "ita",
    "nl": "dut",
    "pt": "por",
}


class InstallError(Exception):
    """A refusal with the exit code it maps to."""

    def __init__(self, code: int, detail: str, kind: str = "") -> None:
        super().__init__(detail)
        self.code = code
        self.detail = detail
        # "conflict" when the refusal protects a file the user owns.
        self.kind = kind


# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------


def user_root(environ: Optional[Dict[str, str]] = None) -> Path:
    """The user XKB tree libxkbcommon reads first."""
    env = os.environ if environ is None else environ
    override = env.get(ENV_USER_ROOT)
    if override:
        return Path(override)
    config_home = env.get("XDG_CONFIG_HOME")
    base = Path(config_home) if config_home else Path.home() / ".config"
    return base / "xkb"


def is_xorg_session(environ: Optional[Dict[str, str]] = None) -> bool:
    """True in a pure Xorg session, whose xkbcomp never reads the user tree."""
    env = os.environ if environ is None else environ
    return env.get(ENV_SESSION_TYPE, "").strip().lower() == "x11"


def refuse_xorg_session(environ: Optional[Dict[str, str]] = None) -> None:
    """Refuses before writing anything when the session could not use the tree."""
    if is_xorg_session(environ):
        raise InstallError(
            EXIT_VALIDATION,
            "this is an Xorg session, which does not read the user XKB tree; nothing was written",
            KIND_XORG_SESSION,
        )


def user_home(environ: Optional[Dict[str, str]] = None) -> Path:
    """The home folder holding ~/.XCompose."""
    env = os.environ if environ is None else environ
    override = env.get(ENV_USER_HOME)
    return Path(override) if override else Path.home()


def layout_paths(root: Path, layout_id: str) -> Dict[str, Path]:
    """Every file one installed layout owns in the tree."""
    return {
        "symbols": root / "symbols" / layout_id,
        "types": root / "types" / layout_id,
        "compose": root / "compose" / (layout_id + ".XCompose"),
    }


# ---------------------------------------------------------------------------
# Text builders (pure)
# ---------------------------------------------------------------------------


def build_rules(layout_ids: List[str]) -> str:
    """The user ruleset: the system rules, then each layout's types rules."""
    parts = [RULES_MARKER + "\n", "! include %S/evdev\n"]
    for layout_id in sorted(layout_ids):
        parts.append("\n" + build_evdev_post(layout_id))
    return "".join(parts)


def xml_text(value: str) -> str:
    """Escapes text for an XML element."""
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def build_registry(layouts: Dict[str, dict]) -> str:
    """The rules/evdev.xml registry of every installed layout."""
    blocks = []
    for layout_id in sorted(layouts):
        meta = layouts[layout_id]
        codes = [ISO639_2[code] for code in meta.get("languages", []) if code in ISO639_2]
        languages = ""
        if codes:
            items = "".join("<iso639Id>%s</iso639Id>" % code for code in codes)
            languages = "        <languageList>%s</languageList>\n" % items
        blocks.append(
            "    <layout>\n"
            "      <configItem>\n"
            "        <name>%s</name>\n"
            "        <shortDescription>%s</shortDescription>\n"
            "        <description>%s</description>\n"
            "%s"
            "      </configItem>\n"
            "    </layout>\n"
            % (layout_id, xml_text(layout_id[:3]), xml_text(meta["name"]), languages)
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        + REGISTRY_MARKER
        + "\n"
        + '<!DOCTYPE xkbConfigRegistry SYSTEM "xkb.dtd">\n'
        + '<xkbConfigRegistry version="1.1">\n'
        + "  <layoutList>\n"
        + "".join(blocks)
        + "  </layoutList>\n"
        + "</xkbConfigRegistry>\n"
    )


def with_file_marker(content: str, layout_id: str) -> str:
    """Prefixes an XKB file with the owner marker (an XKB comment)."""
    return FILE_MARKER + layout_id + "\n" + content


def build_xcompose_block(compose_files: List[Path]) -> List[str]:
    """The owned ~/.XCompose lines: the marker, then one include per layout."""
    if not compose_files:
        return []
    lines = [XCOMPOSE_MARKER]
    for path in compose_files:
        escaped = str(path).replace("\\", "\\\\").replace('"', '\\"')
        lines.append('include "%s"' % escaped)
    return lines


def strip_xcompose_block(content: str) -> List[str]:
    """Removes the owned block (the marker and the includes after it)."""
    lines = content.splitlines()
    kept = []
    index = 0
    while index < len(lines):
        if lines[index].strip() != XCOMPOSE_MARKER:
            kept.append(lines[index])
            index += 1
            continue
        index += 1
        while index < len(lines) and lines[index].lstrip().startswith('include "'):
            index += 1
    return kept


# ---------------------------------------------------------------------------
# Files
# ---------------------------------------------------------------------------


def write_text(path: Path, content: str) -> None:
    """Replaces a file atomically (a crash leaves the old or the new file)."""
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
        os.replace(temporary, str(path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_manifest(root: Path) -> Dict[str, dict]:
    """The layouts this module installed in the tree."""
    path = root / MANIFEST_NAME
    if not path.exists():
        return {}
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise InstallError(
            EXIT_VALIDATION, "the layout manifest %s is unreadable: %s" % (path, error)
        )
    if (
        not isinstance(manifest, dict)
        or manifest.get("schema_version") != MANIFEST_SCHEMA
        or not isinstance(manifest.get("layouts"), dict)
    ):
        raise InstallError(EXIT_VALIDATION, "the layout manifest %s has an unknown shape" % path)
    return manifest["layouts"]


def write_manifest(root: Path, layouts: Dict[str, dict]) -> None:
    """Records the installed layouts."""
    body = {"schema_version": MANIFEST_SCHEMA, "layouts": layouts}
    write_text(
        root / MANIFEST_NAME,
        json.dumps(body, indent="\t", sort_keys=True, ensure_ascii=False) + "\n",
    )


def owned_by_us(path: Path, marker: str) -> bool:
    """Whether an existing file carries our owner marker in its first lines."""
    try:
        with open(str(path), encoding="utf-8", errors="replace") as stream:
            head = stream.read(512)
    except OSError:
        return False
    return marker in head


def publish_shared_files(root: Path, home: Path, layouts: Dict[str, dict]) -> None:
    """Writes (or removes, when empty) the rules, the registry, the manifest
    and the ~/.XCompose block from the installed layouts."""
    rules = root / "rules" / "evdev"
    registry = root / "rules" / "evdev.xml"
    if layouts:
        write_text(rules, build_rules(list(layouts)))
        write_text(registry, build_registry(layouts))
        write_manifest(root, layouts)
    else:
        for path in (rules, registry, root / MANIFEST_NAME):
            if path.exists():
                path.unlink()
    xcompose = home / ".XCompose"
    existing = xcompose.read_text(encoding="utf-8") if xcompose.exists() else ""
    kept = strip_xcompose_block(existing)
    composes = [layout_paths(root, layout_id)["compose"] for layout_id in sorted(layouts)]
    lines = kept + build_xcompose_block([path for path in composes if path.exists()])
    content = "\n".join(lines) + ("\n" if lines else "")
    if content.strip():
        if content != existing:
            write_text(xcompose, content)
    elif xcompose.exists():
        xcompose.unlink()


def check_conflicts(root: Path, layout_id: str, installed: Dict[str, dict]) -> None:
    """Refuses to overwrite any file this module did not create."""
    if layout_id not in installed:
        for path in layout_paths(root, layout_id).values():
            if path.exists():
                raise InstallError(
                    EXIT_VALIDATION,
                    "%s exists and was not installed by ErgoptiPlus" % path,
                    "conflict",
                )
    for path, marker in (
        (root / "rules" / "evdev", RULES_MARKER),
        (root / "rules" / "evdev.xml", REGISTRY_MARKER),
    ):
        if path.exists() and not owned_by_us(path, marker):
            raise InstallError(
                EXIT_VALIDATION,
                "%s is your own file; ErgoptiPlus will not replace it" % path,
                "conflict",
            )


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------


def verify(root: Path, layout_id: str) -> Optional[bool]:
    """Compiles the installed layout with libxkbcommon, when it is available:
    True when the keymap carries the layout's key type, None when no
    compiler is installed (unverified), False otherwise."""
    xkbcli = shutil.which("xkbcli")
    if not xkbcli:
        return None
    result = compile_rmlvo(xkbcli, [LayoutSpec(layout_id)], include_roots=[root])
    return result.keymap is not None and keymap_has_type(result.keymap, ERGOPTI_TYPE_NAME)


def install(
    layout_id: str,
    display_name: str,
    source_dir: Path,
    languages: List[str],
    root: Path,
    home: Path,
    environ: Optional[Dict[str, str]] = None,
    allow_xorg: bool = False,
    source_id: Optional[str] = None,
) -> dict:
    """Installs one converted layout into the user tree.

    A pure Xorg session is refused unless the caller loads the layout itself
    with ``apply_x11`` (``allow_xorg``): the desktop settings cannot select a
    layout from the user tree there. ``source_id`` names the converted files
    when they were converted under another id (a live slot, see
    ``apply_wayland``)."""
    if not allow_xorg:
        refuse_xorg_session(environ)
    source_name = source_id or layout_id
    symbols = (source_dir / (source_name + ".xkb")).read_text(encoding="utf-8")
    types = (source_dir / "xkb_types.txt").read_text(encoding="utf-8")
    compose_source = source_dir / (source_name + ".XCompose")
    problems = validate_layout_files(symbols, types)
    if problems:
        raise InstallError(
            EXIT_VALIDATION, "the converted layout is inconsistent: " + "; ".join(problems)
        )
    installed = read_manifest(root)
    check_conflicts(root, layout_id, installed)
    paths = layout_paths(root, layout_id)
    # What this layout owned before, so a failed installation puts it back.
    previous = {
        name: path.read_text(encoding="utf-8") for name, path in paths.items() if path.exists()
    }
    try:
        write_text(paths["symbols"], with_file_marker(patch_symbols_default(symbols), layout_id))
        write_text(paths["types"], with_file_marker(types, layout_id))
        if compose_source.exists():
            write_text(paths["compose"], compose_source.read_text(encoding="utf-8"))
        elif paths["compose"].exists():
            paths["compose"].unlink()
        updated = dict(installed)
        updated[layout_id] = {"name": display_name, "languages": list(languages)}
        publish_shared_files(root, home, updated)
    except OSError as error:
        restore_layout(root, home, paths, previous, installed)
        raise InstallError(EXIT_INSTALL_ABORTED, "cannot write the user XKB tree: %s" % error)
    verified = verify(root, layout_id)
    if verified is False:
        # The desktop pickers read this tree: a layout that does not compile
        # must not stay registered there while the daemon reports a failure.
        restore_layout(root, home, paths, previous, installed)
        return {
            "ok": False,
            "verified": False,
            "detail": "the converted layout does not compile with its key types; the tree is unchanged",
        }
    sibling = live_slots(layout_id)[1]
    if source_id is None and sibling in installed:
        # An update reaches the live copy too (apply_wayland keeps both alike).
        mirrored = install(
            sibling,
            display_name,
            source_dir,
            languages,
            root,
            home,
            environ,
            allow_xorg,
            source_id=layout_id,
        )
        if not mirrored["ok"]:
            return mirrored
    return {"ok": True, "verified": verified, "detail": "installed in %s" % root}


def restore_layout(
    root: Path,
    home: Path,
    paths: Dict[str, Path],
    previous: Dict[str, str],
    installed: Dict[str, dict],
) -> None:
    """Puts back the files one layout owned before a failed installation
    (none for a new layout) and the shared files of the installed layouts."""
    try:
        for name, path in paths.items():
            if name in previous:
                write_text(path, previous[name])
            elif path.exists():
                path.unlink()
        publish_shared_files(root, home, installed)
    except OSError as error:
        raise InstallError(
            EXIT_INSTALL_ABORTED,
            "cannot restore the user XKB tree after a failed installation: %s" % error,
        )


def uninstall(layout_id: str, root: Path, home: Path, deactivate: bool = True) -> dict:
    """Removes one layout this module installed, with its live slot when it has one."""
    installed = read_manifest(root)
    if layout_id not in installed:
        raise InstallError(
            EXIT_VALIDATION, "the layout %s was not installed by ErgoptiPlus" % layout_id
        )
    owned = [slot for slot in live_slots(layout_id) if slot in installed]
    try:
        for slot in owned:
            for path in layout_paths(root, slot).values():
                if path.exists():
                    path.unlink()
        remaining = {key: value for key, value in installed.items() if key not in owned}
        publish_shared_files(root, home, remaining)
    except OSError as error:
        raise InstallError(EXIT_INSTALL_ABORTED, "cannot update the user XKB tree: %s" % error)
    status = CleanupStatus.ABSENT
    if deactivate:
        status = deactivate_layouts(lambda spec: spec.layout in owned)
    return {
        "ok": True,
        "verified": None,
        "detail": "uninstalled (desktop sources: %s)" % status.name.lower(),
    }


def activate(layout_id: str, root: Path, environ: Optional[Dict[str, str]] = None) -> dict:
    """Makes one installed layout the first input source of the session.

    Its live slot (``apply_wayland``) leaves the desktop's list: the two hold
    the same build, and listing both would show the layout twice."""
    refuse_xorg_session(environ)
    installed = read_manifest(root)
    if layout_id not in installed:
        raise InstallError(EXIT_VALIDATION, "the layout %s is not installed" % layout_id)
    applied = activate_layout([LayoutSpec(layout_id)])
    sibling = live_slots(layout_id)[1]
    if applied and sibling in installed:
        applied = (
            deactivate_layouts(lambda spec: spec.layout == sibling) is not CleanupStatus.FAILED
        )
    return {
        "ok": bool(applied),
        "verified": None,
        "detail": "activated" if applied else "the desktop did not accept the layout",
    }


def apply_x11(layout_id: str, root: Path, environ: Optional[Dict[str, str]] = None) -> dict:
    """Loads one installed layout into the running Xorg server, live."""
    if layout_id not in read_manifest(root):
        raise InstallError(EXIT_VALIDATION, "the layout %s is not installed" % layout_id)
    applied, code = apply_x11_user_tree(LayoutSpec(layout_id), root, environ)
    report = {
        "ok": applied,
        "verified": applied,
        "detail": "loaded into the running X server" if applied else "not loaded: " + code,
    }
    if not applied:
        report["code"] = code
    return report


def apply_wayland(
    layout_id: str,
    display_name: str,
    source_dir: Path,
    languages: List[str],
    root: Path,
    home: Path,
    environ: Optional[Dict[str, str]] = None,
) -> dict:
    """Replaces a layout live on a GNOME or KDE Wayland session.

    The converted files are installed under the live slot the desktop does not
    use (``live_slots``), the desktop setting moves to it, and the report is a
    success only once XWayland, which receives the compositor's keymap, holds
    that slot with the installed cells. On a refusal the setting is put back
    and the session keeps the layout it had."""
    desktop = wayland_live_desktop(environ)
    if desktop is None:
        return _live_refusal(WAYLAND_SESSION_UNSUPPORTED, "no live layout path in this session")
    refusal = live_readback_refusal(environ)
    if refusal is not None:
        # Without a read-back nothing could acknowledge the layout: write nothing.
        return _live_refusal(refusal, "the loaded layout cannot be read back: " + refusal)
    if running_as_root():
        # dconf and the session bus belong to the desktop user (issue #84).
        return _live_refusal(
            WAYLAND_SELECT_REFUSED, "the desktop setting cannot be written as root"
        )
    slots = live_slots(layout_id)
    selection = read_desktop_selection(desktop, slots)
    if selection is None:
        return _live_refusal(
            WAYLAND_SELECT_REFUSED, "the %s layout setting is unreadable" % desktop
        )
    slot = slots[1] if selection.slot_in_use == slots[0] else slots[0]
    report = install(
        slot,
        display_name,
        source_dir,
        languages,
        root,
        home,
        environ,
        source_id=layout_id,
    )
    if not report["ok"]:
        return report
    applied, code = select_live_slot(slot, slots, selection, root, environ)
    if not applied:
        return _live_refusal(code, "not loaded: " + code)
    # The other slot is no longer selected, so rewriting it is invisible to the
    # compositor: both copies now hold this build, and a later activation of
    # either one types it.
    other = slots[0] if slot == slots[1] else slots[1]
    mirrored = install(
        other, display_name, source_dir, languages, root, home, environ, source_id=layout_id
    )
    detail = "loaded by the %s desktop" % desktop
    if not mirrored["ok"]:
        detail += "; the unused copy %s keeps the previous build" % other
    return {"ok": True, "verified": True, "slot": slot, "detail": detail}


def _live_refusal(code: str, detail: str) -> dict:
    return {"ok": False, "verified": False, "code": code, "detail": detail}


def parse_arguments(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install registry layouts in the user XKB tree.")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--layout-id", required=True)
    install_parser.add_argument("--display-name", required=True)
    install_parser.add_argument("--source-dir", required=True, type=Path)
    install_parser.add_argument("--language", action="append", default=[])
    install_parser.add_argument(
        "--allow-xorg", action="store_true", help="install in a pure Xorg session (see apply-x11)"
    )
    wayland_parser = commands.add_parser("apply-wayland")
    wayland_parser.add_argument("--layout-id", required=True)
    wayland_parser.add_argument("--display-name", required=True)
    wayland_parser.add_argument("--source-dir", required=True, type=Path)
    wayland_parser.add_argument("--language", action="append", default=[])
    for name in ("uninstall", "activate", "apply-x11"):
        command = commands.add_parser(name)
        command.add_argument("--layout-id", required=True)
    return parser.parse_args(argv)


def main(argv: Optional[List[str]] = None) -> int:
    args = parse_arguments(sys.argv[1:] if argv is None else argv)
    if not LAYOUT_ID_RE.match(args.layout_id):
        print(json.dumps({"ok": False, "verified": None, "detail": "invalid layout id"}))
        return EXIT_ARGUMENTS
    root, home = user_root(), user_home()
    try:
        if args.command == "install":
            report = install(
                args.layout_id,
                args.display_name,
                args.source_dir,
                args.language,
                root,
                home,
                allow_xorg=args.allow_xorg,
            )
        elif args.command == "uninstall":
            report = uninstall(args.layout_id, root, home)
        elif args.command == "apply-x11":
            report = apply_x11(args.layout_id, root)
        elif args.command == "apply-wayland":
            report = apply_wayland(
                args.layout_id, args.display_name, args.source_dir, args.language, root, home
            )
        else:
            report = activate(args.layout_id, root)
    except InstallError as error:
        print(
            json.dumps({"ok": False, "verified": None, "detail": error.detail, "code": error.kind})
        )
        return error.code
    except OSError as error:
        print(json.dumps({"ok": False, "verified": None, "detail": str(error)}))
        return EXIT_INSTALL_ABORTED
    print(json.dumps(report))
    return EXIT_OK if report["ok"] else EXIT_VALIDATION


if __name__ == "__main__":
    sys.exit(main())
