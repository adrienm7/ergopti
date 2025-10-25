"""Interactive selector for Ergopti XKB installation.

This script lets the user choose a release version
and a variant (Ergopti / Ergopti+ / Ergopti++ / etc.),
for Ergopti ``.xkb`` files.
It then invokes the installer script with the selected files.

Pressing Enter at each step accepts the shown default choice.
"""

import argparse
import logging
import os
import subprocess
import sys
from pathlib import Path
from typing import Dict, Optional, Tuple

from colorama import Fore, Style
from colorama import init as _colorama_init

_colorama_init(autoreset=True)

# Name of the installer Python script file (used to build the full path)
INSTALLER_SCRIPT_NAME = "xkb_files_installer.py"


def main() -> None:
    """Run the interactive Ergopti XKB selection and installation flow.

    This function orchestrates the command-line parsing and interactive
    prompts (use ``--non-interactive`` to skip prompts and accept defaults), discovers available
    release directories and Ergopti variants, selects the appropriate
    .xkb/.XCompose/types files and invokes the installer script.

    Side effects:
        - May print prompts and log information to the console.
        - May call :func:`sys.exit` on error conditions.
        - Invokes the external installer script (via ``sudo`` and the
          current Python executable) which performs the installation.

    Behavior summary:
        - Honors ``--search-dir`` to limit where releases are discovered.
        - ``--version`` selects a release directory (or its numeric menu
          index). ``--variant`` chooses the Ergopti variant.
        - ``--types`` may select a types file or a path to one.
        - Use ``--yes`` / ``--non-interactive`` to avoid prompts and
          accept sensible defaults.

    Raises:
        SystemExit: Exits with non-zero status on fatal errors such as
            missing installer script or no matching .xkb files.
    """
    # if sys.platform == "win32":
    #     logger.error("This script is for Linux and cannot be run on Windows.")
    #     sys.exit(1)

    args = parse_cli_args()
    non_interactive = bool(getattr(args, "non_interactive", False))
    script_dir = _resolve_script_dir(args)

    (
        search_dir,
        chosen_release_key,
        release_options,
        scan_recursive,
    ) = _determine_search_dir_and_release(script_dir, args, non_interactive)

    logger.info(
        "Using release selection: %s -> search directory %s",
        release_options[chosen_release_key],
        search_dir,
    )

    available_variants = _detect_variants(search_dir, scan_recursive)

    version_options, version_map, inv_map = _build_version_maps(
        available_variants
    )

    if not version_options:
        logger.error(
            "No Ergopti .xkb files found in %s. Nothing to install.", search_dir
        )
        sys.exit(1)

    chosen_version_key = _choose_version_key(
        args, non_interactive, version_map, inv_map, version_options
    )
    version = version_map[chosen_version_key]

    xkb_path, xcompose_path, xkb_dir = find_layout_files(search_dir, version)
    if not xkb_path or not xkb_dir:
        logger.error("No XKB file found. Aborting.")
        sys.exit(1)

    types_path = _choose_types(args, non_interactive, xkb_dir)

    installer_path = script_dir / INSTALLER_SCRIPT_NAME
    _invoke_installer(installer_path, xkb_path, xcompose_path, types_path)


def parse_cli_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Interactive selector for Ergopti XKB."
    )
    parser.add_argument(
        "--non-interactive",
        action="store_true",
        help="Run without interactive prompts and accept defaults",
    )
    parser.add_argument(
        "--version",
        help="Release directory to install, e.g. v2_2_0 or index from interactive menu",
    )
    parser.add_argument(
        "--variant",
        help="Variant to install: normal|plus|plus_plus or 1/2/3",
    )
    parser.add_argument(
        "--types", help="Types choice: 1 (default) | 2 | path to types file"
    )
    parser.add_argument(
        "--search-dir",
        help="Path to directory to search for releases/.xkb files (defaults to script location)",
    )
    return parser.parse_args()


class ColorFormatter(logging.Formatter):
    """Formatter that colorizes errors (red) and success messages (green).

    Success is marked by passing extra={'success': True} to the log call.
    Progress/info messages remain uncolored.
    """

    def format(self, record: logging.LogRecord) -> str:
        text = super().format(record)
        # Special-case: make the installer invocation stand out in magenta
        if "Invoking installer with:" in text:
            return Fore.MAGENTA + text + Style.RESET_ALL
        if getattr(record, "success", False):
            return Fore.GREEN + text + Style.RESET_ALL
        if record.levelno >= logging.ERROR:
            return Fore.RED + text + Style.RESET_ALL
        # Highlight general info messages (progress) in blue for visibility
        if record.levelno == logging.INFO:
            return Fore.BLUE + text + Style.RESET_ALL
        return text


