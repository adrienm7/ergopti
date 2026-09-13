# tools/diagnostics/hs274_accessibility_diagnostics.py
"""Retain read-only bundle and TCC evidence without masking failed admission."""
from pathlib import Path
import plistlib
import subprocess


OUTPUT_LIMIT = 16384
TCC_PREDICATE = ('(process == "tccd" OR process == "System Settings") AND '
                 '(eventMessage CONTAINS[c] "hammerspoon" OR '
                 'eventMessage CONTAINS[c] "kTCCServiceAccessibility")')


def output_receipt(stdout, stderr):
    """Normalize partial subprocess bytes and retain only the bounded tail."""
    values = [value.decode("utf-8", errors="replace") if isinstance(value, bytes) else value or ""
              for value in (stdout, stderr)]
    return {"stdout": values[0][-OUTPUT_LIMIT:], "stderr": values[1][-OUTPUT_LIMIT:],
            "truncated": max(map(len, values)) > OUTPUT_LIMIT}


def retain_failure(report, app):
    """Inspect only the supplied application and retain each diagnostic failure."""
    evidence = report.setdefault("hammerspoon_admission_diagnostics", {})
    try:
        app = Path(app).resolve(strict=True)
        if app.name != "Hammerspoon.app" or not (app / "Contents/MacOS/Hammerspoon").is_file():
            raise ValueError("Missing owned Hammerspoon bundle")
        with (app / "Contents/Info.plist").open("rb") as source:
            info = plistlib.load(source)
        evidence["bundle"] = {key: info.get(key) for key in (
            "CFBundleIdentifier", "CFBundleExecutable", "CFBundleVersion", "CFBundleShortVersionString")}
        evidence["path"] = str(app)
    except Exception as error:
        evidence["bundle_error"] = f"{type(error).__name__}: {error}"
        return

    commands = {
        "signature_verify": ["/usr/bin/codesign", "--verify", "--strict", str(app)],
        "signature_identity": ["/usr/bin/codesign", "--display", "--verbose=4", "-r-", str(app)],
        "tcc": ["/usr/bin/log", "show", "--last", "2m", "--style", "compact", "--info",
                "--predicate", TCC_PREDICATE],
    }
    for name, command in commands.items():
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=5)
            evidence[name] = {"exit": result.returncode, **output_receipt(result.stdout, result.stderr)}
        except subprocess.TimeoutExpired as error:
            evidence[name] = {"error": f"{type(error).__name__}: {error}", "timed_out": True,
                              **output_receipt(error.stdout, error.stderr)}
        except Exception as error:
            evidence[name] = {"error": f"{type(error).__name__}: {error}"}
