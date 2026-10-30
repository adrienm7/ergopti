#!/usr/bin/env python3
# tools/dev/field-report-paths.py
"""Print the macOS driver's folders and file names as shell assignments.

The field report collector reads the logs and the personal hotstrings where
the driver writes them; spelling those paths in the collector would drift the
day a folder moves. Every name comes from its one declaration instead:
_shared/modules/paths/app_dirs.toml for the folders and the log file names,
_shared/modules/logger/sub_files.toml for the topical log files. A
ConfigDirPath set in paths.toml is not followed: the collector sees the
default configuration folder. Only the topical logs the caller names are
listed: the hotstring and keystroke logs can carry typed text.
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
    config_dir = folder(config["macos"]["base"], config["macos"]["segments"], app)
    declared = {entry["name"] for entry in routes["sub_files"] if "hs" in entry["platforms"]}
    unknown = sorted(set(arguments.topical) - declared)
    if unknown:
        sys.exit(f"no macOS topical log named {', '.join(unknown)} in sub_files.toml.")
    topical = [files["topical_prefix"] + name + files["extension"] for name in arguments.topical]
    values = {
        "LOG_DIR": folder(logs["macos"]["base"], logs["macos"]["segments"], app),
        "LOG_UNIFIED_PREFIX": files["unified_prefix"],
        "LOG_ERRORS_PREFIX": files["errors_prefix"],
        "LOG_EXTENSION": files["extension"],
        "LOG_LAUNCHER": logs["macos"]["launcher_log"],
        "LOG_TOPICAL": " ".join(topical),
        "PERSONAL_HOTSTRINGS": os.path.join(
            config_dir, config["hotstrings_dir"], config["personal_hotstrings_file"]
        ),
    }
    for name, value in values.items():
        print(f"{name}={shlex.quote(value)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
