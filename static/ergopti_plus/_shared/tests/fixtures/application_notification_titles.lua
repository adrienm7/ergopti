--- _shared/tests/fixtures/application_notification_titles.lua

--- ==============================================================================
--- MODULE: Application Notification Caption Evidence
--- DESCRIPTION:
--- Exercises actual native adapters over recording native boundaries. Expected
--- captions are independent literals; generic port semantics remain separately
--- asserted. The caller supplies the generated policy and test assertions.
--- ==============================================================================

local M = {}




-- =======================================
-- =======================================
-- ======= 1/ Native Caption Evidence ====
-- =======================================
-- =======================================

--- Checks one actual application adapter over scoped native ports.
--- @param assert_eq function Exact test assertion.
--- @param driver string Native host module root.
--- @param compose function Generated shared title composer.
--- @param expected table Independent { default, named, decorated } captions.
--- @param bypass boolean|nil Causal control routes through the original generic port.
function M.run(assert_eq, driver, compose, expected, bypass)
	local names = { "adapters.application_notifier", "adapters.notifier", "application_notifier",
		"window_titles", "adapters.shell_runner", "infra.i18n", "infra.logger", "logger.shim" }
	local previous, previous_hs = {}, _G.hs
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local commands, notes, native_mode = {}, {}, "accept"
	local native_callback
	local logger = { info = function() end, warn = function() end, error = function() end }
	package.loaded["infra.logger"], package.loaded["logger.shim"] = logger, logger
	package.loaded["infra.i18n"] = { get = function(key)
		return key == "common.warning" and "Warning" or "Error"
	end }
	package.loaded["window_titles"] = { compose = compose }
	package.loaded["adapters.shell_runner"] = {
		has_command = function() return native_mode ~= "unavailable" end,
		quote = function(value) return "'" .. tostring(value):gsub("'", "'\\''") .. "'" end,
		run = function(command)
			commands[#commands + 1] = command
			return native_mode ~= "refuse"
		end,
	}
	_G.hs = { notify = { new = function(first, properties)
		if native_mode == "throw" then error("owned native constructor refusal", 0) end
		local options = properties or first
		native_callback = properties and first or nil
		local note = { properties = options, released = 0 }
		note.send = function()
			if native_mode == "refuse" then return false end
			return note
		end
		note.release = function() note.released = note.released + 1 end
		notes[#notes + 1] = note
		return note
	end } }
	package.loaded["adapters.application_notifier"] = nil
	package.loaded["adapters.notifier"] = nil
	local ok, detail = xpcall(function()
		local generic = require("adapters.notifier")
		local application = require("adapters.application_notifier")
		if bypass then application = generic end
		if driver == "macos" then
			assert_eq(generic.send("Literal title", { body = "Literal body" }), true)
			assert_eq(notes[#notes].properties.title, "Literal title")
			assert_eq(application.send(nil, { body = "Native body" }), true)
			assert_eq(notes[#notes].properties.title, expected.default)
			local options = { body = "Native body % ' — 😀", kind = "warn" }
			assert_eq(application.send("Bare label", options), true)
			assert_eq(notes[#notes].properties.title, expected.named)
			assert_eq(notes[#notes].properties.informativeText, options.body)
			assert_eq(notes[#notes].properties.subTitle, "⚠️ Warning")
			assert_eq(notes[#notes].released, 1)
			assert_eq(options.kind, "warn")
			local callback = function() end
			local properties = { title = "Bare label", informativeText = options.body,
				autoWithdraw = true, alwaysPresent = false, withdrawAfter = 5 }
			local note = application.new(callback, properties)
			assert_eq(note, notes[#notes])
			assert_eq(native_callback, callback)
			assert_eq(note.properties.title, expected.named)
			assert_eq(note.properties.informativeText, properties.informativeText)
			assert_eq(note.properties.autoWithdraw, true)
			assert_eq(note.properties.alwaysPresent, false)
			assert_eq(note.properties.withdrawAfter, 5)
			assert_eq(properties.title, "Bare label")
			native_mode = "refuse"
			assert_eq(application.send("Bare label", options), false)
			assert_eq(notes[#notes].released, 1)
			native_mode = "throw"
			assert_eq(application.send("Bare label", options), false)
		else
			assert_eq(generic.send("Literal body", { title = "Literal title", level = "warning" }), true)
			assert_eq(commands[#commands], "notify-send --app-name='Ergopti+' --urgency=normal --expire-time=5000 -- '⚠ Literal title' 'Literal body' >/dev/null 2>&1 &")
			assert_eq(generic.send("Literal body"), true)
			assert_eq(commands[#commands], "notify-send --app-name='Ergopti+' --urgency=low --expire-time=5000 -- 'Ergopti+' 'Literal body' >/dev/null 2>&1 &")
			assert_eq(application.send("Native body"), true)
			assert_eq(commands[#commands], "notify-send --app-name='Ergopti+' --urgency=low --expire-time=5000 -- '" .. expected.default .. "' 'Native body' >/dev/null 2>&1 &")
			local options = { title = "Bare label", level = "warning", onClick = function() end }
			assert_eq(application.send("Native body", options), true)
			assert_eq(commands[#commands], "notify-send --app-name='Ergopti+' --urgency=normal --expire-time=5000 -- '" .. expected.decorated .. "' 'Native body' >/dev/null 2>&1 &")
			assert_eq(options.title, "Bare label")
			assert_eq(options.level, "warning")
			native_mode = "refuse"
			assert_eq(application.send("Native body", options), false)
			local count = #commands
			assert_eq(application.send("", options), false)
			assert_eq(#commands, count)
			package.loaded["adapters.notifier"] = nil
			native_mode = "unavailable"
			assert_eq(application.send("Native body", options), false)
			assert_eq(#commands, count)
		end
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	_G.hs = previous_hs
	if not ok then error(detail, 0) end
end

return M
