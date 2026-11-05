local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local P=require('infra.config_paths');local Shell=require('adapters.shell_runner')
local basedir='/workspace/scratch/parity-sequential-2026-11-05/personal-info/linux/probes/'
local effective=basedir..'private-effective'
assert(P.set_config_dir(effective));assert(P.get_config_dir()==effective)
local default=P.default_config_dir();assert(default~=effective)
assert(Shell.run('mkdir -p -- '..Shell.quote(default)))
local function seed(path,value)
 local f=assert(io.open(path,'wb'));assert(f:write('[info]\nfirst_name="'..value..'"\n[letters]\np="first_name"\n'));assert(f:close())
end
seed(default..'/personal_info.toml','DEFAULT_VALUE')
seed(P.config('personal_info.toml'),'EFFECTIVE_VALUE')
local D=require('modules.dynamic_hotstrings.manager');assert(D.init({trigger_char='★'}))
assert(D.get_info().first_name=='DEFAULT_VALUE')
local receipt,shown=assert(D.capture_info_edit());assert(shown.first_name=='DEFAULT_VALUE')
assert(D.save_info({first_name='EDITED_DEFAULT'},receipt))
local Codec=require('toml_codec')
local function value(path) local f=assert(io.open(path,'rb'));local bytes=f:read('*a');f:close();return Codec.decode(bytes).info.first_name end
assert(value(default..'/personal_info.toml')=='EDITED_DEFAULT')
assert(value(P.config('personal_info.toml'))=='EFFECTIVE_VALUE')
print('CONFIG_OVERRIDE acknowledged=true effective_route_differs=true')
print('DYNAMIC_INIT loaded=DEFAULT_VALUE effective_file=EFFECTIVE_VALUE')
print('EDITOR_SAVE default_file=EDITED_DEFAULT effective_file=EFFECTIVE_VALUE')
assert(D.init({personal_info_path=P.config('personal_info.toml'),trigger_char='★'}))
assert(D.get_info().first_name=='EFFECTIVE_VALUE')
print('EXPLICIT_PATH_CONTROL loaded=EFFECTIVE_VALUE')
print('PASS actual config paths+Storage+dynamic owner+TOML writer, isolated private files; no user configuration')
