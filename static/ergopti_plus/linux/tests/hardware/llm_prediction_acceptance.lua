--- tests/hardware/llm_prediction_acceptance.lua

--- ==============================================================================
--- MODULE: Native Streaming Prediction Acceptance Regression
--- DESCRIPTION:
--- Exercises the production prediction engine, Ollama adapter and curl transport
--- against an owned NDJSON server. Only the privacy and preference input seams
--- are scripted; accepting a partial must retire actual native work and keep the
--- completed stream from resurrecting the offer. Input injection is a recorder.
--- ==============================================================================

local uv = require('luv')
require('compat.utf8').install()
local origin = assert(os.getenv('ERGOPTI_ACCEPT_ORIGIN'))
package.loaded['adapters.secure_field_detector'] = { isSecureField = function() return false end, isUrlBar = function() return false end }
package.loaded['infra.llm_preferences'] = require('tests.support.llm_preferences_fixture').new({initial = {
	['llm.models.selected'] = 'ollama', ['llm.display.streaming'] = true,
}})
package.loaded['modules.llm.profiles'] = {
	init = function() end, is_enabled = function() return true end,
	get_current_model = function() return 'native-model' end, get_base_url = function() return origin end,
}
package.loaded['modules.llm.profile_settings'] = {
	get = function(key) if key == 'num_predictions' then return 1 end end,
	resolve = function() return {id = 'raw', system_single = '{context}'} end,
}
local engine = require('modules.llm.prediction_engine')
local applied, resets, accepted, timeout = 0, 0, false, false
local partial_inflight = false
engine.init({ focus_id = function() return "owned-transport-target" end, engine = {reset = function() resets = resets + 1 end}, apply_prediction = function(candidate)
	assert(candidate.to_type == ' que tout le monde aille bien')
	applied = applied + 1
	return true
end })
engine.predict('Bonjour à tous')
local poll, guard = uv.new_timer(), uv.new_timer()
poll:start(10, 10, function()
	if not accepted and #engine.get_suggestions() > 0 then
		partial_inflight = engine.is_predicting() and require("modules.llm.api_ollama").is_active()
		accepted = engine.accept(1)
		poll:stop(); poll:close()
	end
end)
guard:start(900, 0, function()
	timeout = not accepted
	if not accepted then poll:stop(); poll:close() end
	guard:stop(); guard:close()
end)
uv.run()
assert(not timeout, 'native stream produced an acceptable partial')
assert(partial_inflight, 'acceptance occurred before the real HTTP stream completed')
assert(accepted and applied == 1 and resets == 1, 'one physical commit')
assert(#engine.get_suggestions() == 0, 'late native stream did not resurrect offer')
assert(not engine.is_predicting(), 'accepted native request retired')
assert(not require('modules.llm.api_ollama').is_active(), 'native transport owner retired')
assert(not uv.loop_alive(), 'no retained live native work')
local handles = 0
uv.walk(function() handles = handles + 1 end)
assert(handles == 0, 'no retained native timer, pipe or process handles')
print('PASS native Ollama NDJSON partial accepted once; curl/timers/owner settled; late completion ignored')
