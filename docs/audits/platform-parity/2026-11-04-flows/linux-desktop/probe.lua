local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root .. 'linux/?.lua;' .. root .. 'linux/?/init.lua;' .. root .. '_shared/lua/?.lua;' .. root .. '_shared/lua/?/init.lua;' .. package.path
local helpers = require('tests.helpers')
local Gestures = helpers.load_module('modules.gestures.manager')
local Logger = require('logger.shim')
local recorded, logs = {}, {}
for _, name in ipairs({'error','warn','info','debug'}) do
 Logger[name] = function(...) logs[#logs+1] = {name,...} end
end
local original = os.execute
local function run(mode)
 recorded, logs = {}, {}
 os.execute = function(command)
  recorded[#recorded+1] = command
  if command:find('command -v',1,true) then return true,'exit',0 end
  if mode == 'throw' then error('recorded shell acquisition failed') end
  if mode == 'refuse' then return nil,'exit',126 end
  return true,'exit',0
 end
 local result = Gestures.execute_action('mic_mute_toggle','tap_3')
 os.execute = original
 assert(#recorded==1 and recorded[1]:find('pactl set-source-mute',1,true), 'must reach actual command producer')
 local errors=0
 for _, row in ipairs(logs) do if row[1]=='error' or row[1]=='warn' then errors=errors+1 end end
 assert(result == true,'public dispatch acknowledges name')
 assert(errors==0,'current producer unexpectedly reports failure')
 print(mode .. ': public result=true; command attempts=' .. #recorded .. '; diagnostics=' .. errors)
end
run('refuse')
run('throw')
run('healthy')
local uv = require('luv')
local directory = os.tmpname()
os.remove(directory)
assert(uv.fs_mkdir(directory,448))
local marker = directory .. '/native-refusal.txt'
local fake = assert(io.open(directory .. '/pactl','w'))
fake:write('#!/bin/sh\nprintf "native reached; exit 37\\n" > "$PARITY_FLOW_MARKER"\nprintf "simulated native refusal\\n" >&2\nexit 37\n')
fake:close()
assert(uv.fs_chmod(directory .. '/pactl',448))
recorded, logs = {}, {}
os.execute = function(command)
 recorded[#recorded+1] = command
 return original("export PATH='" .. directory .. ":/usr/bin:/bin'; export PARITY_FLOW_MARKER='" .. marker .. "'; " .. command)
end
local result=Gestures.execute_action('mic_mute_toggle','tap_3')
os.execute=original
local observed
for _=1,100 do
 local file=io.open(marker,'r')
 if file then observed=file:read('*a');file:close();break end
 uv.sleep(5)
end
assert(result==true and observed=='native reached; exit 37\n')
local errors=0
for _, row in ipairs(logs) do if row[1]=='error' or row[1]=='warn' then errors=errors+1 end end
assert(errors==0)
assert(uv.fs_unlink(marker));assert(uv.fs_unlink(directory .. '/pactl'));assert(uv.fs_rmdir(directory))
print('actual POSIX shell + fake pactl exit37: native command reached, asynchronous child refusal lost, public result=true, diagnostics=0')
