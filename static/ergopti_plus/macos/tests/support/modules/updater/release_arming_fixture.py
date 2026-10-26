"""Exercise the emitted detached installer with owned POSIX process capabilities."""

import json
import os
from pathlib import Path
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile

CONTROL_TIMEOUT_SECONDS = 10
CAPTURE = r"""
assert(_VERSION == "Lua 5.4", "Release arming controls require Lua 5.4")
local driver, shared, app, staged, pid, override = table.unpack(arg)
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. shared .. '/lua/?.lua;' .. shared .. '/lua/?/init.lua;' .. package.path
local Json = require('json')
local logger = {}
for _, name in ipairs({'start','success','trace','done','info','debug','warn','error'}) do logger[name]=function() end end
package.preload['infra.logger']=function() return logger end
package.preload['infra.paths']=function() return {shared=function(path)
    assert(path=='../macos/adapters/release_stage.sh');return driver..'/adapters/release_stage.sh'
end} end
package.preload['adapters.file_system']=function() return {read=function(path)
    local file=assert(io.open(path,'rb'));local body=assert(file:read('a'));assert(file:close());return body
end} end
package.preload['adapters.json_codec']=function() return Json end
package.preload['adapters.shell_runner']=function() return {} end
local installer=require('modules.updater.release_installer')
installer._getenv=function(name)
    if name=='ERGOPTI_LAUNCHER_EXECUTABLE' then return app..'/Contents/MacOS/ErgoptiPlus' end
    if name=='ERGOPTI_LAUNCHER_PID' then return pid end
end
if override~='' then installer.SWAP_SCRIPT=override end
local captured
installer._run=function(executable,args) captured={executable=executable,args=args,interpreter_version=_VERSION};return true end
assert(installer.arm_swap(staged,function() end)==true)
print(assert(Json.encode(captured)))
"""
SUPERVISOR = r"""
import json,os,subprocess,sys
arguments=json.loads(sys.argv[1]); inherited=int(sys.argv[2])
worker=subprocess.Popen(arguments,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,pass_fds=(inherited,))
os.close(inherited)
output,error=worker.communicate()
print(json.dumps({'status':worker.returncode,'stdout':output.decode(),'stderr':error.decode()}),flush=True)
# Keep the owned process-group anchor alive until the fixture releases it.
sys.stdin.buffer.read(1)
"""


def resolve_lua():
    """Resolve the requested runtime without hiding an empty or missing setting."""
    executable = shutil.which(os.environ.get("LUA", "lua"))
    if not executable:
        raise RuntimeError("Lua 5.4 is required for the native arming control")
    return executable


def hostile_interpreter_control(driver, temporary):
    """Run the actual case matrix with configured Lua and an unusable bare lua."""
    configured = resolve_lua()
    with tempfile.TemporaryDirectory(prefix="arming-interpreter-", dir=temporary) as folder:
        root = Path(folder)
        marker = root / "wrong-bare-runtime"
        executable = root / "lua"
        executable.write_text(
            "#!/bin/sh\nprintf 'wrong bare lua selected\\n' >&2\nprintf used > "
            + shlex.quote(str(marker))
            + "\nexit 66\n"
        )
        executable.chmod(0o700)
        environment = dict(
            os.environ, LUA=configured, PATH=str(root) + os.pathsep + os.environ.get("PATH", "")
        )
        result = subprocess.run(
            [sys.executable, "-B", str(Path(__file__).resolve()), str(driver), str(temporary)],
            env=environment,
            text=True,
            capture_output=True,
            check=False,
        )
        if marker.exists():
            raise RuntimeError(
                "The arming fixture invoked the hostile bare lua instead of configured LUA"
            )
        if result.returncode != 0:
            raise RuntimeError("Configured interpreter arming control failed:\n" + result.stderr)
        cases = json.loads(result.stdout)
        for case in cases:
            case["configured_lua"] = configured
            case["hostile_bare_used"] = False
        return cases


def read_line(process):
    """Read one bounded receipt while retaining the exact supervisor capability."""
    ready, _, _ = select.select([process.stdout], [], [], CONTROL_TIMEOUT_SECONDS)
    if not ready:
        raise TimeoutError("The owned detached-shell supervisor did not answer")
    line = process.stdout.readline()
    if not line:
        raise RuntimeError("The owned supervisor exited without a receipt")
    return json.loads(line)


def await_eof(descriptor):
    """All shell descendants retain this fixture-only descriptor until exit."""
    ready, _, _ = select.select([descriptor], [], [], CONTROL_TIMEOUT_SECONDS)
    if not ready:
        return False
    if os.read(descriptor, 1) != b"":
        raise RuntimeError("The lifetime descriptor unexpectedly carried data")
    return True


