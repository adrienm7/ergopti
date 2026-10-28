--- tests/unit/modules/keymap/test_number_row_live.lua

--- ==============================================================================
--- MODULE: Number Row Options, Live (Linux) Tests
--- DESCRIPTION:
--- The choice is stored first and survives a refused application; the layout
--- manager is asked to apply the stored options only where the session loads a
--- layout live and a layout of ours exists; a refusal reaches the caller with its
--- code. Collaborators are fakes: no desktop, no child, no configuration folder.
--- ==============================================================================

local helpers = require("tests.helpers")
local Live = require("modules.keymap.number_row_live")

--- Fakes: stored settings, the layout manager and the session.
local function fakes(options)
	options = options or {}
	local state = { stored = { order = "native", edges = false }, applied = {}, set_calls = {} }
	local deps = {
		session_type = function() return options.session or "x11" end,
		preferences = {
			settings = function() return { order = state.stored.order, edges = state.stored.edges } end,
			set = function(role, value)
				state.set_calls[#state.set_calls + 1] = { role, value }
				if options.store_fails then return false end
				state.stored[role] = value
				return true
			end,
		},
		registry = {
			snapshot = function() return { installed = options.installed or { ergol = {} } } end,
			apply_rows = function(id, rows, on_done)
				state.applied[#state.applied + 1] = { id = id, rows = { order = rows.order, edges = rows.edges } }
				if options.live_fails then
					on_done(false, "live_apply_failed", "not loaded: not_loaded", nil, "not_loaded")
				else
					on_done(true, { id = "ergol", rows = { order = rows.order, reason = "" } })
				end
				return true
			end,
		},
	}
	return deps, state
end

helpers.describe("number row options, live (Linux)", function()
	helpers.it("is available on X11 with an installed layout, with the reason otherwise (number-row-live)", function()
		local deps = fakes()
		helpers.assert_true(Live.available(deps))
		local wayland = fakes({ session = "wayland" })
		local available, reason = Live.available(wayland)
		helpers.assert_eq(available, false)
		helpers.assert_eq(reason, "session_unsupported")
		local empty = fakes({ installed = {} })
		available, reason = Live.available(empty)
		helpers.assert_eq(available, false)
		helpers.assert_eq(reason, "no_source_layout")
	end)

	helpers.it("stores the choice, then applies the stored options (number-row-live)", function()
		local deps, state = fakes()
		state.stored.edges = true
		local result
		helpers.assert_true(Live.set("order", "symbols", function(...) result = { ... } end, deps))
		helpers.assert_eq(state.set_calls[1], { "order", "symbols" })
		helpers.assert_eq(state.applied[1].rows, { order = "symbols", edges = true }, "the stored edge switch travels with the ordering")
		helpers.assert_eq(result[1], true)
		helpers.assert_eq(result[5].order, "symbols")
	end)

	helpers.it("keeps a stored choice the session cannot apply and says why (number-row-live)", function()
		local deps, state = fakes({ session = "wayland" })
		local result
		helpers.assert_true(Live.set("order", "digits", function(...) result = { ... } end, deps), "the choice is stored")
		helpers.assert_eq(state.stored.order, "digits")
		helpers.assert_eq(#state.applied, 0, "no application is attempted")
		helpers.assert_eq(result[1], false)
		helpers.assert_eq(result[2], "session_unsupported")
	end)

	helpers.it("applies nothing when the choice cannot be stored (number-row-live)", function()
		local deps, state = fakes({ store_fails = true })
		helpers.assert_eq(Live.set("order", "digits", nil, deps), false)
		helpers.assert_eq(#state.applied, 0)
	end)

	helpers.it("hands the closed code of a refused load to the caller (number-row-live)", function()
		local deps = fakes({ live_fails = true })
		local result
		Live.apply_stored(function(...) result = { ... } end, deps)
		helpers.assert_eq(result[1], false)
		helpers.assert_eq(result[2], "live_apply_failed")
		helpers.assert_eq(result[4], "not_loaded")
	end)
end)

return true
