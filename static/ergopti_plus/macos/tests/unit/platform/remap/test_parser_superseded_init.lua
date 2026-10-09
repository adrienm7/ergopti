--- tests/unit/platform/remap/test_parser_superseded_init.lua

local helpers=require('tests.helpers')
local with_fixture=require('tests.support.remap_transaction_fixture')
helpers.describe('older manager frames cannot act against a newer parser owner',function()
 for _,case in ipairs({{clock='early',newer='malformed'},{clock='user-start',newer='malformed'},{clock='user-tail',newer='malformed'},{clock='user-start',newer='stop'},{clock='user-tail',newer='stop'}})do
  helpers.it(case.clock..' newer '..case.newer..' preserves chronology and original read provenance',function()
   local path=os.tmpname();local file=assert(io.open(path,'wb'));file:write('[karabiner\nintegration_enabled = true\n');file:close()
   local passed,detail=pcall(function()
    with_fixture(function(fixture)
     local manager=fixture.load_enabled_remap({real_user_config_path=path})
     local owner=package.loaded['platform.remap.config'];local logger=package.loaded['infra.logger']
     local reader=owner.load_user_config;local clock=hs.timer.absoluteTime;local loginfo,logerror=logger.info,logger.error
     local inside,won,triggered,ready,read_seen=false,false,false,false,false
     local reads_after_win,inner_reads,outer_errors,user_clocks_after_win=0,0,0,0
     local inner_token
     local hook,mask,count=debug.gethook()
     debug.sethook(function()
      if debug.getinfo(2,'f').func==reader then
       if inside then inner_reads=inner_reads+1 else read_seen=true;if won then reads_after_win=reads_after_win+1 end end
      end
     end,'c')
     logger.info=function(component,format,label,...)
      if not inside and label=='compute_non_canonical_combos' then ready=true end
      return loginfo(component,format,label,...)
     end
     logger.error=function(...)
      if won and not inside then outer_errors=outer_errors+1 end
      return logerror(...)
     end
     hs.timer.absoluteTime=function(...)
      local result=table.pack(clock(...))
      if not inside and ready and won and not read_seen then user_clocks_after_win=user_clocks_after_win+1 end
      local selected=case.clock=='early' or case.clock=='user-start' and ready and not read_seen or case.clock=='user-tail' and read_seen
      if selected and not inside and not triggered then
       triggered=true;inside=true
       if case.newer=='stop' then manager.stop() else helpers.assert_eq(manager.init({expand_path=function(v)return v end}),false)end
       inner_token=manager.parser_refusal_token();inside=false;won=true
      end
      return table.unpack(result,1,result.n)
     end
     local ran,err=pcall(function()
      helpers.assert_eq(manager.init({expand_path=function(v)return v end}),false)
      helpers.assert_eq(triggered,true,'actual captured manager clock reached selected original phase')
      helpers.assert_eq(reads_after_win,0,'superseded outer frame must not enter the actual user reader')
      helpers.assert_eq(outer_errors,0,'superseded outer frame must not call unsafe-config logger against its newer owner')
      if case.clock=='early' then helpers.assert_eq(user_clocks_after_win,0,'pre-read guard prevents entering old timed read')end
      if case.newer=='malformed' then helpers.assert_eq(inner_reads,1);helpers.assert_type(inner_token,'table');helpers.assert_eq(manager.parser_refusal_token(),inner_token)
      else helpers.assert_eq(inner_reads,0);helpers.assert_nil(inner_token);helpers.assert_nil(manager.parser_refusal_token())end
     end)
     hs.timer.absoluteTime=clock;logger.info,logger.error=loginfo,logerror;debug.sethook(hook,mask,count)
     if not ran then error(err,0)end
    end)
   end)
   os.remove(path);if not passed then error(detail,0)end
  end)
 end
end)
return true