def run_case(driver, temporary, mode, lua):
    """Keep every process within an owned group until its lifetime EOF is observed."""
    with tempfile.TemporaryDirectory(prefix="arming-", dir=temporary) as folder:
        root = Path(folder)
        app = root / "Installed ' literal.app"
        staged = root / "stage/app/ErgoptiPlus.app"
        app.mkdir()
        staged.mkdir(parents=True)
        (app / "marker").write_text("installed")
        (staged / "marker").write_text("chosen")
        opened = root / "opened"
        native_open = root / "open"
        native_open.write_text(
            "#!/bin/sh\nprintf '%s\\n' \"$2\" > " + shlex.quote(str(opened)) + "\n"
        )
        native_open.chmod(0o700)
        parent = subprocess.Popen(["/bin/cat"], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL)
        supervisor = None
        read_fd, write_fd = os.pipe()
        retired = False
        stage = root / "stage"
        mutations = {
            "early_exit": "exit 17",
            "missing": "exec 3>&-; exit 17",
            "foreign": "printf 'FOREIGN\\n' >&3; exec 3>&-; exit 0",
            "duplicate": "printf 'ARMED\\nARMED\\n' >&3; exec 3>&-; exit 0",
            "no_lf": "printf ARMED >&3; exec 3>&-; exit 0",
            "trailing_fragment": "printf 'ARMED\\nextra' >&3; exec 3>&-; exit 0",
        }
        try:
            capture = subprocess.run(
                [
                    lua,
                    "-",
                    str(driver),
                    str(driver.parent / "_shared"),
                    str(app),
                    str(staged),
                    str(parent.pid),
                    mutations.get(mode, ""),
                ],
                input=CAPTURE,
                text=True,
                capture_output=True,
                timeout=CONTROL_TIMEOUT_SECONDS,
                check=True,
            )
            command = json.loads(capture.stdout)
            # The only replacement is the native LaunchServices boundary. All
            # moves and the real parent-exit wait remain the production script.
            command["args"][3] = command["args"][3].replace(
                "/usr/bin/open", shlex.quote(str(native_open))
            )
            if mode == "log_refused":
                stage.chmod(0o500)
                if os.access(stage, os.W_OK):
                    raise RuntimeError("The controlled log refusal is not physically active")
            arguments = [command["executable"], *command["args"]]
            supervisor = subprocess.Popen(
                [sys.executable, "-c", SUPERVISOR, json.dumps(arguments), str(write_fd)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                pass_fds=(write_fd,),
                start_new_session=True,
            )
            os.close(write_fd)
            write_fd = None
            receipt = read_line(supervisor)
            before = (app / "marker").read_text()
            parent.stdin.close()
            parent.wait(timeout=CONTROL_TIMEOUT_SECONDS)
            retired = await_eof(read_fd)
            if not retired:
                raise TimeoutError("An owned detached worker retained its lifetime descriptor")
            receipt.update(
                {
                    "mode": mode,
                    "interpreter_version": command["interpreter_version"],
                    "before_parent_exit": before,
                    "installed": (app / "marker").read_text(),
                    "previous": (Path(str(app) + ".previous") / "marker").read_text()
                    if Path(str(app) + ".previous").exists()
                    else None,
                    "opened": opened.read_text() if opened.exists() else None,
                    "log_exists": (stage / "swap.log").exists(),
                    "retired": retired,
                }
            )
            return receipt
        finally:
            if parent.stdin and not parent.stdin.closed:
                parent.stdin.close()
            try:
                parent.wait(timeout=CONTROL_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                parent.kill()
                parent.wait(timeout=CONTROL_TIMEOUT_SECONDS)
            if supervisor is not None:
                if not retired:
                    # Do not poll/reap the group anchor before signalling: its
                    # unreaped PID prevents reuse of this owned process group.
                    try:
                        os.killpg(supervisor.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    if not await_eof(read_fd):
                        raise RuntimeError("The exact owned process group did not retire")
                if supervisor.stdin and not supervisor.stdin.closed:
                    supervisor.stdin.close()
                supervisor.wait(timeout=CONTROL_TIMEOUT_SECONDS)
            if write_fd is not None:
                os.close(write_fd)
            os.close(read_fd)
            stage.chmod(0o700)


def main():
    """Return observations; the registered Lua cases own the semantic assertions."""
    if os.name != "posix" or os.geteuid() == 0:
        raise RuntimeError("Physical arming controls require an unprivileged POSIX host")
    driver, temporary = map(Path, sys.argv[1:3])
    if sys.argv[3:] == ["--hostile-interpreter"]:
        print(json.dumps(hostile_interpreter_control(driver, temporary)))
        return
    if sys.argv[3:]:
        raise RuntimeError("Unknown arming control arguments")
    lua = resolve_lua()
    modes = (
        "healthy",
        "log_refused",
        "early_exit",
        "missing",
        "foreign",
        "duplicate",
        "no_lf",
        "trailing_fragment",
    )
    print(json.dumps([run_case(driver, temporary, mode, lua) for mode in modes]))


if __name__ == "__main__":
    main()
