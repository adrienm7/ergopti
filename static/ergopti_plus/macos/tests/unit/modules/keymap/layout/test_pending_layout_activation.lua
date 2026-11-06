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
			read_exact = function(key)
				if state.fail_read then return false, nil end
				return true, state.stored[key]
			end,
			set = function(key, value)
				if not state.no_write then state.stored[key] = value end
				if state.fail_receipt then state.fail_read = true end
				return true
			end,
			delete = function(key) if not state.no_write then state.stored[key] = nil end; return true end,
		},
		is_live = function(name)
			if state.unreadable then return nil, "live_state_unreadable" end
			return state.live[name] == true, nil
		end,
		select = function(id, on_done)
			state.selected[#state.selected + 1] = id
			if state.select_hook then return state.select_hook(id, on_done) end
			if state.defer_selection then state.selection_done = on_done else on_done(true, { id = id }) end
		end,
		encode_json = Json.encode,
		decode_json = Json.decode,
		now = function() return state.now or 1800000000 end,
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

	helpers.it("keeps selection intent until the asynchronous selection succeeds (pending-layout-selection)", function()
		local Pending, state = load({ ["Ergo-L"] = true })
		Pending.record("ergol", "Ergo-L")
		Pending.request_select("ergol")
		state.defer_selection = true
		Pending.resume()
		helpers.assert_not_nil(Pending.pending("ergol"), "the in-flight request remains durable")
		state.selection_done(false, "refused", "selection failed")
		helpers.assert_not_nil(Pending.pending("ergol"), "a failure is retried at the next boot")
		Pending.resume()
		state.selection_done(true)
		helpers.assert_nil(Pending.pending("ergol"))
	end)

	helpers.it("does not erase a newer request when an older selection settles (pending-layout-selection)", function()
		local Pending, state = load({ ["Ergo-L"] = true })
		Pending.record("ergol", "Ergo-L")
		Pending.request_select("ergol")
		state.defer_selection = true
		Pending.resume()
		Pending.resume()
		helpers.assert_eq(#state.selected, 1, "one in-flight selection owns the layout")
		Pending.record("ergol", "Ergo-L")
		state.selection_done(true)
		helpers.assert_not_nil(Pending.pending("ergol"), "the newer request survives the old callback")
	end)

	for _, raises in ipairs({ false, true }) do
	helpers.it("keeps a reentrant selection owner when the first start refuses (pending-layout-reentrant) " .. tostring(raises), function()
		local Pending, state = load({ ["Ergo-L"] = true })
		Pending.record("ergol", "Ergo-L")
		Pending.request_select("ergol")
		state.select_hook = function(_, on_done)
			state.select_hook = function(_, next_done) state.selection_done = next_done; return true end
			on_done(false, "refused")
			Pending.resume()
			if raises then error("first start failed") end
			return false
		end
		Pending.resume()
		Pending.resume()
		helpers.assert_eq(#state.selected, 2, "the second request retains its in-flight owner")
		state.selection_done(true)
		helpers.assert_nil(Pending.pending("ergol"))
	end)
	end

	helpers.it("keeps a layout whose live state cannot be read, and refuses to select an unrecorded one", function()
		local Pending, state = load({})
		Pending.record("composed", "Composer Check")
		state.unreadable = true
		helpers.assert_eq(Pending.resume().unreadable, 1)
		helpers.assert_not_nil(Pending.pending("composed"))
		helpers.assert_eq(Pending.request_select("other"), false)
	end)

	helpers.it("refuses malformed pending entries without changing them (pending-layout-malformed)", function()
		for _, raw in ipairs({
			'{"schema":1,"layouts":{"first":false}}',
			'{"schema":1,"layouts":{"first":{"keyboard_name":5,"select":false,"recorded_at":1}}}',
			'{"schema":1,"layouts":{"first":{"keyboard_name":"First","select":"yes","recorded_at":1}}}',
			'{"schema":1,"layouts":{"first":{"keyboard_name":"First","select":true,"recorded_at":1e100}}}',
			'{"schema":2,"layouts":{}}',
		}) do
			local Pending, state = load({})
			state.stored[Pending.STORAGE_KEY] = raw
			local ok, summary = pcall(Pending.resume)
			helpers.assert_true(ok, "invalid stored data must not crash startup")
			helpers.assert_eq(summary.unreadable, 1)
			helpers.assert_eq(Pending.record("second", "Second"), false)
			helpers.assert_eq(state.stored[Pending.STORAGE_KEY], raw, "unreadable data must remain recoverable")
			helpers.assert_eq(#state.selected, 0)
		end
	end)

	helpers.it("refuses to create malformed pending entries (pending-layout-malformed)", function()
		local Pending, state = load({})
		helpers.assert_eq(Pending.record("", "First"), false)
		helpers.assert_eq(Pending.record("first", ""), false)
		state.now = 1e100
		helpers.assert_eq(Pending.record("first", "First"), false)
		helpers.assert_nil(state.stored[Pending.STORAGE_KEY])
	end)

	helpers.it("does not overwrite pending requests when the stored record is unreadable (pending-layout-read-failure)", function()
		local Pending, state = load({})
		helpers.assert_true(Pending.record("first", "First"))
		local original = state.stored[Pending.STORAGE_KEY]
		state.fail_read = true
		helpers.assert_eq(Pending.record("second", "Second"), false)
		helpers.assert_eq(Pending.request_select("first"), false)
		helpers.assert_eq(Pending.forget("first"), false)
		helpers.assert_eq(Pending.resume().unreadable, 1)
		helpers.assert_eq(state.stored[Pending.STORAGE_KEY], original, "a read failure must not publish an empty record")
		state.fail_read = false
		helpers.assert_not_nil(Pending.pending("first"))
	end)

	helpers.it("rejects a write or delete that did not change the record (pending-layout-write-receipt)", function()
		local Pending, state = load({})
		helpers.assert_true(Pending.record("first", "First"))
		local original = state.stored[Pending.STORAGE_KEY]
		state.no_write = true
		helpers.assert_eq(Pending.record("second", "Second"), false)
		helpers.assert_eq(Pending.request_select("first"), false)
		helpers.assert_eq(Pending.forget("first"), false)
		helpers.assert_eq(state.stored[Pending.STORAGE_KEY], original)
	end)

	helpers.it("does not claim success when the write receipt is unreadable (pending-layout-write-receipt)", function()
		local Pending, state = load({})
		state.fail_receipt = true
		helpers.assert_eq(Pending.record("first", "First"), false)
		state.fail_read = false
		helpers.assert_not_nil(Pending.pending("first"), "the write may have completed despite the unreadable receipt")
	end)

	helpers.it("fences an older selection when a newer write has an unreadable receipt (pending-layout-write-receipt)", function()
		local Pending, state = load({ ["First"] = true })
		helpers.assert_true(Pending.record("first", "First"))
		helpers.assert_true(Pending.request_select("first"))
		state.defer_selection = true
		Pending.resume()
		state.fail_receipt = true
		helpers.assert_eq(Pending.record("first", "New"), false)
		state.fail_read = false
		state.selection_done(true)
		helpers.assert_eq(Pending.pending("first").keyboard_name, "New")
	end)

	helpers.it("re-recording keeps the selection asked for", function()
		local Pending = load({})
		Pending.record("composed", "Composer Check")
		Pending.request_select("composed")
		Pending.record("composed", "Composer Check")
		helpers.assert_eq(Pending.pending("composed").select, true)
	end)
end)
