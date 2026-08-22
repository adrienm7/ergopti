--- tests/unit/modules/shortcuts/test_text_clipboard_native_refusals.lua

--- ==============================================================================
--- MODULE: Text actions clipboard native refusals
--- DESCRIPTION:
--- Drives real transform/plain-paste actions with native writers that mutate and
--- then return false. No Cmd+V may follow a refused payload, and a refused exact
--- restore must retain ownership until an autonomous retry succeeds.
--- ==============================================================================

local helpers = require("tests.helpers")


local function load_fixture(options)
	options = options or {}
	for _, name in ipairs({
		"modules.shortcuts.actions.text", "adapters.synthetic_input",
		"adapters.timer_scheduler", "infra.logger",
	}) do package.loaded[name] = nil end
	local original = {
		["public.utf8-plain-text"] = "hello world",
		["public.html"] = "<b>hello world</b>",
	}
	local current = original
	local timers = {}
	local write_calls = 0
	local restore_calls = 0
	local keys = {}
	local selection_reads = 0
	local pasteboard = {
		readAllData = function() return original end,
		getContents = function()
			selection_reads = selection_reads + 1
			local outcome = options.selection_outcomes and options.selection_outcomes[selection_reads]
			if outcome == "throw" then error("injected selection read failure") end
			return "hello world"
		end,
		clearContents = function() current = {} end,
		setContents = function(text)
			write_calls = write_calls + 1
			current = { ["public.utf8-plain-text"] = text }
			local outcome = options.write_outcomes and options.write_outcomes[write_calls]
			if outcome == "false" then return false end
			return true
		end,
		writeAllData = function(snapshot)
			restore_calls = restore_calls + 1
			local outcome = options.restore_outcomes and options.restore_outcomes[restore_calls]
			if outcome == "false" then return false end
			current = snapshot
			return true
		end,
	}
	local synthetic = {
		emit_key_stroke = function(_mods, key)
			keys[#keys + 1] = key
			local outcome = options.key_outcomes and options.key_outcomes[#keys]
			if outcome == "throw" then error("injected key dispatch failure") end
			if outcome == "false" then return false end
			return true
		end,
		emit_key_strokes = function() return true end,
		begin = function() return {} end,
		begin_batch = function() return {} end,
		keyStroke = function() return true end,
		dispatch = function() return true end,
		seal = function() return true end,
		cancel = function() return true end,
	}
	package.loaded["adapters.synthetic_input"] = synthetic
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	local timer_calls = 0
	local text = helpers.load_with_stubs("modules.shortcuts.actions.text", {
		pasteboard = pasteboard,
		timer = {
			new = function(_delay, callback)
				timer_calls = timer_calls + 1
				local outcome = options.timer_outcomes and options.timer_outcomes[timer_calls]
				if outcome == "throw" then error("injected timer allocation failure") end
				if outcome == "nil" then return nil end
				local handle = {
					callback = callback,
					stopped = false,
					running_state = false,
				}
				function handle:start()
					self.running_state = true
					if outcome == "sync" then self.callback() end
					return self
				end
				function handle:stop()
					self.stopped = true
					self.running_state = false
					return self
				end
				function handle:running() return self.running_state end
				timers[#timers + 1] = handle
				return handle
			end,
		},
	})
	return {
		text = text,
		original = original,
		current = function() return current end,
		timers = timers,
		keys = keys,
		restores = function() return restore_calls end,
	}
end


local function count_key(keys, wanted)
	local count = 0
	for _, key in ipairs(keys) do if key == wanted then count = count + 1 end end
	return count
end


helpers.describe("text actions: clipboard refusals fail closed", function()
	helpers.it("transform mutate-then-false restores exact data and posts no Cmd+V", function()
		local f = load_fixture({ write_outcomes = { "false" } })
		f.text.toggle_titlecase()
		f.timers[2].callback() -- timer 1 is the ownership failsafe; timer 2 reads Cmd+C
		helpers.assert_eq(count_key(f.keys, "v"), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("plain paste mutate-then-false restores exact data and posts no Cmd+V", function()
		local f = load_fixture({ write_outcomes = { "false" } })
		helpers.assert_eq(f.text.paste_as_plain_text(), false)
		helpers.assert_eq(count_key(f.keys, "v"), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("plain paste retries a refused all-type restore", function()
		local f = load_fixture({ restore_outcomes = { "false", "success" } })
		helpers.assert_eq(f.text.paste_as_plain_text(), true)
		f.timers[1].callback()
		helpers.assert_eq(count_key(f.keys, "v"), 1)
		f.timers[2].callback()
		helpers.assert_eq(f.restores(), 1)
		helpers.assert_eq(#f.timers, 3)
		f.timers[3].callback()
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("transform refuses Cmd+C when its capture timer cannot be armed", function()
		local f = load_fixture({ timer_outcomes = { "success", "nil" } })
		f.text.toggle_titlecase()
		helpers.assert_eq(count_key(f.keys, "c"), 0)
		helpers.assert_eq(count_key(f.keys, "v"), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("transform restores when Cmd+C dispatch is refused", function()
		local f = load_fixture({ key_outcomes = { "false" } })
		f.text.toggle_titlecase()
		helpers.assert_eq(count_key(f.keys, "c"), 1)
		helpers.assert_eq(count_key(f.keys, "v"), 0)
		helpers.assert_true(f.current() == f.original)
	end)

	helpers.it("a throwing capture callback restores instead of only reaching the global logger", function()
		local f = load_fixture({ selection_outcomes = { "throw" } })
		f.text.toggle_titlecase()
		f.timers[2].callback()
		helpers.assert_eq(count_key(f.keys, "v"), 0)
		helpers.assert_true(f.current() == f.original,
			"transaction-local rollback is still required even though the logger wraps timers")
	end)

	helpers.it("a synchronous retry dispatcher cannot recurse or release ownership", function()
		local f = load_fixture({
			restore_outcomes = { "false" },
			timer_outcomes = { "success", "success", "sync" },
		})
		helpers.assert_eq(f.text.paste_as_plain_text(), true)
		f.timers[1].callback()
		f.timers[2].callback()
		helpers.assert_eq(f.text.paste_as_plain_text(), false,
			"a synchronously-fired retry is not a retained recovery callback")
		helpers.assert_true(f.current() ~= f.original,
			"ownership remains closed until an exact restore actually succeeds")
	end)
end)
