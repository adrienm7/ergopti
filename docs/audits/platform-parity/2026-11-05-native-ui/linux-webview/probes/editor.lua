local root = assert(arg[1], 'source root argument required')
local linux = root .. '/static/ergopti_plus/linux'
package.path = linux..'/?.lua;'..linux..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate()
require('compat.utf8').install()
local F = require('tests.support.ui.editors.ui_bridge_handlers_fixture')
require('infra.timings')
-- Existing fixture owns private real files and delegates to the actual canonical writer.
-- Its host is a submission recorder, not an actual GTK/DOM visibility claim.
for _, receipt in ipairs({'healthy','refused','throws'}) do
 F.with_opening_file(function(f)
  assert(f.ready())
  local calls = 0
  f.state.config.reload = function()
   calls = calls + 1
   if receipt == 'throws' then error('synthetic native reload refusal') end
   return 1, receipt == 'healthy'
  end
  local reply = f.save('private edited value')
  assert(f.read():find('private edited value',1,true))
  assert(calls == 1)
  print('RELOAD_RECEIPT mode='..receipt..' saved='..tostring(reply.saved)..' alerts='..#f.seen.alerts..' reload_calls='..calls)
  assert(reply.saved == true and #f.seen.alerts == 0)
 end)
end
F.with_opening_file(function(f)
 assert(f.ready())
 local closes = 0
 f.context.close_owned_window = function() closes=closes+1;return true end
 local reply = f.handler.on_message({action='close',data={}}, f.state, f.context)
 print('CLOSE_RECEIPT close_calls='..closes..' reply='..tostring(reply))
 assert(closes == 0 and reply == nil)
end)
F.with_opening_file(function(f)
 local C = require('modules.hotstrings.hotstrings_config')
 local Choices = require('tests.support.hotstring_choices')
 local directory = assert(f.path:match('^(.*)/personal.toml$'))
 C._set_override_config_dir_for_test(directory)
 Choices.with_file(C, '', function()
  local engine = require('hotstring_engine').new()
  assert(C.init(engine,directory,nil))
  assert(select(2,C.load_all()) == true)
  f.state.config = C
  assert(f.ready())
  local generation = engine:mapping_state().generation
  local foreign = directory..'/malformed.toml'
  local file = assert(io.open(foreign,'wb'));assert(file:write('[broken\n'));assert(file:close())
  local count, reload_receipt = C.reload()
  assert(reload_receipt ~= true)
  local result = f.save('committed while another source is malformed')
  local bytes = f.read()
  assert(bytes:find('committed while another source is malformed',1,true))
  print('ACTUAL_RELOAD_REFUSAL saved='..tostring(result.saved)..' receipt='..tostring(reload_receipt)..' alerts='..#f.seen.alerts)
  assert(result.saved == true and #f.seen.alerts == 0)
  assert(engine:mapping_state().generation == generation)
  print('ACTUAL_ENGINE generation_unchanged=true')
  assert(os.remove(foreign))
 end)
end)
