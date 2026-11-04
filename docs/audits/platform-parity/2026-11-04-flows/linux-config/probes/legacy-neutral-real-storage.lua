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
local Storage=require('adapters.storage')
assert(Storage.set(key,not neutral))
local storage_path=Storage.path()
local path=base..'real-storage.toml'
local f=assert(io.open(path,'wb'));f:write('# real storage failure audit fixture\n');f:close()
assert(P._set_file_for_test(path))
local rename=os.rename
local refusals=0
os.rename=function(src,dst,...) if dst==storage_path then refusals=refusals+1;return nil,'synthetic native permission denied',13 end;return rename(src,dst,...) end
local called,first=pcall(I.import,{path=path,storage=Storage})
os.rename=rename
assert(called and first==false and refusals>0)
assert(Storage.has(key))
assert(Preview.get('ai')==not neutral)
assert(Preview.set('ai',neutral))
assert(not read(path):find('preview_ai_enabled',1,true))
assert(I.import({path=path,storage=Storage}))
assert(Preview.get('ai')==not neutral)
assert(not Storage.has(key))
print('REAL_STORAGE native_rename_refusals='..refusals..' first_import=false later_neutral_save=true next_import=true old_choice_resurrected=true alias_finally_deleted=true')
print('BYTES '..read(path):gsub('\n',' | '))
os.remove(path)
