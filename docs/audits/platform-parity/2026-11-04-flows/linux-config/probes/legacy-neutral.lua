local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('test.runner_home').isolate()
require('tests.support.secret_service_fake').isolate()
local P=require('infra.hotstring_preferences')
local I=require('infra.legacy_hotstring_storage')
local Preview=require('modules.hotstrings.preview_settings')
local M=require('infra.manifest_reader')
local base='/workspace/scratch/parity-flows/linux-config/probes/'
local key='hotstrings.preview_ai_enabled'
local neutral=M.default_for(key)
local function read(path) local f=assert(io.open(path,'rb')); local s=f:read('*a');f:close();return s end
for _, failure in ipairs({true,false}) do
 local path=base..(failure and 'refused-delete.toml' or 'successful-delete.toml')
 local f=assert(io.open(path,'wb'));f:write('# private synthetic audit fixture\n');f:close()
 assert(P._set_file_for_test(path))
 local vals={[key]=not neutral}
 local refuse=failure
 local storage={has=function(k)return vals[k]~=nil end,get=function(k,d)if vals[k]==nil then return d end;return vals[k]end,
 delete=function(k)if refuse then return false end;vals[k]=nil;return true end}
 local first=I.import({path=path,storage=storage})
 assert(first==not failure)
 assert(Preview.get('ai')==not neutral)
 assert(Preview.set('ai',neutral))
 assert(Preview.get('ai')==neutral)
 assert(not read(path):find('preview_ai_enabled',1,true))
 refuse=false
 local second=I.import({path=path,storage=storage})
 assert(second)
 local result=Preview.get('ai')
 print('CASE delete_refused='..tostring(failure)..' first='..tostring(first)..' neutral_save=true second='..tostring(second)..' expected_neutral='..tostring(neutral)..' actual_after_restart='..tostring(result))
 if failure then assert(result==not neutral) else assert(result==neutral) end
 print('BYTES '..read(path):gsub('\n',' | '))
 os.remove(path)
end
print('CONFIRMED failed legacy deletion reimports the old nonneutral choice; successful cleanup control preserves neutral')