# Module logger setup
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)
handler = logging.StreamHandler()
handler.setFormatter(ColorFormatter("%(levelname)s: %(message)s"))
logger.addHandler(handler)


def _logger_success(self, msg: str, *args, **kwargs) -> None:
    """Log a success message (green).

    Usage: logger.success("Done: %s", name)
    """
    extra = kwargs.pop("extra", {}) or {}
    extra.update({"success": True})
    # Delegate to info so level remains INFO but formatted as success
    self.info(msg, *args, extra=extra, **kwargs)


# Attach method to Logger class for convenience
logging.Logger.success = _logger_success


def select_from_menu(
    prompt: str, options: Dict[str, str], default: Optional[str] = None
) -> str:
    """Prompt the user to select one option from a short menu.

    Interactive selection uses the terminal arrow keys (Up/Down) when
    possible. If curses is not available or the environment is
    non-interactive, fall back to a simple numeric prompt.
    """
    if not options:
        raise ValueError("options must not be empty")

    # Try to use curses for an arrow-key based menu. Import lazily so
    # module import works on platforms without curses.
    # Try to import curses for a nicer interactive menu. If curses is not
    # available (ImportError) or the curses wrapper fails at runtime,
    # fall back to a simple numbered input prompt.
    try:
        import curses
    except ImportError:
        curses = None

    if curses is not None:
        try:

            def _curses_menu(stdscr):
                # Try to hide the cursor; some terminals may not support it.
                try:
                    curses.curs_set(0)
                except curses.error:
                    # Ignore if the terminal doesn't support cursor visibility changes
                    pass

                stdscr.keypad(True)
                keys = list(options.keys())
                idx = keys.index(default) if default in keys else 0

                # Redraw the menu on each iteration and refresh so the
                # terminal receives updated content. This ensures arrow
                # key navigation is visually reflected.
                while True:
                    stdscr.clear()
                    stdscr.addstr(0, 0, prompt)
                    for i, k in enumerate(keys):
                        label = options[k]
                        marker = "▶ " if i == idx else "  "
                        # Position explicitly rather than relying on newlines
                        stdscr.addstr(2 + i, 0, f"{marker}{label}")
                    stdscr.refresh()

                    ch = stdscr.getch()
                    if ch in (curses.KEY_UP, ord("k")):
                        idx = (idx - 1) % len(keys)
                    elif ch in (curses.KEY_DOWN, ord("j")):
                        idx = (idx + 1) % len(keys)
                    elif ch in (ord("\n"), curses.KEY_ENTER, 10, 13):
                        return keys[idx]
                    elif ch == 27:  # ESC => cancel
                        raise KeyboardInterrupt()

            # Ensure curses uses the controlling TTY even when stdin/out are
            # redirected (this happens when the script is launched from a
            # piped installer or another process). We temporarily dup /dev/tty
            # onto fd 0/1/2 so curses talks to the real terminal.
            tty_fd = None
            saved_fds = {}
            try:
                try:
                    tty_fd = os.open("/dev/tty", os.O_RDWR)
                except OSError:
                    tty_fd = None

                if tty_fd is not None:
                    # Save original std fds
                    for fd in (0, 1, 2):
                        saved_fds[fd] = os.dup(fd)
                    # Redirect std fds to the tty
                    os.dup2(tty_fd, 0)
                    os.dup2(tty_fd, 1)
                    os.dup2(tty_fd, 2)

                return curses.wrapper(_curses_menu)
            finally:
                # Restore original fds
                if tty_fd is not None:
                    try:
                        os.close(tty_fd)
                    except OSError:
                        pass
                    for fd, dup in saved_fds.items():
                        try:
                            os.dup2(dup, fd)
                        except OSError:
                            pass
                        try:
                            os.close(dup)
                        except OSError:
                            pass
        except (curses.error, OSError):
            # If curses fails at runtime (terminal issues, IO errors),
            # fall back to the simple prompt below.
            pass

    # Fallback to numbered input prompt
    print(prompt)
    for key, label in options.items():
        default_marker = " (default)" if default == key else ""
        print(f"{key}. {label}{default_marker}")

    keys = ", ".join(options.keys())
    prompt_suffix = f"Your choice ({keys})"
    if default is not None:
        default_label = options.get(default, default)
        prompt_suffix += f" [default {default_label}]"
    prompt_suffix += ": "

    while True:
        try:
            choice = input(prompt_suffix).strip()
        except (KeyboardInterrupt, EOFError):
            logger.info("Selection cancelled by user.")
            sys.exit(1)

        if not choice and default is not None:
            return default

        if choice in options:
            return choice

        logger.warning("Invalid choice. Please try again.")


