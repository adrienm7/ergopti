--- tests/unit/platform/remap/test_parser_query_integrity.lua

--- Independent genuine published Config public-reader substitution challenge.
local helpers = require('tests.helpers')
local with_fixture = require('tests.support.remap_transaction_fixture')
local CORRUPT = '[karabiner\nintegration_enabled = true\n'
local function with_actual(body)
 local path = os.tmpname(); local f=assert(io.open(path,'wb'));assert(f:write(CORRUPT));f:close()
 local ok,err=pcall(function()
  with_fixture(function(fixture)
   fixture.load_enabled_remap({real_user_config_path=path})
   local config=assert(loadfile('platform/remap/config.lua'))()
   package.loaded['platform.remap.config']=config
   local remap=assert(loadfile('platform/remap/init.lua'))()
   package.loaded['platform.remap']=remap
   local paths=require('infra.config_paths'); local get=paths.get
   paths.get=function(key,...)
    if key=='KarabinerConfigPath' then return path end
    return get(key,...)
   end
   local ran,detail=pcall(body,remap,config,package.loaded['infra.logger'],path)
   paths.get=get
   if not ran then error(detail,0) end
  end)
 end)
 os.remove(path);os.remove(path..'.tmp');if not ok then error(err,0) end
end

helpers.describe('public manager parser query integrity',function()
 helpers.it('actual future refusal cannot gain Clear All from a pre-menu fake parser query',function()
  with_actual(function(manager,config,_,path)
   local f=assert(io.open(path,'wb'));f:write('[karabiner]\nruntime = "future-runtime"\nintegration_enabled = true\n');f:close()
   helpers.assert_eq(manager.init({expand_path=function(v)return v end}),false)
   helpers.assert_nil(manager.parser_refusal_token())
   local original=manager.parser_refusal_token;local counterfeit={}
   manager.parser_refusal_token=function()return counterfeit end
   local menu=assert(loadfile(assert(package.searchpath('ui.menu.menu_tap_holds',package.path))))()
   local function find(row)
    if row.title=='common.clear_to_system' or row.label=='common.clear_to_system' then return row end
    for _,child in ipairs(row.menu or row.submenu or row.items or {})do local result=find(child);if result then return result end end
   end
   local row=find(menu.build({karabiner=manager,updateMenu=function()end}))
   manager.parser_refusal_token=original
   helpers.assert_nil(row,'a forged public query does not authenticate genuine parser failure')
  end)
 end)
end)
return true
