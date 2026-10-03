--- tests/unit/platform/remap/test_layout_name_forms.lua

--- ==============================================================================
--- MODULE: Regression — one layout, two names (layout-name-forms)
--- DESCRIPTION:
--- hs.keycodes names the selected layout by its localised name ("Ergopti+"),
--- `defaults read com.apple.HIToolbox AppleSelectedInputSources` by its
--- KeyboardLayout Name ("Ergopti_v2_2_2_plus"). The input-source watcher seeded
--- its baseline with the first and compared the poll's second against it, so
--- every boot of an Ergopti layout reported a layout change at the first poll.
--- That change fenced the boot's Karabiner lease while its RESUME was in flight
--- and opened the error window (« prepared lease RESUME failed:
--- lease-stopping »). Each name is now compared only with a name of its own
--- form, and a bare alphanumeric value, as `defaults` prints ABC, is parsed.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The defaults output for one KeyboardLayout Name, quoted as `defaults`
--- quotes a value that is not purely alphanumeric.
--- @param name string KeyboardLayout Name.
--- @return string stdout
local function selected_sources(name)
	local value = name:match("^%w+$") and name or ('"' .. name .. '"')
	return "(\n        {\n        InputSourceKind = \"Keyboard Layout\";\n"
		.. "        \"KeyboardLayout ID\" = 252;\n"
		.. "        \"KeyboardLayout Name\" = " .. value .. ";\n    }\n)\n"
end

--- Loads the real watcher over native doubles the test drives by hand.
--- @param localised string The localised name hs.keycodes reports at start.
--- @return table h Harness: watchers, changes, and the native drivers.
local function load_watcher(localised)
	local h = { localised = localised, changes = {}, reads = {}, debounces = {} }
	package.loaded["adapters.input_source_broker"] = {
		subscribe = function(_, callback)
			h.notify = callback
			return true
		end,
		unsubscribe = function() return true end,
	}
	package.loaded["adapters.shell_runner"] = {
		spawn = function(_, _, on_done)
			h.reads[#h.reads + 1] = on_done
			return { start = function() return true end, terminate = function() return true end }
		end,
		_active_tasks = {},
	}
	package.loaded["adapters.timer_scheduler"] = {
		after = function(_, callback) return { callback = callback, fired = false }, true end,
		cancel = function() return true end,
	}
	h.watchers = helpers.load_with_stubs("platform.remap.watchers", {
		execute = function() return "", true end,
		keycodes = {
			inputSourceChanged = function() end,
			currentLayout = function() return h.localised end,
			map = { f17 = 64 },
		},
		timer = {
			new = function(_, callback)
				h.poll = callback
				local handle = { live = false }
				function handle:start() self.live = true; return self end
				function handle:stop() self.live = false; return self end
				function handle:running() return self.live end
				return handle
			end,
			doAfter = function(_, callback)
				local timer = { callback = callback }
				function timer:stop() self.stopped = true; return self end
				h.debounces[#h.debounces + 1] = timer
				return timer
			end,
		},
	})
	helpers.assert_true(h.watchers.start_input_source_watcher(function(layout)
		h.changes[#h.changes + 1] = layout
	end))
	--- Completes the newest layout read and runs every due debounce.
	--- @param exit_code integer
	--- @param stdout string
	function h.answer(exit_code, stdout)
		local on_done = h.reads[#h.reads]
		helpers.assert_type(on_done, "function", "a layout read must be in flight")
		on_done(exit_code, stdout, "")
		for _, timer in ipairs(h.debounces) do
			if not timer.ran and not timer.stopped then
				timer.ran = true
				timer.callback()
			end
		end
	end
	--- Runs one poll tick whose read answers with a KeyboardLayout Name.
	--- @param name string
	function h.poll_reads(name)
		h.poll()
		h.answer(0, selected_sources(name))
	end
	return h
end

--- Restores the real adapters for later test files.
local function restore_adapters()
	package.loaded["adapters.shell_runner"] = nil
	package.loaded["adapters.timer_scheduler"] = nil
	package.loaded["adapters.input_source_broker"] = nil
	package.loaded["platform.remap.watchers"] = nil
end





-- =================================================
-- =================================================
-- ======= 1/ Each Name Against Its Own Form =======
-- =================================================
-- =================================================

helpers.describe("karabiner.watchers: one layout, two names (layout-name-forms)", function()
	helpers.it("(layout-name-forms) observing layouts never acquires the CapsWord control owner", function()
		local module_name = "modules.keymap.control_sentinels"
		local previous_loader = package.preload[module_name]
		local acquisitions = 0
		package.preload[module_name] = function()
			acquisitions = acquisitions + 1
			error("layout observation cannot acquire the CapsWord control owner")
		end
		local ok, failure = xpcall(function()
			helpers.with_fresh_modules({ module_name }, function()
				local h = load_watcher("ABC")
				h.poll_reads("ABC")
				helpers.assert_eq(#h.changes, 0)
				helpers.assert_true(h.watchers.stop_input_source_watcher())
			end)
		end, debug.traceback)
		package.preload[module_name] = previous_loader
		restore_adapters()
		if not ok then error(failure, 0) end
		helpers.assert_eq(acquisitions, 0, "the layout owner must not initialize keyboard-control timers")
	end)

	helpers.it("(layout-name-forms) an Ergopti layout's two names are no change at the first poll", function()
		local h = load_watcher("Ergopti+")
		h.poll_reads("Ergopti_v2_2_2_plus")
		helpers.assert_eq(#h.changes, 0,
			"the localised name and the KeyboardLayout Name of one layout are the same layout, got "
				.. table.concat(h.changes, ", "))
		h.poll_reads("Ergopti_v2_2_2_plus")
		helpers.assert_eq(#h.changes, 0, "an unchanged layout stays unchanged")

		h.localised = "French"
		h.poll_reads("French")
		helpers.assert_eq(h.changes[1], "French", "a real switch is still reported")
		helpers.assert_eq(#h.changes, 1)
		restore_adapters()
	end)

	helpers.it("(layout-name-forms) reads a bare alphanumeric KeyboardLayout Name", function()
		local h = load_watcher("ABC")
		h.poll_reads("ABC")
		helpers.assert_eq(#h.changes, 0)
		h.localised = "French"
		h.poll_reads("French")
		helpers.assert_eq(h.changes[1], "French",
			"`defaults` prints ABC and French bare; the poll must still resolve them")
		restore_adapters()
	end)

	helpers.it("(layout-name-forms) a failed notification read compares localised names only", function()
		local h = load_watcher("Ergopti+")
		h.poll_reads("Ergopti_v2_2_2_plus")

		h.notify()
		h.answer(1, "")
		helpers.assert_eq(#h.changes, 0,
			"an unchanged localised name must not be compared with a KeyboardLayout Name")

		h.localised = "ABC"
		h.notify()
		h.answer(1, "")
		helpers.assert_eq(h.changes[1], "ABC", "a localised name that moved is a change")
		h.poll_reads("ABC")
		helpers.assert_eq(#h.changes, 1, "the next poll adopts the name of the change it reported")
		restore_adapters()
	end)

	helpers.it("(layout-name-forms) a localised name that moved before the baseline is a change", function()
		local h = load_watcher("Ergopti+")
		h.localised = "French"
		h.poll_reads("French")
		helpers.assert_eq(h.changes[1], "French",
			"a switch between the seed and the first read must not be adopted silently")
		restore_adapters()
	end)
end)

restore_adapters()
