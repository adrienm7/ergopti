local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('test.runner_home').isolate()
require('tests.support.secret_service_fake').isolate()
local Storage=require('adapters.storage')
local Paths=require('infra.config_paths')
local Scope=require('infra.script_scope')
local I18n=require('infra.i18n')
local base='/workspace/scratch/parity-flows/linux-config/probes'
assert(Paths.set_config_dir(base))
local path=base..'/config.toml'
local function read() local f=assert(io.open(path,'rb'));local s=f:read('*a');f:close();return s end
for _, present in ipairs({true,false}) do
 local f=assert(io.open(path,'wb'));f:write(present and '[script]\nlocale = "fr"\n' or '# no explicit script locale\n');f:close()
 assert(Storage.set('locale','fr'))
 package.loaded['infra.i18n']=nil
 I18n=require('infra.i18n')
 I18n.init()
 assert(I18n.get_locale()=='fr')
 local rename=os.rename
 local refusals=0
 os.rename=function(src,dst,...) if dst==Storage.path() then refusals=refusals+1;return nil,'synthetic native permission denied',13 end;return rename(src,dst,...) end
 local called,result=pcall(I18n.set_locale,'en')
 os.rename=rename
 assert(called and result==false and refusals>0)
 assert(I18n.get_locale()=='fr' and Storage.get('locale')=='fr')
 local after=read()
 Scope.adopt_configured()
 package.loaded['infra.i18n']=nil
 I18n=require('infra.i18n')
 I18n.init()
 local actual=I18n.get_locale()
 assert(actual==(present and 'en' or 'fr'))
 print('CASE existing_config_row='..tostring(present)..' setter=false active_and_native_alias_on_return=fr native_refusals='..refusals..' startup_locale='..actual)
 print('BYTES '..after:gsub('\n',' | '))
end
os.remove(path)
print('CONFIRMED existing config row changes despite rejected locale setter; absent-row control preserves fr')
