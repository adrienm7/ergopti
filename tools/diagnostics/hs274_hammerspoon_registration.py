# tools/diagnostics/hs274_hammerspoon_registration.py
"""Register the isolated native application and verify bundle URL resolution."""

import json
from pathlib import Path
import subprocess

from hs274_accessibility_diagnostics import output_receipt


SCRIPT = r'''
ObjC.import('AppKit');
ObjC.import('CoreServices');
function run(argv) {
    const target = $.NSURL.fileURLWithPath(argv[0]);
    const bundle = $.NSBundle.bundleWithURL(target);
    if (!bundle || bundle.isNil()) throw new Error('Missing native bundle');
    const identifier = ObjC.unwrap(bundle.bundleIdentifier);
    if (identifier !== 'org.hammerspoon.Hammerspoon') throw new Error('Unexpected bundle identifier');
    const workspace = $.NSWorkspace.sharedWorkspace;
    function resolve() {
        const url = workspace.URLForApplicationWithBundleIdentifier(identifier);
        return !url || url.isNil() ? null : ObjC.unwrap(url.URLByResolvingSymlinksInPath.path);
    }
    const before = resolve();
    const status = $.LSRegisterURL(target, true);
    return JSON.stringify({identifier: identifier, before: before, status: status, after: resolve()});
}
'''


def register_application(report, app):
    """Require exact readback; registration never implies Accessibility trust."""
    state = report.setdefault("hammerspoon_registration", {})
    try:
        app = Path(app).resolve(strict=True)
        if app.name != "Hammerspoon.app" or not (app / "Contents/MacOS/Hammerspoon").is_file():
            raise ValueError("Missing owned Hammerspoon bundle")
        completed = subprocess.run(["/usr/bin/osascript", "-l", "JavaScript", "-e", SCRIPT, str(app)],
                                   capture_output=True, text=True, timeout=10)
        state.update(exit=completed.returncode, **output_receipt(completed.stdout, completed.stderr))
        if completed.returncode != 0:
            raise RuntimeError("Native Hammerspoon registration command failed")
        result = json.loads(completed.stdout)
        state["resolution"] = result
        if (not isinstance(result, dict) or result.get("identifier") != "org.hammerspoon.Hammerspoon"
                or type(result.get("status")) is not int or result["status"] != 0
                or result.get("after") != str(app)):
            raise RuntimeError("Native Hammerspoon bundle resolution is not exact")
    except subprocess.TimeoutExpired as error:
        state.update(timed_out=True, **output_receipt(error.stdout, error.stderr))
        raise
