-- Supplemental root countercheck. Original audit/probe artifacts remain immutable.
local root=assert(arg[1],'source root required')
local linux=root..'/static/ergopti_plus/linux'
package.path=linux..'/?.lua;'..linux..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate();require('compat.utf8').install();require('infra.timings')
local F=require('tests.support.ui.editors.ui_bridge_handlers_fixture')
local Logger=require('logger')
local Dialog=require('ui.error_dialog.bridge')
assert(require('logger.shim')==Logger)
assert(Dialog.init() and Dialog.is_enabled()==true,'Actual default error-window setting must be enabled')
local deferred,observed={},{}
Dialog.defer=function(fn,delay)deferred[#deferred+1]={callback=fn,delay=delay};return true end
Logger.set_error_observer(function(module,template,message)
 observed[#observed+1]={module=module,template=template,message=message}
 return Dialog.on_error(module,template,message)
end)
F.with_opening_file(function(f)
 local C=require('modules.hotstrings.hotstrings_config')
 local directory=assert(f.path:match('^(.*)/personal.toml$'))
 C._set_override_config_dir_for_test(directory)
 require('tests.support.hotstring_choices').with_file(C,'',function()
  local engine=require('hotstring_engine').new()
  assert(C.init(engine,directory,nil));assert(select(2,C.load_all())==true)
  f.state.config=C;assert(f.ready())
  local generation=engine:mapping_state().generation
  local foreign=directory..'/malformed.toml'
  local file=assert(io.open(foreign,'wb'));assert(file:write('[broken\n'));assert(file:close())
  local result=f.save('countercheck physically saved value')
  assert(result.saved==true and f.read():find('countercheck physically saved value',1,true))
  assert(engine:mapping_state().generation==generation)
  local reload_errors=0
  for _,error_record in ipairs(observed)do
   print('OBSERVED_ERROR module='..error_record.module..' template='..error_record.template)
   if error_record.template:find('Catalogue reload refused',1,true)then reload_errors=reload_errors+1 end
  end
  local native_attempts=0
  for _,request in ipairs(deferred)do if request.delay==250 then native_attempts=native_attempts+1 end end
  print('COUNTERCHECK saved=true exact_bytes_committed=true engine_unchanged=true explicit_editor_alerts='..#f.seen.alerts..' reload_error_observed='..reload_errors..' default_error_window_requests='..native_attempts)
  assert(reload_errors==1 and native_attempts==1 and #f.seen.alerts==0)
  -- Deferred callbacks are intentionally not executed: no GTK/desktop/notification.
  assert(os.remove(foreign))
 end)
end)
Logger.set_error_observer(nil)
Dialog._reset()
print('COUNTERCHECK native_visibility=unmeasured actual_logger_and_policy=true')
