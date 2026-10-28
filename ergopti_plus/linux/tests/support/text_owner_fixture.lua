--- tests/support/text_owner_fixture.lua

--- ==============================================================================
--- MODULE: Retained Text Destination Fixture
--- DESCRIPTION:
--- Uses the real focus guard, detector and in-memory application policy with
--- explicitly controlled resident receipts. This fixture makes no native claim.
--- ==============================================================================
local M = {}

--- Runs an isolated real guard against controlled resident focus observations.
--- @param body function Receives guard, state, detector, policy and watch.
function M.with(body)
	local names = { "modules.keystats.focus_guard", "adapters.secure_field_detector", "modules.keystats.keystats" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local guard
	local ok, detail = pcall(function()
		local policy = require("modules.keystats.keystats")
		local detector = require("adapters.secure_field_detector")
		local configuration = assert(policy.configuration_snapshot())
		configuration.private_filter_enabled = false
		assert(policy.apply_configuration(configuration))
		local state = { bus = ":1.23", path = "/field/original", role = 61, now = 1000, barriers = 0, pumps = 0 }
		local listener
		local function snapshot()
			if state.unknown then return nil end
			return { bus = state.bus, path = state.path, role = state.role }
		end
		local watch = {
			on_change = function(fn) listener = fn end,
			pump = function() state.pumps = state.pumps + 1 end,
			barrier = function()
				state.barriers = state.barriers + 1
				if state.on_barrier then state.on_barrier() end
				state.receipt = snapshot()
				listener(state.receipt)
				return state.receipt
			end,
			snapshot = function() return state.receipt end,
			invalidate = function() state.receipt = nil; listener(nil) end,
		}
		guard = require("modules.keystats.focus_guard").new({
			watch = watch, detector = detector, keystats = policy, now_ms = function() return state.now end,
			capture_context = function()
				return { app_id = "owned-editor", title = "Private Browsing", native_identity = "owned-window" }
			end,
			publish_context = function(context)
				return true, policy.is_context_protected(context.app_id, context.title)
			end,
		})
		assert(guard.prime(), "initial context joins its controlled native receipt")
		body(guard, state, detector, policy, watch)
	end)
	if guard then guard.stop() end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(detail, 0) end
end

return M