def find_layout_files(
    directory: Path, version: str
) -> Tuple[Optional[Path], Optional[Path], Optional[Path]]:
    """Find the most recent Ergopti XKB file and related files.

    This searches recursively under ``directory``.
    """
    if not directory.exists() or not directory.is_dir():
        logger.warning("Search directory does not exist: %s", directory)
        return None, None, None

    xkb_files = list(directory.rglob("*.xkb"))
    matches = []

    for f in xkb_files:
        name_lower = f.name.lower()
        stem_lower = f.stem.lower()
        if "ergopti" not in name_lower:
            continue

        if version == "normal":
            if not stem_lower.endswith("_plus") and not stem_lower.endswith(
                "_plus_plus"
            ):
                matches.append(f)
        elif version == "plus":
            if stem_lower.endswith("_plus") and not stem_lower.endswith(
                "_plus_plus"
            ):
                matches.append(f)
        elif version == "plus_plus":
            if stem_lower.endswith("_plus_plus"):
                matches.append(f)
        else:
            matches.append(f)

    if not matches:
        logger.warning("No .xkb files found for version '%s'.", version)
        return None, None, None

    try:
        latest_xkb = max(matches, key=lambda p: p.stat().st_mtime)
    except OSError as exc:
        logger.error("Failed to determine most recent .xkb: %s", exc)
        return None, None, None

    logger.info("Selected XKB file: %s", latest_xkb)
    xkb_dir = latest_xkb.parent
    xcompose_path = xkb_dir / f"{latest_xkb.stem}.XCompose"
    xcompose_file: Optional[Path] = (
        xcompose_path if xcompose_path.exists() else None
    )

    return latest_xkb, xcompose_file, xkb_dir


def determine_default_version(directory: Path) -> str:
    """Return the version of the most recent Ergopti .xkb found.

    Returns one of: 'normal', 'plus', 'plus_plus'. Falls back to 'normal'.
    """
    xkb_files = list(directory.rglob("*.xkb"))
    matches = [f for f in xkb_files if "ergopti" in f.name.lower()]
    if not matches:
        return "normal"
    try:
        latest = max(matches, key=lambda p: p.stat().st_mtime)
    except OSError:
        return "normal"
    stem = latest.stem.lower()
    if stem.endswith("_plus_plus"):
        return "plus_plus"
    if stem.endswith("_plus"):
        return "plus"
    return "normal"


def _resolve_script_dir(args: argparse.Namespace) -> Path:
    """Resolve the directory to search for releases and .xkb files.

    This honors a provided ``--search-dir`` CLI argument. If the provided
    path is invalid, the function logs a warning and returns the script
    directory (the directory containing this file).

    Args:
        args: Parsed CLI arguments (as returned by :func:`parse_cli_args`).

    Returns:
        Path to use as the base search directory.
    """
    script_dir = Path(__file__).parent
    if getattr(args, "search_dir", None):
        candidate = Path(args.search_dir)
        if candidate.exists() and candidate.is_dir():
            logger.info("Using search directory: %s", candidate)
            return candidate
        logger.warning(
            "Provided --search-dir does not exist or is not a directory: %s; using script location instead",
            args.search_dir,
        )
    return script_dir


