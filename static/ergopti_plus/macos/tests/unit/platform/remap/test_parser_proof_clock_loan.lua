--- tests/unit/platform/remap/test_parser_proof_clock_loan.lua

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

local function write(path,bytes)local file=assert(io.open(path,'wb'));assert(file:write(bytes));file:close()end
local FUTURE='[karabiner]\nruntime = "future-runtime"\nintegration_enabled = true\n'
local function init(remap)return remap.init({expand_path=function(v)return v end})end
local function no_clear(remap)
 local menu=assert(loadfile(assert(package.searchpath('ui.menu.menu_tap_holds',package.path))))()
 local function has(row)
  if row.title=='common.clear_to_system' or row.label=='common.clear_to_system' then return true end
  for _,child in ipairs(row.menu or row.submenu or row.items or {}) do if has(child) then return true end end
  return false
 end
 helpers.assert_eq(has(menu.build({karabiner=remap,updateMenu=function()end})),false)
end
helpers.describe('genuine parser proof clock loan',function()
 helpers.it('a temporary manager-clock reader restores its field but cannot loan an unused malformed proof to a real future file',function()
  with_actual(function(manager,config,_,path)
   local _,_,_,_,proof=config.load_user_config({}, {},path);helpers.assert_type(proof,'table')
   write(path,FUTURE)
   local original=config.load_user_config;local clock=hs.timer.absoluteTime;local armed,calls=true,0
   hs.timer.absoluteTime=function(...)
    local results=table.pack(clock(...))
    if armed then armed=false;config.load_user_config=function()calls=calls+1;config.load_user_config=original;return nil,'error',nil,'parse_error',proof end end
    return table.unpack(results,1,results.n)
   end
   local ran,err=pcall(function()
    helpers.assert_eq(init(manager),false);helpers.assert_eq(calls,1,'frozen old public invocation behavior is retained')
    helpers.assert_eq(config.load_user_config,original);helpers.assert_nil(manager.parser_refusal_token());no_clear(manager)
    local a,b,c,d,e=original({}, {},path);helpers.assert_nil(a);helpers.assert_eq(b,'error');helpers.assert_nil(c);helpers.assert_nil(d);helpers.assert_nil(e)
    local f=assert(io.open(path,'rb'));helpers.assert_eq(f:read('*a'),FUTURE);f:close()
   end)
   hs.timer.absoluteTime=clock;config.load_user_config=original;if not ran then error(err,0)end
  end)
 end)
end)

helpers.describe("independent unused-proof invocation provenance",function()
 helpers.it("clock substitution followed by path restoration cannot lend an earlier genuine unused proof",function()
  with_actual(function(remap,config,logger)
   local reader=config.load_user_config;local paths=require("infra.config_paths")
   local get=paths.get;local _,_,_,_,unused=reader({}, {},get("KarabinerConfigPath"))
   helpers.assert_type(unused,"table")
   local clock,info=hs.timer.absoluteTime,logger.info;local armed=false;local fake_calls,restores=0,0
   local fake=function()fake_calls=fake_calls+1;return nil,"error",nil,"parse_error",unused end
   logger.info=function(log,format,...)
    local results=table.pack(info(log,format,...));local label=select(1,...)
    if format=="init phase '%s': %.1f ms." and label=="compute_non_canonical_combos" then armed=true end
    return table.unpack(results,1,results.n)
   end
   hs.timer.absoluteTime=function(...)
    local results=table.pack(clock(...));if armed then armed=false;config.load_user_config=fake end
    return table.unpack(results,1,results.n)
   end
   paths.get=function(key,...)
    if key=="KarabinerConfigPath" and config.load_user_config==fake then
     config.load_user_config=reader;restores=restores+1
    end
    return get(key,...)
   end
   local ok,err=pcall(function()
    helpers.assert_eq(remap.init({expand_path=function(v)return v end}),false)
    helpers.assert_eq(fake_calls,1,"the captured fake actually executed despite path restoring public reader")
    helpers.assert_eq(restores,1,"path callback restored exactly the real reader before fake ran")
    helpers.assert_eq(config.load_user_config,reader)
    helpers.assert_nil(remap.parser_refusal_token(),"unused genuine proof cannot stand in for the actually invoked reader")
   end)
   paths.get=get;hs.timer.absoluteTime=clock;logger.info=info;config.load_user_config=reader
   if not ok then error(err,0)end
  end)
 end)
end)
return true
