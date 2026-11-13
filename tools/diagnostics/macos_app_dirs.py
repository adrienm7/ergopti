#!/usr/bin/env python3
# tools/diagnostics/macos_app_dirs.py
"""The macOS driver's folders, read from their one declaration.

The launch diagnostics seed and inspect the folders the packaged application
writes: the logs folder, the configuration folder and the paths.toml beside
them. Spelling those paths here would drift the day a folder moves, so each
one comes from _shared/core/fs/data/paths/app_dirs.toml, like the drivers'
generated files and tools/dev/field-report-paths.py.
"""

from pathlib import Path
import tomllib

APP_DIRS = (
    Path(__file__).resolve().parents[2]
    / "static/ergopti_plus/_shared/core/fs/data/paths/app_dirs.toml"
)

with APP_DIRS.open("rb") as _handle:
    DATA = tomllib.load(_handle)

# The folder named after the application on macOS.
FOLDER_NAME = DATA["app"]["folder_name"]


def home_relative(segments):
    """Joins the segments of one app_dirs.toml folder below the home folder.

    Args:
        segments: The path segments, "{app}" standing for the application folder.

    Returns:
        The relative path, with "/" separators.
    """
    if not segments:
        raise ValueError("an app_dirs.toml folder needs at least one segment")
    return "/".join(FOLDER_NAME if segment == "{app}" else segment for segment in segments)


# The default logs folder: launcher.log, the fallback boot log and, without a
# LogsDirPath override, the driver's own logs.
LOGS_RELATIVE = home_relative(DATA["logs"]["macos"]["segments"])
LAUNCHER_LOG_NAME = DATA["logs"]["macos"]["launcher_log"]
# The default configuration folder and the launcher-managed paths.toml.
CONFIG_RELATIVE = home_relative(DATA["config"]["macos"]["segments"])
PATHS_FILE_RELATIVE = home_relative(DATA["config"]["macos"]["paths_file"])
# The support root and the cache folder.
SUPPORT_RELATIVE = home_relative(DATA["support"]["macos"]["segments"])
CACHE_RELATIVE = home_relative(DATA["cache"]["macos"]["segments"])
