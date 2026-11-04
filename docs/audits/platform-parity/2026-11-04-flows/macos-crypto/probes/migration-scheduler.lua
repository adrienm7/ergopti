-- Load actual mac cipher + SQL writer using recording ports prepared by sibling probe.
dofile('/workspace/scratch/parity-flows/macos-crypto/probes/cipher-prefix.lua')
local scheduled,commits={},false
_G.hs.timer={new=function(_,callback)
 local timer={callback=callback,live=false,start_result=nil}
 function timer:start() self.start_result=commits;if not commits then return false end;self.live=true;return self end
 function timer:stop() self.live=false;return self end
 function timer:running() return self.live end
 scheduled[#scheduled+1]=timer;return timer
 end,absoluteTime=function() return 1000000000 end}
package.loaded['adapters.timer_scheduler']=nil
local ActualScheduler=require('adapters.timer_scheduler')
local function instance()
 package.loaded['modules.keystats.text_migration']=nil
 local module=require('modules.keystats.text_migration')
 local data={id=1,values={text='ordinary-fixture',events_json='[]'}}
 local updates,cursor=0,nil
 module._set_backend{available=function() return true end,count=function() return 1 end,
  fetch=function(_,after) return after<1 and {data} or {} end,
  apply=function(_,rows) updates=updates+#rows;return true end,
  get_cursor=function() return cursor end,set_cursor=function(c) cursor=c;return true end}
 return module,function() return updates end
end
local denied,writes=instance()
assert(denied.start_for_posture(true)==true)
assert(denied.is_running()==true and writes()==0 and scheduled[#scheduled].start_result==false and scheduled[#scheduled].live==false)
print('timer_refusal: start_reported=true running=true committed_timer=false rewritten_rows=0')
commits=true
local healthy,control_writes=instance()
assert(healthy.start_for_posture(true)==true)
local h=scheduled[#scheduled];assert(h.start_result==true);h.callback()
assert(control_writes()==1 and healthy.is_running()==false)
print('healthy_timer_control: rewritten_rows=1 running=false')
print('Actual mac wrapper/shared runner/cipher/SQL module/TimerScheduler; native hs.timer and data ports recording-only.')
