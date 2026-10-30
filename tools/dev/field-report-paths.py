#!/usr/bin/env python3
# tools/dev/field-report-paths.py
"""Print the macOS driver's folders and file names as shell assignments.

The field report collector reads the logs and the personal hotstrings where
the driver writes them; spelling those paths in the collector would drift the
day a folder moves. Every name comes from its one declaration instead:
_shared/modules/paths/app_dirs.toml for the folders and the log file names,
_shared/modules/logger/sub_files.toml for the topical log files. The
paths.toml the launcher keeps wins over both defaults, as it does in the
driver (infra/config_paths.lua): its configuration and logs folder keys move
the personal hotstrings and the logs. Only the topical logs the caller names
are listed: the hotstring and keystroke logs can carry typed text.
"""

import argparse
import os
import pathlib
import shlex
import sys
import tomllib


def load(path):
    """Returns one parsed TOML file.

    Args:
        path: The TOML file.

    Returns:
        The parsed document.
    """
    with path.open("rb") as handle:
        return tomllib.load(handle)


def folder(base, segments, app):
    """Joins an environment root and its segments, naming the app folder.

    Args:
        base: The environment variable that holds the root.
        segments: The path segments, "{app}" standing for the app folder.
        app: The application folder name.

    Returns:
        The absolute folder, without a trailing separator.
    """
    root = os.environ.get(base, "")
    if not root:
        sys.exit(f"{base} is not set: the driver folders cannot be resolved.")
    return os.path.join(root, *(app if s == "{app}" else s for s in segments))


def override(paths, key):
    """Returns the folder a paths.toml key names, or None when it names none.

    Args:
        paths: The parsed paths.toml, or an empty dict when there is none.
        key: The key to read.

    Returns:
        The absolute folder, without a trailing separator, or None.
    """
    value = paths.get(key)
    if value is None or value == "":
        return None
    if not isinstance(value, str):
        sys.exit(f"{key} in paths.toml must be a string.")
    # Releases dev.108 to dev.117 wrote a home-relative value; the driver expands it.
    if value == "~" or value.startswith("~/"):
        value = os.path.expanduser(value)
    if not os.path.isabs(value):
        sys.exit(f"{key} in paths.toml must be an absolute path.")
    return value.rstrip("/") or "/"


def main():
    """Prints the assignments and returns the process exit status."""
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("shared", type=pathlib.Path, help="the _shared folder of the clone")
    parser.add_argument("topical", nargs="*", help="the topical log names to copy")
    arguments = parser.parse_args()
    dirs = load(arguments.shared / "modules/paths/app_dirs.toml")
    routes = load(arguments.shared / "modules/logger/sub_files.toml")
    app = dirs["app"]["folder_name"]
    logs = dirs["logs"]
    files = logs["files"]
    config = dirs["config"]
    paths_file = folder(config["macos"]["base"], config["macos"]["paths_file"], app)
    paths = load(pathlib.Path(paths_file)) if os.path.isfile(paths_file) else {}
    config_dir = override(paths, config["override_key"]) or folder(
        config["macos"]["base"], config["macos"]["segments"], app
    )
    default_log_dir = folder(logs["macos"]["base"], logs["macos"]["segments"], app)
    log_dir = override(paths, logs["override_key"]) or default_log_dir
    declared = {entry["name"] for entry in routes["sub_files"] if "hs" in entry["platforms"]}
    unknown = sorted(set(arguments.topical) - declared)
    if unknown:
        sys.exit(f"no macOS topical log named {', '.join(unknown)} in sub_files.toml.")
    topical = [files["topical_prefix"] + name + files["extension"] for name in arguments.topical]
    values = {
        "LOG_DIR": log_dir,
        "LOG_UNIFIED_PREFIX": files["unified_prefix"],
        "LOG_ERRORS_PREFIX": files["errors_prefix"],
        "LOG_EXTENSION": files["extension"],
        # The launcher writes these before any configuration is read, so they
        # stay in the default folder whatever LogsDirPath says.
        "LOG_DEFAULT_DIR": default_log_dir,
        "LOG_LAUNCHER": logs["macos"]["launcher_log"],
        "LOG_FATAL_REPORT": logs["macos"]["fatal_report"],
        "LOG_TOPICAL": " ".join(topical),
        # Always in the default folder, whatever LogsDirPath says, like launcher.log.
        "RELOAD_BREADCRUMB": os.path.join(default_log_dir, logs["macos"]["reload_breadcrumb"]),
        "PERSONAL_HOTSTRINGS": os.path.join(
            config_dir, config["hotstrings_dir"], config["personal_hotstrings_file"]
        ),
    }
    for name, value in values.items():
        print(f"{name}={shlex.quote(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
