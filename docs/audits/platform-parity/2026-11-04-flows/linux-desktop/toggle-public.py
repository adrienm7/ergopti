"""Actual public manager dispatch; real shell with a private native-settings tool."""

import ast, json, os, subprocess, tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parent
TREE = Path("/workspace/ergopti")
node = next(
    n
    for n in ast.walk(ast.parse((BASE / "toggle-race.py").read_text()))
    if isinstance(n, ast.Call)
    and isinstance(n.func, ast.Attribute)
    and isinstance(n.func.value, ast.Name)
    and n.func.value.id == "tool"
    and n.func.attr == "write_text"
)
native = ast.literal_eval(node.args[0])
with tempfile.TemporaryDirectory(prefix="ergopti-public-toggle-") as name:
    directory = Path(name)
    tool = directory / "gsettings"
    tool.write_text(native)
    tool.chmod(0o700)
    lua = directory / "dispatch.lua"
    lua.write_text("""local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate()
require('tests.support.secret_service_fake').isolate()
local helpers=require('tests.helpers')
local Manager=helpers.load_module('modules.gestures.manager')
local uv=require('luv')
local directory=assert(arg[1]); local state=directory..'/state';local log=directory..'/calls'
local original=os.execute;local commands={};local barrier=false
local function quote(s)return "'"..s:gsub("'", "'\\\"'\\\"'").."'" end
os.execute=function(cmd)
 commands[#commands+1]=cmd
 return original('export PATH='..quote(directory..':/usr/bin:/bin')..'; export AUDIT_DIR='..quote(directory)..'; export AUDIT_STATE='..quote(state)..'; export AUDIT_LOG='..quote(log)..'; export AUDIT_BARRIER='..(barrier and '1' or '0')..'; '..cmd)
end
local function write(path,text)local f=assert(io.open(path,'w'));assert(f:write(text));f:close()end
local function read(path)local f=io.open(path,'r');if not f then return ''end;local text=f:read('*a');f:close();return text end
local function wait_sets(expected)
 for _=1,500 do local _,count=read(directory..'/done'):gsub('done', 'done');if count>=expected then return end;uv.sleep(5)end
 error('private worker failed to complete')
end
write(state,'default\\n');write(log,'');write(directory..'/done','')
assert(Manager.execute_action('toggle_dark_mode','tap_3'))
wait_sets(1)
assert(Manager.execute_action('toggle_dark_mode','keyboard__second_binding'))
wait_sets(2)
assert(read(state):match('default'))
print('CONTROL actual manager: sequential accepted dispatches return default')
write(state,'default\\n');write(log,'');write(directory..'/done','');barrier=true
assert(Manager.execute_action('toggle_dark_mode','tap_3'))
assert(Manager.execute_action('toggle_dark_mode','keyboard__second_binding'))
wait_sets(2)
assert(read(state):match('prefer%-dark'))
os.execute=original
assert(#commands==4)
print('REPRO actual manager: two independently named accepted dispatches overlap and leave prefer-dark, losing one toggle')
print(read(log))
""")
    run = subprocess.run(
        ["/workspace/scratch/parity-toolchain/ci-bin/lua", str(lua), str(directory)],
        cwd=TREE,
        capture_output=True,
        text=True,
        timeout=8,
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
    )
    assert run.returncode == 0, (run.stdout, run.stderr)
    print(run.stdout)
    (BASE / "toggle-public.txt").write_text(run.stdout + run.stderr)
