--- tests/unit/meta/test_wpm_widget_persistence.lua

--- ==============================================================================
--- MODULE: The Widget Comes Back The Way It Was Left
--- DESCRIPTION:
--- That the typing-speed pill\'s two user choices survive a restart, and that
--- something drives its clock.
---
--- THE TWO DEFECTS THIS PINS:
--- Neither choice was stored. A user who turned the widget on found it gone
--- after the next restart, with the menu row unticked and no sign that anything
--- had been forgotten — which reads as a control that does not work rather than
--- one whose answer is not kept. The colour mode reverted the same way.
---
--- And `tick` had no caller anywhere in the driver. The module was complete —
--- it computes the frame, picks the colour from the keystroke source, throttles
--- redraws to what a user could actually see — and nothing ever called it, so
--- the whole surface was inert on every desktop. That is the third module in
--- this driver found finished and unwired, after the preview bubble and the
--- crash reporter.
---
--- WHY ONLY A CHANGE IS STORED:
--- Writing the default too would freeze today\'s default for anyone who had
--- already run the driver: a later change to what ships would reach new installs
--- and nobody else. The metrics toggles and the dynamic-hotstring families are
--- stored the same way for the same reason.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fakes = helpers.load_module("tests.fakes")

-- Restored rather than cleared. A test that reaches into package.loaded owes
-- the files after it the state it found — clearing instead cost a CI run once,
-- when four suppression tests failed on Linux and passed on Windows purely
-- because the two runners return files in a different order.
local _displaced = { storage = nil, widget = nil, held = false }

--- Loads the widget over a fake storage.
--- @param initial table|nil Pre-existing stored values.
--- @param writes_fail boolean|nil Whether mutations fail.
--- @return table widget, table storage
local function load_over_storage(initial, writes_fail)
	if not _displaced.held then
		_displaced.storage = package.loaded["adapters.storage"]
		_displaced.widget = package.loaded["ui.wpm.widget"]
		_displaced.held = true
	end
	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	package.loaded["adapters.storage"] = storage
	package.loaded["ui.wpm.widget"] = nil
	return require("ui.wpm.widget"), storage
end

--- Puts back exactly what was there.
local function drop_storage()
	package.loaded["adapters.storage"] = _displaced.storage
	package.loaded["ui.wpm.widget"] = _displaced.widget
end




-- =================================================================
-- =================================================================
-- ======= 1/ A change is written ==================================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: what gets written", function()

	helpers.it("stores nothing while both switches are at their shipped default", function()
		local widget, storage = load_over_storage()
		widget.restore()
		local written = 0
		for _, key in ipairs(storage.keys()) do
			if key:find("^wpm_widget%.") then written = written + 1 end
		end
		drop_storage()
		helpers.assert_eq(written, 0,
			"persisting the default would freeze today's default for anyone who had "
				.. "already run the driver: a later change to what ships would reach "
				.. "new installs and nobody else")
	end)

	helpers.it("remembers that the user turned it on", function()
		local widget, storage = load_over_storage()
		widget.start()
		local stored = storage.get("wpm_widget.visible")
		widget.stop()
		drop_storage()
		helpers.assert_eq(stored, true,
			"this is the whole complaint: turned on, restarted, gone — with the "
				.. "menu row unticked and nothing saying anything had been forgotten")
	end)

	helpers.it("clears the entry when it is turned off again", function()
		local widget, storage = load_over_storage({ ["wpm_widget.visible"] = true })
		widget.restore()
		widget.stop()
		local has = storage.has("wpm_widget.visible")
		drop_storage()
		helpers.assert_true(not has,
			"back to the default means back to no entry, so the default stays live "
				.. "for this user rather than being pinned at the moment they toggled")
	end)

	helpers.it("remembers the colour mode", function()
		local widget, storage = load_over_storage()
		widget.set_use_source_colors(false)
		local stored = storage.get("wpm_widget.source_colors")
		drop_storage()
		helpers.assert_eq(stored, false,
			"the second of the two choices, and it reverted the same way")
	end)

	helpers.it("keeps the durable visibility and colour state when writes fail", function()
		local widget, storage = load_over_storage({
			["wpm_widget.visible"] = true,
			["wpm_widget.source_colors"] = false,
		}, true)
		helpers.assert_true(widget.restore(), "a durable visible state must restore without rewriting it")
		helpers.assert_eq(widget.stop(), false, "a failed delete must not report a stopped widget")
		helpers.assert_true(widget.is_running(), "the live widget must remain aligned with durable true")
		helpers.assert_eq(widget.set_use_source_colors(true), false)
		helpers.assert_eq(widget.uses_source_colors(), false,
			"failed colour persistence must not publish a session-only mode")
		helpers.assert_eq(storage.get("wpm_widget.visible"), true)
		helpers.assert_eq(storage.get("wpm_widget.source_colors"), false)
		drop_storage()
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ A stored choice is read back =========================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: what gets read", function()

	helpers.it("comes up showing when the user left it showing", function()
		local widget = load_over_storage({ ["wpm_widget.visible"] = true })
		local running = widget.restore()
		local is_running = widget.is_running()
		widget.stop()
		drop_storage()
		helpers.assert_true(running and is_running,
			"the point of storing it: the widget is put back the way it was left, "
				.. "not reset to the shipped default at every start")
	end)

	helpers.it("comes up with the colour mode the user chose", function()
		local widget = load_over_storage({ ["wpm_widget.source_colors"] = false })
		widget.restore()
		local uses = widget.uses_source_colors()
		drop_storage()
		helpers.assert_eq(uses, false)
	end)

	helpers.it("falls back to the shipped default when nothing is stored", function()
		local widget = load_over_storage()
		widget.restore()
		local shipped = widget._defaults()
		local running = widget.is_running()
		local uses = widget.uses_source_colors()
		drop_storage()
		helpers.assert_eq(running, shipped.visible,
			"an install with no stored choice must follow what ships")
		helpers.assert_eq(uses, shipped.source_colors)
	end)

	helpers.it("ignores a stored value that is not a boolean", function()
		local widget = load_over_storage({ ["wpm_widget.visible"] = "true" })
		widget.restore()
		local running = widget.is_running()
		widget.stop()
		drop_storage()
		helpers.assert_eq(running, widget._defaults().visible,
			"a hand-edited store or a foreign writer can leave a string here, and "
				.. "reading it as truthy would turn a setting on that nobody set")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ Something drives its clock ===========================
-- =================================================================
-- =================================================================

helpers.describe("wpm widget: it is ticked", function()

	helpers.it("has a caller for tick in the daemon", function()
		-- The module was complete and nothing called it, so the whole surface was
		-- inert on every desktop. That is the third module in this driver found
		-- finished and unwired, after the preview bubble and the crash reporter —
		-- which is why this is asserted rather than assumed.
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local source = handle:read("*a")
		handle:close()
		helpers.assert_true(source:find("wpm_widget%.tick") ~= nil,
			"a widget nobody ticks draws nothing, and every test of its frame "
				.. "computation passes regardless")
		helpers.assert_true(source:find("wpm_widget%.restore") ~= nil,
			"and one nobody restores comes up hidden however the user left it")
	end)

end)