def _determine_search_dir_and_release(
    script_dir: Path, args: argparse.Namespace, non_interactive: bool
) -> Tuple[Path, str, Dict[str, str], bool]:
    """Determine release selection and compute search directory.

    The function enumerates release subdirectories under ``script_dir``
    whose name starts with ``v`` and builds a numeric menu. It then
    resolves the chosen entry based on CLI arguments or interactive
    selection.

    Args:
        script_dir: Base directory to search for release subdirectories.
        args: Parsed CLI arguments.
        non_interactive: If True, avoid interactive prompts and accept
            sensible defaults.

    Returns:
        A tuple containing:
        - search_dir: Path where .xkb files should be searched
        - chosen_release_key: The numeric key chosen from release options
        - release_options: Mapping of numeric keys to release directory names
        - scan_recursive: Whether recursive scanning should be used
    """
    release_dirs = [
        p for p in script_dir.iterdir() if p.is_dir() and p.name.startswith("v")
    ]
    release_dirs.sort(reverse=True)
    release_options: Dict[str, str] = {}
    for idx, p in enumerate(release_dirs, start=1):
        release_options[str(idx)] = p.name

    root_key = str(len(release_dirs) + 1)
    release_options[root_key] = "Use this script's directory"

    chosen_release_key: Optional[str]
    if getattr(args, "version", None):
        if args.version in release_options:
            chosen_release_key = args.version
        else:
            for k, name in release_options.items():
                if args.version == name:
                    chosen_release_key = k
                    break
            else:
                logger.warning(
                    "Unknown --version '%s', using top-level directory.",
                    args.version,
                )
                chosen_release_key = root_key
    elif non_interactive:
        chosen_release_key = str(1) if release_dirs else root_key
    else:
        if release_options:
            chosen_release_key = select_from_menu(
                "Select the release (press Enter to use the latest):",
                release_options,
                default=str(1) if release_dirs else root_key,
            )
        else:
            chosen_release_key = root_key

    if chosen_release_key == root_key:
        search_dir = script_dir
    else:
        sel_name = release_options[chosen_release_key]
        search_dir = script_dir / sel_name

    scan_recursive = chosen_release_key != root_key
    return search_dir, chosen_release_key, release_options, scan_recursive


def _detect_variants(base_dir: Path, recursive: bool) -> Dict[str, bool]:
    """Detect which Ergopti variants exist under a directory.

    Args:
        base_dir: Directory to scan for ``.xkb`` files.
        recursive: If True, scan recursively using ``rglob``, otherwise
            only examine the top-level directory with ``glob``.

    Returns:
        A mapping with boolean flags for keys: 'normal', 'plus', 'plus_plus'.
    """
    res = {"normal": False, "plus": False, "plus_plus": False}
    try:
        iterator = (
            base_dir.rglob("*.xkb") if recursive else base_dir.glob("*.xkb")
        )
        for p in iterator:
            name = p.stem.lower()
            if "ergopti" not in name:
                continue
            if name.endswith("_plus_plus"):
                res["plus_plus"] = True
            elif name.endswith("_plus"):
                res["plus"] = True
            else:
                res["normal"] = True
    except OSError:
        # On permission or filesystem errors, assume all variants might exist
        return {"normal": True, "plus": True, "plus_plus": True}
    return res


def _build_version_maps(
    available_variants: Dict[str, bool],
) -> Tuple[Dict[str, str], Dict[str, str], Dict[str, str]]:
    """Build numeric-to-variant mappings from available variants.

    Args:
        available_variants: Mapping returned by :func:`_detect_variants`.

    Returns:
        A tuple of (version_options, version_map, inv_map):
        - version_options: numeric key -> display label
        - version_map: numeric key -> internal variant id
        - inv_map: internal variant id -> numeric key
    """
    version_options: Dict[str, str] = {}
    version_map: Dict[str, str] = {}
    inv_map: Dict[str, str] = {}
    idx = 1
    if available_variants.get("normal"):
        version_options[str(idx)] = "Ergopti"
        version_map[str(idx)] = "normal"
        inv_map["normal"] = str(idx)
        idx += 1
    if available_variants.get("plus"):
        version_options[str(idx)] = "Ergopti+"
        version_map[str(idx)] = "plus"
        inv_map["plus"] = str(idx)
        idx += 1
    if available_variants.get("plus_plus"):
        version_options[str(idx)] = "Ergopti++"
        version_map[str(idx)] = "plus_plus"
        inv_map["plus_plus"] = str(idx)
        idx += 1
    return version_options, version_map, inv_map


