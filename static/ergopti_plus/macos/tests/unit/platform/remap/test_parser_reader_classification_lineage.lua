--- tests/unit/platform/remap/test_parser_reader_classification_lineage.lua

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
   local ran,detail=pcall(body,remap,config,package.loaded['infra.logger'])
   paths.get=get
   if not ran then error(detail,0) end
  end)
 end)
 os.remove(path);os.remove(path..'.tmp');if not ok then error(err,0) end
end
helpers.describe('genuine public parser classification lineage',function()
 helpers.it('actual decoder refusal establishes the decisive positive control',function()
  with_actual(function(remap,config)
   local value,status,source,failure=config.load_user_config({}, {}, require('infra.config_paths').get('KarabinerConfigPath'))
   helpers.assert_nil(value);helpers.assert_eq(status,'error');helpers.assert_nil(source);helpers.assert_eq(failure,'parse_error')
   helpers.assert_eq(remap.init({expand_path=function(v)return v end}),false)
   helpers.assert_type(remap.parser_refusal_token(),'table')
  end)
 end)
 for _,boundary in ipairs({'pre-init','logger-start','clock'}) do
  helpers.it('substituted actual Config reader at '..boundary..' cannot mint a parser token',function()
   with_actual(function(remap,config,logger)
    local original=config.load_user_config;local calls=0
    local function replace() config.load_user_config=function() calls=calls+1;return nil,'error',nil,'parse_error' end end
    local port,name
    if boundary=='pre-init' then replace()
    else
     port,name=boundary=='logger-start' and logger or hs.timer,boundary=='logger-start' and 'start' or 'absoluteTime'
     local foreign,armed=port[name],true
     port[name]=function(...)local results=table.pack(foreign(...));if armed then armed=false;replace()end;return table.unpack(results,1,results.n)end
     local ok,err=pcall(function()
      helpers.assert_eq(remap.init({expand_path=function(v)return v end}),false)
      helpers.assert_eq(calls,1,'the actual substituted reader was reached')
      helpers.assert_nil(remap.parser_refusal_token(),'a public fourth string has no actual decoder lineage')
     end)
     port[name]=foreign;config.load_user_config=original
     if not ok then error(err,0)end;return
    end
    local ok,err=pcall(function()
     helpers.assert_eq(remap.init({expand_path=function(v)return v end}),false)
     helpers.assert_eq(calls,1,'the actual substituted reader was reached')
     helpers.assert_nil(remap.parser_refusal_token(),'a public fourth string has no actual decoder lineage')
    end)
    config.load_user_config=original;if not ok then error(err,0)end
   end)
  end)
 end
end)
return true
