local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
_G.hs=require('tests.stubs.hs')
local helpers=require('tests.helpers')
package.loaded['adapters.shell_runner']=nil
package.loaded['modules.gestures.conflicts']=nil
local shell=helpers.load_with_stubs('adapters.shell_runner')
local native_new=_G.hs.task.new
local native_tasks,starts={},0
_G.hs.task.new=function(executable,done,...)
 local task=native_new(executable,done,...)
 local original=task.start
 task.start=function(self,...)starts=starts+1;return original(self,...)end
 native_tasks[#native_tasks+1]={task=task,done=done}
 return task
end
local spawn=shell.spawn
local handles={}
shell.spawn=function(...)
 local h=spawn(...);handles[#handles+1]=h;return h
end
local conflicts=require('modules.gestures.conflicts')
local completed=0
assert(conflicts.refresh(function()completed=completed+1 end))
assert(#handles==4 and #native_tasks==4 and starts==0 and completed==0)
for _,h in ipairs(handles) do assert(h.wasStartAttempted()==false and h.isSettled()==false)end
assert(conflicts.slot_system_state('swipe_3_left')=='free')
assert(conflicts.recheck())
assert(#handles==4 and starts==0 and completed==0)
print('REPRO: actual ShellRunner constructs4 preference tasks but none starts; repeated recheck joins pending forever; swipe_3_left remains free')
for _,h in ipairs(handles) do assert(h.start())end
for _,task in ipairs(native_tasks)do task.done(0,'TrackpadThreeFingerHorizSwipeGesture = 2;','')end
assert(starts==4 and completed==1)
assert(conflicts.slot_system_state('swipe_3_left')=='taken')
print('CONTROL: starting the exact retained handles and completing native reads changes same slot to taken')
conflicts.restore_all_overrides()
