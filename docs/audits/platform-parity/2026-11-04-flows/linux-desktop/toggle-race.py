"""Replay one immutable production command table; no working driver/gen inputs."""

from pathlib import Path
import subprocess, tempfile, json, os

ROOT = Path("/workspace/ergopti")
BASE = Path(__file__).resolve().parent
SHA = "213d65af24d2aa4845ba47743c9bab6787b61964"
source = subprocess.check_output(
    ["git", "show", SHA + ":static/ergopti_plus/linux/modules/gestures/system_actions.lua"],
    cwd=ROOT,
)
with tempfile.TemporaryDirectory(prefix="ergopti-toggle-audit-") as name:
    directory = Path(name)
    path = directory / "system_actions.lua"
    path.write_bytes(source)
    extract = "local p=arg[1]; local known={}; setmetatable(known,{__index=function()return {}end}); local env=setmetatable({require=function(n)return known[n]end},{__index=_G}); local m=assert(loadfile(p,'t',env))(); io.write(m.COMMANDS.toggle_dark_mode)"
    extractor = directory / "extract.lua"
    extractor.write_text(extract)
    command = subprocess.check_output(
        ["/workspace/scratch/parity-toolchain/ci-bin/lua", str(extractor), str(path)],
        text=True,
        cwd=ROOT,
    )
    state = directory / "state"
    log = directory / "calls"
    tool = directory / "gsettings"
    tool.write_text("""#!/bin/sh
case "$1" in
 get)
   old=$(cat "$AUDIT_STATE")
   printf 'get %s\\n' "$old" >> "$AUDIT_LOG"
   if [ "$AUDIT_BARRIER" = 1 ]; then
     : > "$AUDIT_DIR/read.$$"
     count=0; attempts=0
     while [ "$count" -lt 2 ]; do
       count=0
       for flag in "$AUDIT_DIR"/read.*; do [ -f "$flag" ] && count=$((count+1)); done
       attempts=$((attempts+1)); [ "$attempts" -lt 300 ] || exit 88
       [ "$count" -ge 2 ] || sleep 0.01
     done
   fi
   printf "'%s'\\n" "$old"
   ;;
 set)
   printf 'set %s\\n' "$4" >> "$AUDIT_LOG"
   printf '%s\\n' "$4" > "$AUDIT_STATE.$$"
   mv "$AUDIT_STATE.$$" "$AUDIT_STATE"
   printf 'done\\n' >> "$AUDIT_DIR/done"
   ;;
 *) exit 89;;
esac
""")
    tool.chmod(0o700)
    env = {
        **os.environ,
        "PATH": str(directory) + ":/usr/bin:/bin",
        "AUDIT_DIR": str(directory),
        "AUDIT_STATE": str(state),
        "AUDIT_LOG": str(log),
    }
    state.write_text("default\n")
    env["AUDIT_BARRIER"] = "0"
    for _ in range(2):
        subprocess.run(["/bin/sh", "-c", command], env=env, check=True, timeout=5)
    assert state.read_text().strip() == "default"
    control = log.read_text()
    log.write_text("")
    state.write_text("default\n")
    env["AUDIT_BARRIER"] = "1"
    workers = [
        subprocess.Popen(
            ["/bin/sh", "-c", command], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        for _ in range(2)
    ]
    for process in workers:
        out, err = process.communicate(timeout=5)
        assert process.returncode == 0, (process.returncode, out, err)
    assert state.read_text().strip() == "prefer-dark"
    result = {
        "audited_sha": SHA,
        "source": "original immutable system_actions.lua command table, dependencies unused recording imports",
        "command": command,
        "healthy_sequential_two_toggles": control,
        "concurrent_two_toggles": log.read_text(),
        "final_after_two_concurrent_toggles": "prefer-dark",
        "expected_serial_toggle_result": "default",
        "native": "quoted GVariant get output, real POSIX shell and scratch fake gsettings; no real desktop preferences mutated",
    }
    (BASE / "toggle-race.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
