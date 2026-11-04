local root='/workspace/ergopti/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
if not utf8 then require('compat.utf8').install() end
local helpers=require('tests.helpers')
local Gestures=helpers.load_module('modules.gestures.manager')
local shell=require('adapters.shell_runner')
local original_execute=os.execute
local state
shell.has_command=function() return true end
shell.exec_checked=function(command)
 state.reads=state.reads+1
 if command:find('text/uri-list',1,true) then
  if state.uri then return true,state.uri end
  return false,''
 end
 return true,state.clipboard
end
shell.with_exact_stdin=function(command,text) state.pending=text;return command end
shell.run=function() state.clipboard=state.pending;state.writes=state.writes+1;return true end
package.loaded['infra.display_server']={is_x11=function() return true end,is_wayland=function() return false end,kind=function() return 'x11' end,UNKNOWN='unknown'}
package.loaded['adapters.clipboard']=nil
package.loaded['modules.gestures.combo_emitter']={press=function(combo,publication)
 state.emits[#state.emits+1]={combo=combo,app=state.app,publication=publication}
 if state.no_emitter then return false end
 if state.app=='nautilus' then state.uri='file:///tmp/ergopti-fixture-only.sh\r\n' end
 return true
end}
package.loaded['adapters.event_loop']={sleep_ms=function() return true end}
package.loaded['adapters.application_notifier']={send=function() state.notices=state.notices+1;return true end}
os.execute=function(command) state.commands[#state.commands+1]=command;return true,'exit',0 end
local function run(app,writer,no_emitter)
 state={app=app,clipboard='saved',reads=0,writes=0,emits={},commands={},notices=0,no_emitter=no_emitter}
 if not writer then shell.has_command=function() return false end else shell.has_command=function() return true end end
 local result=Gestures.execute_action('make_executable_selection','keyboard__ctrl_alt_e')
 assert(result==true)
 if not writer then
  assert(#state.emits==0 and #state.commands==0 and state.writes==0)
 elseif no_emitter then
  assert(#state.emits==1 and #state.commands==0 and state.clipboard=='saved' and state.writes==2)
 elseif app=='terminal' then
  assert(#state.emits==1 and state.emits[1].combo=='ctrl+c' and state.emits[1].app=='terminal' and state.emits[1].publication==nil)
  assert(#state.commands==0 and state.clipboard=='saved' and state.notices==1)
 else
  assert(#state.emits==1 and #state.commands==1 and state.commands[1]:find('chmod +x',1,true))
  assert(state.clipboard=='saved')
 end
 print('CALLER',app,'clipboard_provider='..tostring(writer),'emitter_refused='..tostring(no_emitter==true),'result='..tostring(result),'ctrlc='..#state.emits,'commands='..#state.commands,'writes='..state.writes,'notices='..state.notices)
end
run('terminal',true)
run('nautilus',true)
run('terminal',false)
run('terminal',true,true)
os.execute=original_execute
