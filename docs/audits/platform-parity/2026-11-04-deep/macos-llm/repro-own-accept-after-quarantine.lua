local root = '/workspace/ergopti/static/ergopti_plus/'
package.path = root..'macos/?.lua;'..root..'macos/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..root..'macos/tests/stubs/?.lua;'..package.path
local Fixture = require('tests.support.apply_prediction_fixture')
for _, scenario in ipairs({'control', 'reset_refused', 'quarantine_during_reset'}) do
  local calls = 0
  local options = { prediction = { to_type = 'agent calendar action', on_accept = function() calls=calls+1; return true end } }
  if scenario == 'reset_refused' then options.reset_result = false end
  if scenario == 'quarantine_during_reset' then
    options.reset_result = function()
      require('modules.keymap.llm_bridge').set_runtime_quarantined(true)
      return true
    end
  end
  local result = Fixture.run(options)
  print(string.format('%s: call_ok=%s applied=%s callback_calls=%d runtime_available=%s reset_count=%d',
    scenario, tostring(result.call_ok), tostring(result.applied), calls,
    tostring(require('modules.keymap.llm_bridge').is_runtime_available()), result.reset_count))
  assert(result.call_ok == true, tostring(result.applied))
  assert(calls == 1, 'current defect changed; re-evaluate finding')
  assert(result.applied == true)
end
