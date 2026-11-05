-- Actual Reader/Hook/Manager/Engine/Writer over original recorded native ports.
local root=assert(arg[1]);local here=assert(arg[0]:match('^(.*)/[^/]+$'))
local file=assert(io.open(here..'/public-probe.lua','rb'));local source=file:read('*a');file:close()
local stop=assert(source:find('local observations={}',1,true))
local Capture=assert((loadstring or load)(source:sub(1,stop-1)..'\nreturn Capture','@qualified-native-layout-port'))()
local Fixture=require('tests.support.input_owner_fixture')
local observations={}
local function run(name,stream)
 require('logger.shim').set_sink(nil)
 assert(Capture.load('keymap','C'))
 local chars,logs={},{}
 local options={capture=Capture,on_char=function(ch)chars[#chars+1]=ch end}
 Fixture.with_manager_session(options,function(s)
  local logger=require('logger.shim');logger.set_level('trace');logger.set_sink(function(line,variant)if variant=='error' or variant=='warn'then logs[#logs+1]=line end end)
  for _,e in ipairs(stream)do s.edge('a',e[1],e[2],e[3])end
  observations[#observations+1]={name=name,chars=chars,wire=s.rows,logs=logs,hook_running=s.hook.isRunning(),broker_debt=s.broker.has_debt(),output_current=s.writer.output_view(s.output)~=nil,reader_closes=s.source_closes or 0,output_closes=s.output_closes or 0,output_destroys=s.output_destroys or 0}
 end)
 require('logger.shim').set_sink(nil)
end
run('repeat-real-channel',{{97,1,1000},{97,0,1100},{30,1,1200},{30,2,1210},{30,0,1220},{30,1,1300},{30,0,1310}})
run('no-repeat-real-channel',{{97,1,1000},{97,0,1100},{30,1,1200},{30,0,1220},{30,1,1300},{30,0,1310}})
for _,mode in ipairs({'pause-resume','reload','stop'})do
 require('logger.shim').set_sink(nil);assert(Capture.load('keymap','C'))
 local chars={}
 Fixture.with_manager_session({capture=Capture,on_char=function(ch)chars[#chars+1]=ch end},function(s)
  s.edge('a',97,1,1000);s.edge('a',97,0,1100)
  local old=s.manager.configuration_snapshot().engine
  assert(old.one_shot_until~=nil,'ordinary tap must arm before '..mode)
  if mode=='pause-resume'then assert(s.manager.set_paused(true));assert(old.one_shot_until==nil);assert(s.manager.set_paused(false))
  elseif mode=='reload'then assert(s.manager.reload());assert(old.one_shot_until==nil);assert(s.manager.configuration_snapshot().engine~=old)
  else s.hook.stop();assert(old.one_shot_until==nil);assert(not s.hook.isRunning())end
  if mode~='stop'then s.edge('a',30,1,1200);s.edge('a',30,0,1210);assert(#chars==1 and chars[1]=='a');assert(s.hook.isRunning() and not s.broker.has_debt())end
  observations[#observations+1]={name=mode,chars=chars,old_arm_cleared=old.one_shot_until==nil,hook_running=s.hook.isRunning(),broker_debt=s.broker.has_debt(),wire=s.rows}
 end)
end
local bad,good=observations[1],observations[2];assert(bad.hook_running==false and bad.broker_debt and not bad.output_current and #bad.chars==1 and bad.chars[1]=='A');assert(good.hook_running and not good.broker_debt and good.output_current and #good.chars==2 and good.chars[1]=='A' and good.chars[2]=='a');assert(bad.reader_closes>0 and bad.output_closes>0 and bad.output_destroys>0)
print('ONE_SHOT_CHANNEL='..assert(require('json').encode({qualification='Actual original Reader/Hook/Manager/Engine/broker/Writer; fixture supplies FFI/syscall/XKB ports and declaration-unavailable source marker. Physical standalone RCtrl tap path, not legacy logical pair admission. No real evdev/uinput/application receiving.',observations=observations})))
