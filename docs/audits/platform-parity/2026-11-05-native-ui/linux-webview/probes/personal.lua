local root = assert(arg[1], 'source root argument required')
local linux = root .. '/static/ergopti_plus/linux'
package.path = linux..'/?.lua;'..linux..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate();require('compat.utf8').install();require('infra.timings')
local Shell = require('adapters.shell_runner')
local dir = os.tmpname();assert(os.remove(dir));assert(Shell.run('mkdir -p '..Shell.quote(dir)))
local path = dir..'/personal_info.toml'
local function put(bytes)local f=assert(io.open(path,'wb'));assert(f:write(bytes));assert(f:close())end
local function read()local f=assert(io.open(path,'rb'));local bytes=assert(f:read('*a'));assert(f:close());return bytes end
local original = '[info]\nfirst_name = "SyntheticAda"\n[letters]\np = "first_name"\n'
put(original)
local D = require('modules.dynamic_hotstrings.manager')
local C = require('modules.hotstrings.hotstrings_config')
C._set_override_config_dir_for_test(dir)
local calls, notices, closes, epoch = 0,0,0,5
local host = {current_epoch=function()return epoch end,page_current=function(_,e)return e==epoch end,eval_js=function()calls=calls+1;return true end}
local B = require('ui.personal_info_editor.bridge')
local state = {dyn_hotstrings=D,webview_manager=host,config=C,notify_error=function()notices=notices+1 end}
local context = {app_name='personal_info_editor',epoch=epoch,close_owned_window=function()closes=closes+1;return true end}
local ok,detail = pcall(function()
 require('tests.support.hotstring_choices').with_file(C,'',function()
  assert(C.init(require('hotstring_engine').new(),dir,nil));assert(D.init({personal_info_path=path,trigger_char='*'}))
  assert(B.on_message({action='ready'},state,context).pushed)
  put(original..'# external change\n')
  local result=B.on_message({action='save',values={first_name='RefusedStale'}},state,context)
  assert(result.saved==false and closes==0 and read()==original..'# external change\n')
  print('PERSONAL_STALE refused=true exact_bytes=true notices='..notices)
  assert(B.on_message({action='ready'},state,context).pushed)
  result=B.on_message({action='save',values={foreign='RefusedUnknown'}},state,context)
  assert(result.saved==false and not read():find('RefusedUnknown',1,true))
  print('PERSONAL_UNKNOWN refused=true')
  result=B.on_message({action='save',values={first_name='SyntheticGrace'}},state,context)
  assert(result.saved and result.reloaded and result.closed)
  assert(read():find('SyntheticGrace',1,true) and D.get_info().first_name=='SyntheticGrace')
  print('PERSONAL_HEALTHY saved=true reloaded=true closed=true actual_dynamic_value=true')
  local bytes=read();epoch=6;context.epoch=epoch
  assert(B.on_message({action='ready'},state,context).pushed)
  result=B.on_message({action='cancel'},state,context)
  assert(result.cancelled and result.closed and read()==bytes)
  B.on_window_closed(epoch)
  result=B.on_message({action='save',values={first_name='ClosedPage'}},state,context)
  assert(result.saved==false and read()==bytes)
  print('PERSONAL_CANCEL closed=true no_write=true late_save_refused=true')
 end)
end)
assert(Shell.run('rm -rf '..Shell.quote(dir)))
if not ok then error(detail,0)end
