--- tests/unit/modules/keymap/layout/test_pending_layout_activation.lua

--- ==============================================================================
--- MODULE: Pending Layout Activation Tests
--- DESCRIPTION:
--- macOS 26 lists a layout written to the enabled-sources preference at once but
--- turns it on only at the next login (field probe, L25 and L52). The pending
--- record keeps such a layout until a boot finds it on: it is then forgotten
--- and, when the user asked to use it, selected; a layout still off stays
--- recorded and is logged, never called enabled.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Loads the module with in-memory collaborators.
--- @param live table Keyboard names macOS has turned on.
--- @return table Pending, table state
local function load(live)
	package.loaded["modules.keymap.pending_layout_activation"] = nil
	local Pending = helpers.load_with_stubs("modules.keymap.pending_layout_activation")
	local state = { stored = {}, selected = {}, live = live or {} }
	Pending.init({
		storage = {
			get = function(key, default) local value = state.stored[key]; if value == nil then return default end return value end,
			set = function(key, value) state.stored[key] = value; return true end,
			delete = function(key) state.stored[key] = nil; return true end,
		},
		is_live = function(name)
			if state.unreadable then return nil, "live_state_unreadable" end
			return state.live[name] == true, nil
		end,
		select = function(id, on_done) state.selected[#state.selected + 1] = id; on_done(true, { id = id }) end,
		encode_json = Json.encode,
		decode_json = Json.decode,
		now = function() return 1800000000 end,
		reason = "macos_requires_logout",
	})
	return Pending, state
end

helpers.describe("pending layout activation (composer-macos26)", function()
	helpers.it("refuses a second init and any call before init", function()
		local Pending = load()
		helpers.assert_contains(tostring(helpers.assert_throws(function() Pending.init({}) end)), "called twice")
		Pending._reset()
		helpers.assert_contains(tostring(helpers.assert_throws(function() Pending.record("composed", "X") end)),
			"before init()")
	end)

	helpers.it("keeps a layout still off after the boot, and logs it as pending", function()
		local Pending, state = load({})
		helpers.assert_true(Pending.record("composed", "Composer Check"))
		local summary = Pending.resume()
		helpers.assert_eq(summary.waiting, 1)
		helpers.assert_eq(summary.confirmed, 0)
		helpers.assert_not_nil(Pending.pending("composed"), "it is checked again at the next boot")
		helpers.assert_eq(#state.selected, 0, "a source macOS has not turned on is never selected")
	end)

	helpers.it("forgets a layout macOS turned on and selects it when asked before the login", function()
		local Pending, state = load({ ["Composer Check"] = true })
		Pending.record("composed", "Composer Check")
		helpers.assert_true(Pending.request_select("composed"))
		local summary = Pending.resume()
		helpers.assert_eq(summary.confirmed, 1)
		helpers.assert_nil(Pending.pending("composed"))
		helpers.assert_eq(state.selected[1], "composed")
		helpers.assert_nil(state.stored[Pending.STORAGE_KEY], "an empty record is removed")
	end)

	helpers.it("turns on without selecting a layout nobody asked to use", function()
		local Pending, state = load({ ["Ergo-L"] = true })
		Pending.record("ergol", "Ergo-L")
		Pending.resume()
		helpers.assert_eq(#state.selected, 0)
		helpers.assert_nil(Pending.pending("ergol"))
	end)

	helpers.it("keeps a layout whose live state cannot be read, and refuses to select an unrecorded one", function()
		local Pending, state = load({})
		Pending.record("composed", "Composer Check")
		state.unreadable = true
		helpers.assert_eq(Pending.resume().unreadable, 1)
		helpers.assert_not_nil(Pending.pending("composed"))
		helpers.assert_eq(Pending.request_select("other"), false)
	end)

	helpers.it("re-recording keeps the selection asked for", function()
		local Pending = load({})
		Pending.record("composed", "Composer Check")
		Pending.request_select("composed")
		Pending.record("composed", "Composer Check")
		helpers.assert_eq(Pending.pending("composed").select, true)
	end)
end)
