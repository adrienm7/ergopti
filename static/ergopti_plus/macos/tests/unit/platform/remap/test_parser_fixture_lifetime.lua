--- tests/unit/platform/remap/test_parser_fixture_lifetime.lua

local helpers=require('tests.helpers')
local with_fixture=require('tests.support.remap_transaction_fixture')
local ALIASES={'infra.toml.codec','toml_codec','toml_codec.codec'}
local function snapshot()local b={};for _,n in ipairs(ALIASES)do b[n]=rawget(package.loaded,n)end;return b end
local function restore(b)for _,n in ipairs(ALIASES)do package.loaded[n]=b[n]end end
local function same(b)for _,n in ipairs(ALIASES)do helpers.assert_eq(rawget(package.loaded,n),b[n],n)end end
local function copy(t)local c={};for k,v in pairs(t)do c[k]=v end;return c end
local function real(fixture)
 local path=os.tmpname();local file=assert(io.open(path,'wb'));file:write('[karabiner\nintegration_enabled = true\n');file:close()
 local manager=fixture.load_enabled_remap({real_user_config_path=path});os.remove(path);return manager
end
helpers.describe('real-source fixture ownership lifetime',function()
 for _,case in ipairs({{label='nil'},{label='false',value=false},{label='table',value={caller=true}}})do
  helpers.it('preserves caller '..case.label..' codec bindings and helper/require identities after success',function()
   local saved,loader,require_port=snapshot(),helpers.load_with_stubs,require
   for _,n in ipairs(ALIASES)do package.loaded[n]=case.value end
   local caller=snapshot()
   local result=table.pack(pcall(function()
    return with_fixture(function(fixture)
     local manager=real(fixture);helpers.assert_type(manager.parser_refusal_token(),'table')
     helpers.load_with_stubs('ui.menu.menu_tap_holds');helpers.assert_type(manager.parser_refusal_token(),'table')
     helpers.assert_eq(require,require_port)
     return 'kept',nil,false
    end)
   end))
   local passed,err=pcall(function()
    helpers.assert_true(result[1],tostring(result[2]));helpers.assert_eq(result.n,4);helpers.assert_eq(result[2],'kept');helpers.assert_nil(result[3]);helpers.assert_eq(result[4],false)
    same(caller);helpers.assert_eq(helpers.load_with_stubs,loader);helpers.assert_eq(require,require_port)
   end)
   restore(saved);if not passed then error(err,0)end
  end)
 end
 helpers.it('body error restores exact loader require and caller codecs',function()
  local saved,loader,require_port=snapshot(),helpers.load_with_stubs,require;local marker={original=true}
  local ok,err=pcall(function()with_fixture(function(fixture)real(fixture);error(marker,0)end)end)
  helpers.assert_eq(ok,false);helpers.assert_eq(err,marker);same(saved);helpers.assert_eq(helpers.load_with_stubs,loader);helpers.assert_eq(require,require_port)
 end)
 helpers.it('named load error restores require immediately and all caller ownership on fixture exit',function()
  local saved,loader,require_port=snapshot(),helpers.load_with_stubs,require
  with_fixture(function(fixture)
   local manager=real(fixture);local owned=snapshot()
   local ok,err=pcall(helpers.load_with_stubs,'__ergopti_missing_lineage_module__')
   helpers.assert_eq(ok,false);helpers.assert_true(tostring(err):find('__ergopti_missing_lineage_module__',1,true)~=nil)
   helpers.assert_eq(require,require_port);same(owned);helpers.assert_type(manager.parser_refusal_token(),'table')
  end)
  same(saved);helpers.assert_eq(helpers.load_with_stubs,loader);helpers.assert_eq(require,require_port)
 end)
 helpers.it('explicit pre-call fake alias is preserved as unqualified input',function()
  with_fixture(function(fixture)
   local manager=real(fixture);local fake=copy(require('infra.toml.codec'))
   package.loaded['infra.toml.codec']=fake
   helpers.load_with_stubs('ui.menu.menu_tap_holds')
   helpers.assert_eq(package.loaded['infra.toml.codec'],fake);helpers.assert_nil(manager.parser_refusal_token())
  end)
 end)
 helpers.it('a constructor replacement persists after named-source handoff',function()
  local name='tests.private_lineage_constructor';local prior=package.preload[name]
  local ran,err=pcall(function()
   with_fixture(function(fixture)
    local manager=real(fixture);local fake=copy(require('infra.toml.codec'))
    package.preload[name]=function()package.loaded['infra.toml.codec']=fake;return {constructor=true}end
    local result=helpers.load_with_stubs(name)
    helpers.assert_true(result.constructor);helpers.assert_eq(package.loaded['infra.toml.codec'],fake);helpers.assert_nil(manager.parser_refusal_token())
   end)
  end)
  package.preload[name]=prior;if not ran then error(err,0)end
 end)
 helpers.it('model fixture retains original codec clearing behavior',function()
  with_fixture(function(fixture)
   fixture.load_enabled_remap()
   local fake=copy(require('infra.toml.codec'));package.loaded['infra.toml.codec']=fake
   helpers.load_with_stubs('ui.menu.menu_tap_holds')
   helpers.assert_true(package.loaded['infra.toml.codec']~=fake)
  end)
 end)
 helpers.it('nested helper loads retain outer require binding and caller cleanup',function()
  local outer,inner='tests.private_lineage_outer','tests.private_lineage_inner'
  local a,b=package.preload[outer],package.preload[inner];local loader,require_port,saved=helpers.load_with_stubs,require,snapshot()
  local ran,err=pcall(function()
   with_fixture(function(fixture)
    real(fixture)
    package.preload[inner]=function()return {inner=true}end
    package.preload[outer]=function()
     local within=require;local result=helpers.load_with_stubs(inner)
     helpers.assert_true(result.inner);helpers.assert_eq(require,within);return {outer=true}
    end
    helpers.assert_true(helpers.load_with_stubs(outer).outer);helpers.assert_eq(require,require_port)
   end)
  end)
  package.preload[outer],package.preload[inner]=a,b
  helpers.assert_eq(require,require_port);helpers.assert_eq(helpers.load_with_stubs,loader);same(saved);if not ran then error(err,0)end
 end)
 helpers.it('an early same-name internal helper require leaks no caller binding and stays unqualified',function()
  local saved,loader,require_port=snapshot(),helpers.load_with_stubs,require
  with_fixture(function(fixture)
   local manager=real(fixture)
   helpers.load_with_stubs('tests.stubs.hs')
   helpers.assert_eq(require,require_port);helpers.assert_nil(manager.parser_refusal_token())
  end)
  same(saved);helpers.assert_eq(helpers.load_with_stubs,loader);helpers.assert_eq(require,require_port)
 end)
end)
return true
