--- tests/support/modules/shortcuts/magic_editor/magic_editor_source_owner_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_magic_editor_source_owner
--- DESCRIPTION:
--- Prelude shared by the test_magic_editor_source_owner_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"hs", "infra.logger", "infra.paths", "infra.manifest_reader",
	"adapters.file_system", "adapters.input_source_broker", "adapters.keyboard_source_probe",
	"adapters.hotkey_registrar", "modules.keymap.magic_key_source", "modules.shortcuts.magic_editor",
	"adapters.keyboard_geometry", "shortcuts.magic_editor",
}

local function with_fixture(callback)
	return helpers.with_stub_scope(OWNED_MODULES, function()
		local native = dofile("tests/stubs/hs.lua")
		native.keycodes.map = { a = 0, c = 8, b = 11, j = 38 }
		_G.hs, package.loaded.hs = native, native
		package.loaded["adapters.keyboard_geometry"] = require("tests.support.keyboard_geometry_ports").new(native.eventtap.event.properties)
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = function() return "physical-registry.json" end }
		package.loaded["infra.manifest_reader"] = {
			default_for = function() return "open_hotstrings_editor" end,
		}
		package.loaded["adapters.file_system"] = { read = function()
			return '{"keys":{"KeyA":{"kind":"key","hs":0},"KeyC":{"kind":"key","hs":8},"KeyB":{"kind":"key","hs":11},"KeyJ":{"kind":"key","hs":38},"Backquote":{"kind":"key","hs":50,"macos_iso":{"hs":10}},"IntlBackslash":{"kind":"key","hs":10,"macos_iso":{"hs":50}}}}'
		end }
		local state = {
			source_id = "source.first", trigger = "★", magic_source = "automatic",
			replace_active = false, paused = false, inhibited = false, current = true,
			requests = {}, actions = {}, cancel_refuses = false, projections = {}, remap_types = {},
		}
		package.loaded["modules.keymap.magic_key_source"] = {
			remaps = function(code, _, active, keyboard_type)
				state.remap_types[#state.remap_types + 1] = { code = code, keyboard_type = keyboard_type }
				return (state.remap_code == code or (state.remap_codes or {})[code] == true) and active() == true
			end,
		}
		package.loaded["adapters.input_source_broker"] = {
			subscribe = function(_, observer) state.source_changed = observer; return true end,
			unsubscribe = function() state.source_changed = nil; return true end,
		}
		package.loaded["adapters.keyboard_source_probe"] = {
			current_source_id = function() return state.source_id end,
			request = function(request, observer)
				local retained = { request = request, observer = observer, settled = false }
				retained.operation = {
					cancel = function()
						if state.cancel_refuses and not retained.settled then return false end
						retained.settled = true
						return true
					end,
					is_settled = function() return retained.settled end,
					on_settled = function(observer) retained.on_settled = observer; return true end,
				}
				state.requests[#state.requests + 1] = retained
				return retained.operation
			end,
		}
		local policy = require("shortcuts.magic_editor")
		package.loaded["shortcuts.magic_editor"] = setmetatable({ resolve = function(options)
			state.projections[#state.projections + 1] = options
			return policy.resolve(options)
		end }, { __index = policy })
		local registrar = require("adapters.hotkey_registrar")
		local subject = require("modules.shortcuts.magic_editor")
		local spec = {
			configuration_generation = 1,
			is_action = function(action)
				return action == "open_hotstrings_editor" or action == "script_pause_toggle" or action == "none"
			end,
			is_current = function() return state.current end,
			execute = function(action, binding)
				state.actions[#state.actions + 1] = { action = action, binding = binding }
				return true
			end,
			context = {
				trigger = function() return state.trigger end,
				magic_source = function() return state.magic_source end,
				replace_active = function() return state.replace_active end,
				paused = function() return state.paused end,
				inhibited = function() return state.inhibited end,
			},
		}
		local function respond(index, levels, keyboard_type)
			local retained = state.requests[index or #state.requests]
			retained.settled = true
			if retained.on_settled then retained.on_settled() end
			local selected = {}
			for _, level in ipairs(levels or {
				{ code = 0, text = "a", direct = true, dead = false },
				{ code = 8, text = state.trigger, direct = true, dead = false },
				{ code = 11, text = "b", direct = true, dead = false },
			}) do selected[level.code] = level end
			local ordered = {}
			for _, code in ipairs(retained.request.codes) do
				ordered[#ordered + 1] = selected[code] or { code = code, text = "", direct = false, dead = false }
			end
			retained.observer({
				version = 1, source_id = retained.request.source_id, keyboard_type = keyboard_type or 40,
				levels = ordered,
			})
		end
		callback(subject, registrar, native, state, spec, respond)
	end)
end

return {
	OWNED_MODULES = OWNED_MODULES,
	with_fixture = with_fixture,
}
