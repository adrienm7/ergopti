local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local path='/workspace/scratch/parity-sequential-2026-11-05/personal-info/linux/probes/private-firstboot.toml';os.remove(path)
local D=require('modules.dynamic_hotstrings.manager');assert(D.init({personal_info_path=path,trigger_char='★'}))
assert(next(D.get_info())==nil and D.capture_info_edit()==nil)
local B=require('ui.personal_info_editor.bridge')
local pushes,notices=0,0
local host={current_epoch=function() return 7 end,page_current=function(_,epoch) return epoch==7 end,eval_js=function() pushes=pushes+1;return true end}
local state={dyn_hotstrings=D,webview_manager=host,i18n={get=function(k) return k end},notify_error=function() notices=notices+1 end,config={reload=function() return 0,true end}}
local context={app_name='personal_info_editor',epoch=7,close_owned_window=function() return true end}
local answer=B.on_message({action='ready'},state,context)
assert(answer.pushed==false and pushes==0 and notices==0)
local saved=B.on_message({action='save',values={first_name='synthetic-name'}},state,context)
assert(saved.saved==false and io.open(path,'rb')==nil)
print('ABSENT_FILE ready_pushed=false init_js=0 initial_notices=0 save=false file_created=false')
local f=assert(io.open(path,'wb'));assert(f:write('[info]\nfirst_name="synthetic-name"\n[letters]\np="first_name"\n'));assert(f:close())
assert(D.init({personal_info_path=path,trigger_char='★'}))
answer=B.on_message({action='ready'},state,context);assert(answer.pushed==true and pushes==1 and #answer.data.fields==1)
print('EXISTING_SOURCE_CONTROL ready_pushed=true fields=1')
B.on_window_closed(7)
local before=notices
saved=B.on_message({action='save',values={first_name='MUST-NOT-WRITE'}},state,context)
assert(saved.saved==false)
assert(D.get_info().first_name=='synthetic-name')
print('CLOSED_EPOCH_CONTROL save=false original_value_preserved=true')
print('PASS actual dynamic source owner and editor bridge; faithful page host receipts, no native page/display')
