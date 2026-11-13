#!/usr/bin/env python3
"""Exercise actual owned entry points through delimiter-bearing AppDir paths."""

import os
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

source = Path(sys.argv[1]).resolve()
repo = source.parents[2]
luajit = shutil.which("luajit")
sqlite = shutil.which("sqlite3")
assert luajit and sqlite, "Linux integration requires luajit and sqlite3"


def host_glibc():
    """The C library glibc reports, or None on another one (musl on Alpine)."""
    try:
        return os.confstr("CS_GNU_LIBC_VERSION")
    except (ValueError, OSError):
        return None


# The AppImage runs on the recipient's glibc; its AppRun preflight refuses any
# other C library with EX_UNAVAILABLE before the bundled loader would fail.
APPIMAGE_REFUSAL_EXIT = 69


def run(argv, *, env=None, input=None, cwd=None, timeout=8):
    p = subprocess.run(
        [str(x) for x in argv],
        env=env,
        input=input,
        cwd=cwd,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    assert p.returncode == 0, (argv, p.returncode, p.stdout, p.stderr)
    return p.stdout


def module_path(name):
    return Path(
        run([luajit, "-e", 'io.write(assert(package.searchpath("' + name + '",package.cpath)))'])
    )


with tempfile.TemporaryDirectory(prefix="ergopti-literal-") as temporary:
    scratch = Path(temporary)
    normal = scratch / "normal-driver"
    normal.mkdir()
    clean_admission = r"""source "$1/install/native_modules_env.sh"
export ERGOPTI_LITERAL_NATIVE_MODULES=1
ergopti_admit_native_modules "$3" optional
test -z "${ERGOPTI_LITERAL_NATIVE_MODULES:-}"
export ERGOPTI_LITERAL_NATIVE_MODULES=1
ergopti_admit_native_modules "$2" required
test -z "${ERGOPTI_LITERAL_NATIVE_MODULES:-}"
"""
    # Exercise both outcomes with separate calls: the first has no directory,
    # the second has a real module in a path without Lua template delimiters.
    absent = scratch / "absent-driver"
    absent.mkdir()
    (normal / "native_modules").mkdir()
    shutil.copy2(module_path("luv"), normal / "native_modules/luv.so")
    run(["bash", "-c", clean_admission, "native-cleanup", source, normal, absent])
    app = scratch / "App;dir"
    driver = app / "linux"
    driver.mkdir(parents=True)
    for entry in source.iterdir():
        if entry.name in ("install", "tests"):
            continue
        (driver / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    install = driver / "install"
    install.mkdir()
    for entry in (source / "install").iterdir():
        (install / entry.name).symlink_to(entry, target_is_directory=entry.is_dir())
    (app / "_shared").symlink_to(source.parent / "_shared", target_is_directory=True)
    (driver / "_shared").symlink_to("../_shared", target_is_directory=True)
    usr = app / "usr"
    (usr / "bin").mkdir(parents=True)
    (usr / "lib").mkdir(parents=True)
    (usr / "lib/ergopti").symlink_to("../../linux", target_is_directory=True)
    shutil.copy2(luajit, usr / "bin/luajit")
    shutil.copy2(sqlite, usr / "bin/sqlite3")
    for name in ("curl", "openssl", "zstd"):
        (usr / "bin" / name).symlink_to("/bin/true")
    native = usr / "lib/lua/5.1"
    native.mkdir(parents=True)
    for name in ("luv", "lfs"):
        shutil.copy2(module_path(name), native / (name + ".so"))
    standalone_native = driver / "native_modules"
    standalone_native.mkdir()
    for name in ("luv", "lfs"):
        shutil.copy2(module_path(name), standalone_native / (name + ".so"))
    (app / "bin").mkdir()
    (app / "bin/ergopti").symlink_to(source / "install/standalone_launcher.sh")
    for name in (
        "lib/lua/5.1/posix/sys/stat.so",
        "share/lua/5.1/posix/init.lua",
        "lib/gio/modules/libgiolibproxy.so",
        "share/glib-2.0/schemas/gschemas.compiled",
    ):
        path = usr / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.touch()
    # Replace two source links with generated installed files inside the fixture.
    for name in ("network-runtime-env.sh", "libc-preflight.sh"):
        path = driver / name
        if path.is_symlink():
            path.unlink()
    shutil.copy2(
        repo / "tools/build/templates/linux-portable-runtime-env.sh",
        driver / "network-runtime-env.sh",
    )
    run(
        [
            "node",
            repo / "tools/build/render-appimage-libc-preflight.cjs",
            driver / "libc-preflight.sh",
        ]
    )
    builder = (repo / "tools/build/build-linux-appimage.sh").read_text()
    apprun = builder.split("cat > \"$APPDIR/AppRun\" << 'APPRUN_EOF'\n", 1)[1].split(
        "\nAPPRUN_EOF", 1
    )[0]
    (app / "AppRun").write_text(apprun)
    (app / "AppRun").chmod(0o755)
    home = scratch / "home"
    home.mkdir()
    fifo = scratch / "config.fifo"
    os.mkfifo(fifo)
    for spoof in (scratch / "dir/linux", scratch / "Appliteral_module_absentdir/linux"):
        spoof.mkdir(parents=True)
        (spoof / "literal_module_absent.lua").write_text('error("wrong path searched")\n')
    host = scratch / "host"
    host.mkdir()
    fake_bin = scratch / "bin"
    fake_bin.mkdir()
    opener = fake_bin / "xdg-open"
    opener.write_text("#!/bin/sh\nexit 0\n")
    opener.chmod(0o755)
    (host / "literal_host.lua").write_text('return "host"\n')
    (host / "literal_priority.lua").write_text('return "host"\n')
    (driver / "literal_priority.lua").write_text('return "driver"\n')
    (driver / "literal_collision").mkdir()
    (driver / "literal_collision/init.lua").write_text('return "driver-init"\n')
    alternate_shared = scratch / "alternate-shared"
    alternate_shared.mkdir()
    (alternate_shared / "literal_collision.lua").write_text('return "shared-file"\n')
    (native / "literal_broken.so").write_text("invalid shared object\n")
    # Created once and renamed: no repeated copy of the source or runtime.
    for component in ("App;dir", "App?dir"):
        next_app = scratch / component
        if next_app != app:
            app.rename(next_app)
            app = next_app
        driver, usr = app / "linux", app / "usr"
        env = {
            **os.environ,
            "HOME": str(home),
            "XDG_RUNTIME_DIR": str(home),
            "LUA_PATH": ";;",
            "LUA_CPATH": ";;",
            "PATH": str(fake_bin) + os.pathsep + os.environ["PATH"],
            "ERGOPTI_LITERAL_DRIVER_ROOT": str(driver),
            "ERGOPTI_LITERAL_SHARED_ROOT": str(app / "_shared"),
            "ERGOPTI_RUNTIME_PREFIX": str(usr),
        }
        for name in (
            "ERGOPTI_LITERAL_DIRECT",
            "ERGOPTI_LITERAL_DAEMON",
            "ERGOPTI_LITERAL_NATIVE_MODULES",
        ):
            env.pop(name, None)
        if host_glibc() is None:
            # musl cannot load glibc programs: the literal AppDir still has to
            # reach the preflight and refuse there, naming the cause.
            refused = subprocess.run(
                [str(app / "AppRun"), "--help"],
                env=env,
                text=True,
                capture_output=True,
                timeout=8,
            )
            assert refused.returncode == APPIMAGE_REFUSAL_EXIT, (
                refused.returncode,
                refused.stdout,
                refused.stderr,
            )
            assert "musl" in refused.stderr, refused.stderr
        else:
            assert "Usage:" in run([app / "AppRun", "--help"], env=env)
        direct = env.copy()
        for name in (
            "ERGOPTI_LITERAL_DRIVER_ROOT",
            "ERGOPTI_LITERAL_SHARED_ROOT",
            "ERGOPTI_RUNTIME_PREFIX",
        ):
            direct.pop(name, None)
        assert "Usage:" in run([luajit, driver / "ergopti_hotstrings.lua", "--help"], env=direct)
        assert "Usage:" in run([luajit, "ergopti_hotstrings.lua", "--help"], env=direct, cwd=driver)
        check_env = """local exit=os.exit; os.exit=function(n)
assert(os.getenv('ERGOPTI_LITERAL_DRIVER_ROOT'), 'relative entry did not export its root')
assert(os.getenv('ERGOPTI_LITERAL_DAEMON')=='1', 'daemon did not export its search order')
local shared=assert(os.getenv('ERGOPTI_LITERAL_SHARED_ROOT'))
local child=assert(io.popen('luajit ./adapters/atspi_context_worker.lua bus / 0 '..string.format('%q',shared)..' 1 invalid 2>&1'))
local result=child:read('*a'); child:close()
assert(result:find('context worker parent already exited',1,true), result)
exit(n) end
arg={[0]='ergopti_hotstrings.lua','--help'}; dofile('ergopti_hotstrings.lua')"""
        assert "Usage:" in run([luajit, "-e", check_env], env=direct, cwd=driver)
        db = scratch / (component + ".sqlite")
        assert (
            run(
                [
                    usr / "bin/luajit",
                    driver / "core/process/adapters/sqlite_process_worker.lua",
                    str(os.getpid()),
                    db,
                ],
                env=env,
                input="select 42;\n",
            )
            == "42\n"
        )
        relative_db = scratch / (component + "-relative.sqlite")
        assert (
            run(
                [
                    usr / "bin/luajit",
                    "./adapters/sqlite_process_worker.lua",
                    str(os.getpid()),
                    relative_db,
                ],
                env=env,
                cwd=driver,
                input="select 43;\n",
            )
            == "43\n"
        )
        run(
            [
                usr / "bin/luajit",
                driver / "adapters/desktop_opener_worker.lua",
                "https://example.invalid/",
                "1000",
            ],
            env=env,
        )
        proxy = run(
            [
                usr / "bin/luajit",
                driver / "core/network/adapters/system_proxy_probe.lua",
                app / "_shared",
            ],
            env=env,
            input="{}",
        )
        assert "proxy-request-invalid" in proxy
        runtime_probe = subprocess.run(
            [
                usr / "bin/luajit",
                driver / "core/network/adapters/runtime_probe.lua",
                app / "_shared",
            ],
            env=env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        assert runtime_probe.returncode in (0, 1), runtime_probe.stderr
        assert isinstance(json.loads(runtime_probe.stdout).get("ok"), bool), runtime_probe.stderr
        assert "module '" not in runtime_probe.stderr, runtime_probe.stderr
        rejected = subprocess.run(
            [usr / "bin/luajit", driver / "platform/window_switch_worker.lua"],
            env=env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        assert rejected.returncode == 1 and rejected.stderr == "", (
            rejected.stdout,
            rejected.stderr,
        )
        context = subprocess.run(
            [
                usr / "bin/luajit",
                "./adapters/atspi_context_worker.lua",
                "bus",
                "/",
                "0",
                app / "_shared",
                str(os.getpid()),
                "invalid",
            ],
            cwd=driver,
            env=env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        assert context.returncode != 0 and "unknown context worker operation" in context.stderr, (
            context.stderr
        )
        watch = subprocess.run(
            [
                usr / "bin/luajit",
                "./adapters/atspi_focus_watch_worker.lua",
                "0",
                "0",
                "0",
                "0",
                app / "_shared",
            ],
            cwd=driver,
            env=env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        assert watch.returncode == 1 and "stopped without authority" in watch.stderr, watch.stderr
        dialog = subprocess.run(
            [usr / "bin/luajit", driver / "ui/dialog_host.lua", "--invalid"],
            env=env,
            text=True,
            capture_output=True,
            timeout=8,
        )
        assert dialog.returncode != 0 and "module " not in dialog.stderr, dialog.stderr
        standalone = env.copy()
        for name in (
            "ERGOPTI_RUNTIME_PREFIX",
            "ERGOPTI_LITERAL_DRIVER_ROOT",
            "ERGOPTI_LITERAL_SHARED_ROOT",
            "ERGOPTI_LITERAL_DIRECT",
        ):
            standalone.pop(name, None)
        assert "Usage:" in run(["bash", app / "bin/ergopti", "--help"], env=standalone)
        # The real admission owner supplies a literal C root before any host
        # modules; invalid host candidates make an accidental fallback fail.
        for name in ("luv", "lfs"):
            (host / (name + ".so")).write_text("invalid host module")
        standalone["LUA_CPATH"] = str(host / "?.so") + ";;"
        admission = r"""source "$1/install/native_modules_env.sh"
ergopti_admit_native_modules "$1" required
export ERGOPTI_LITERAL_DRIVER_ROOT="$1" ERGOPTI_LITERAL_SHARED_ROOT="$2"
exec "$3" -e 'local d=os.getenv("ERGOPTI_LITERAL_DRIVER_ROOT"); assert(os.getenv("ERGOPTI_LITERAL_NATIVE_MODULES")=="1"); assert(loadfile(d.."/core/lifecycle/engine/literal_module_loader.lua"))().install(d,os.getenv("ERGOPTI_LITERAL_SHARED_ROOT")); assert(type(require("luv").new_timer)=="function"); assert(type(require("lfs").attributes)=="function")'
"""
        run(
            ["bash", "-c", admission, "native-test", driver, app / "_shared", luajit],
            env=standalone,
        )
        direct_native = r"""
local d=os.getenv('LITERAL_DRIVER'); local s=os.getenv('LITERAL_SHARED')
assert(loadfile(d..'/core/lifecycle/engine/literal_module_loader.lua'))().install(d,s,nil,'direct')
local ok,err=pcall(require,'lfs')
assert(not ok and err:find('error loading',1,true), 'direct entry must retain host native errors')
"""
        direct_native_env = dict(
            standalone, LITERAL_DRIVER=str(driver), LITERAL_SHARED=str(app / "_shared")
        )
        run([luajit, "-e", direct_native], env=direct_native_env)
        lua = r"""
local d=os.getenv('ERGOPTI_LITERAL_DRIVER_ROOT')
local s=os.getenv('ERGOPTI_LITERAL_SHARED_ROOT')
local owner=assert(loadfile(d..'/core/lifecycle/engine/literal_module_loader.lua'))().install(d,s,os.getenv('ERGOPTI_RUNTIME_PREFIX'),'daemon')
package.path=os.getenv('LITERAL_HOST')..'/?.lua;'..package.path
package.preload.lfs=function() return 'preload' end
assert(require('lfs')=='preload')
package.preload.lfs=nil; package.loaded.lfs=nil
assert(type(require('lfs').attributes)=='function')
assert(type(require('luv').new_timer)=='function')
assert(require('literal_host')=='host')
package.preload.literal_priority=function() return 'preload' end
assert(require('literal_priority')=='preload')
package.preload.literal_priority=nil; package.loaded.literal_priority=nil
assert(require('literal_priority')=='driver')
local broken, native_err=pcall(require,'literal_broken')
assert(not broken and native_err:find('literal_broken',1,true) and native_err:find('error loading',1,true))
local ok,err=pcall(require,'literal_module_absent')
assert(not ok and err:find('literal_module_absent',1,true))
assert(owner.searchpath('core.fs.engine.regular_file_reader',package.path))
local stream= require('core.text.engine.toml_codec.source_open').open(os.getenv('LITERAL_FIFO'))
assert(stream==nil, 'FIFO must be refused')
local writer = require('core.text.engine.toml_codec.writer')
local written = writer.publish_if_unchanged(os.getenv('LITERAL_FIFO'), 'k=1\n', nil, {status='absent'})
assert(not written, 'FIFO create-only publication must be refused')
print('ok')
"""
        env["LITERAL_HOST"] = str(host)
        env["LITERAL_FIFO"] = str(fifo)
        assert run([usr / "bin/luajit", "-e", lua], env=env, cwd=scratch) == "ok\n"
        order = r"""
local d=os.getenv('ERGOPTI_LITERAL_DRIVER_ROOT')
local owner=assert(loadfile(d..'/core/lifecycle/engine/literal_module_loader.lua'))()
owner.install(d,os.getenv('LITERAL_ALTERNATE_SHARED'),nil,os.getenv('LITERAL_MODE'))
assert(require('literal_collision') == os.getenv('LITERAL_EXPECTED'))
"""
        for mode, expected in (("base", "driver-init"), ("daemon", "shared-file")):
            ordering = dict(
                env,
                LITERAL_ALTERNATE_SHARED=str(alternate_shared),
                LITERAL_MODE=mode,
                LITERAL_EXPECTED=expected,
            )
            run([usr / "bin/luajit", "-e", order], env=ordering)
        # Stale inherited roots must not make a different direct checkout run.
        stale = direct.copy()
        stale["ERGOPTI_LITERAL_DRIVER_ROOT"] = str(scratch / "retired")
        stale["ERGOPTI_LITERAL_SHARED_ROOT"] = str(scratch / "retired/shared")
        assert "Usage:" in run([luajit, source / "ergopti_hotstrings.lua", "--help"], env=stale)
print("literal AppDir integration passed")