def _choose_version_key(
    args: argparse.Namespace,
    non_interactive: bool,
    version_map: Dict[str, str],
    inv_map: Dict[str, str],
    version_options: Dict[str, str],
) -> str:
    """Resolve which version numeric key to install.

    Accepts CLI textual or numeric indicators and falls back to interactive
    selection when appropriate.

    Args:
        args: Parsed CLI arguments.
        non_interactive: Whether to avoid interactive prompts.
        version_map: Numeric key -> variant id mapping.
        inv_map: Variant id -> numeric key mapping.
        version_options: Numeric key -> display label mapping.
        default_key: Default numeric key to use when none provided.

    Returns:
        The chosen numeric key as a string.
    """
    default_key = "1"
    variant_arg = getattr(args, "variant", None)
    if variant_arg:
        v = variant_arg
        if v in version_map:
            return v
        if v in version_map.values():
            return inv_map.get(v, default_key)
        logger.warning("Unknown --version value '%s', using default.", v)
        return default_key
    if non_interactive:
        return default_key
    return select_from_menu(
        "Select the Ergopti version to install:",
        version_options,
        default=default_key,
    )


def _choose_types(
    args: argparse.Namespace, non_interactive: bool, xkb_dir: Path
) -> Optional[Path]:
    """Select the types file to use and return resolved path and label.

    Args:
        args: Parsed CLI arguments.
        non_interactive: Whether to avoid interactive prompts.
        xkb_dir: Directory where the chosen .xkb file resides.

    Returns:
        The resolved Path to the chosen types file, or None if no types file
        should be used or was found.
    """
    types_options = {
        "1": "Default types (xkb_types.txt)",
        "2": "Types without Ctrl mappings (xkb_types_without_ctrl.txt)",
        "3": "None / Skip types file",
    }
    default_types_key = "1"

    if args.types:
        if args.types in types_options:
            chosen_types_key = args.types
        else:
            chosen_types_key = "path"
    elif non_interactive:
        chosen_types_key = default_types_key
    else:
        chosen_types_key = select_from_menu(
            "Select the types file to use:",
            types_options,
            default=default_types_key,
        )

    chosen_types_label = types_options.get(chosen_types_key, chosen_types_key)
    types_file: Optional[Path] = None
    if chosen_types_key == "1":
        candidate = xkb_dir / "xkb_types.txt"
        if candidate.exists():
            types_file = candidate
    elif chosen_types_key == "2":
        candidate = xkb_dir / "xkb_types_without_ctrl.txt"
        if candidate.exists():
            types_file = candidate
    elif chosen_types_key == "path":
        candidate = Path(args.types)
        if candidate.exists():
            types_file = candidate

    if types_file:
        logger.info(
            "Selected types option: %s; Using types file: %s",
            chosen_types_label,
            types_file,
        )
    else:
        if chosen_types_key == "3":
            logger.info(
                "Selected types option: %s; Skipping types file as requested.",
                chosen_types_label,
            )
        elif chosen_types_key == "path":
            logger.info(
                "Selected types option: %s; No valid types file at provided path (%s); proceeding without types file.",
                chosen_types_label,
                args.types,
            )
        else:
            logger.info(
                "Selected types option: %s; No types file found in %s; proceeding without types file.",
                chosen_types_label,
                xkb_dir,
            )

    return types_file


def _invoke_installer(
    installer_path: Path,
    xkb_path: Path,
    xcompose_path: Optional[Path],
    types_path: Optional[Path],
) -> None:
    """Invoke the installer Python script with the chosen files.

    This function receives the full path to the installer Python script
    (for example: ``/path/to/install_xkb_files.py``) and constructs the
    command to execute it using the current Python interpreter and
    ``sudo``. If the installer is missing or the installer process
    returns a non-zero exit code, the function will log an error and
    exit the process with the same return code.

    Args:
        installer_path: Full path to the installer Python script to run.
        xkb_path: The selected .xkb file path to install.
        xcompose_path: Optional .XCompose file path to pass to the installer.
        types_path: Optional types file path to pass to the installer.

    Raises:
        SystemExit: Exits with the installer's return code on failure or if
            the installer script cannot be found.
    """
    if not installer_path.exists():
        logger.error("Installer script not found: %s", installer_path)
        sys.exit(1)
    cmd = ["sudo", sys.executable, str(installer_path), "--xkb", str(xkb_path)]
    if xcompose_path:
        cmd += ["--xcompose", str(xcompose_path)]
    if types_path:
        cmd += ["--types", str(types_path)]

    logger.info("Invoking installer with: %s", " ".join(cmd))

    try:
        subprocess.check_call(cmd)
        logger.success("Installer finished successfully.")
    except subprocess.CalledProcessError as exc:
        logger.error("Installer failed with exit code %s", exc.returncode)
        sys.exit(exc.returncode)


if __name__ == "__main__":
    main()
