# tools/diagnostics/hs274_runtime.py
"""Select a coherent remapper runtime for disposable native observations."""

import os
from pathlib import Path


def runtime_paths():
    """Require all selected components; never mix official and development IPC peers."""
    development = os.environ.get("HS274_DEVELOPMENT_ROOT")
    if development:
        root = Path(development)
        if not root.is_absolute():
            raise RuntimeError("Development runtime requires an absolute artifact root")
        core = root / "src/apps/CoreService/build/Release/Karabiner-Core-Service.app"
        console = root / "src/apps/ConsoleUserServer/build/Release/Karabiner-Console-User-Server.app"
        cli = root / "src/bin/cli/build/Release/karabiner_cli"
    else:
        root = Path("/Library/Application Support/org.pqrs/Karabiner-Elements")
        core = root / "Karabiner-Core-Service.app"
        console = root / "Karabiner-Console-User-Server.app"
        cli = root / "bin/karabiner_cli"
    paths = {
        "core_app": core,
        "core": core / "Contents/MacOS/Karabiner-Core-Service",
        "console": console / "Contents/MacOS/Karabiner-Console-User-Server",
        "cli": cli,
    }
    for name in ("core", "console", "cli"):
        if not paths[name].is_file():
            raise RuntimeError(f"Selected runtime component is missing: {paths[name]}")
    return paths
