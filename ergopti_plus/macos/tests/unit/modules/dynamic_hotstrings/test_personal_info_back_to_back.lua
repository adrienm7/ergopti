--- tests/unit/modules/dynamic_hotstrings/test_personal_info_back_to_back.lua

--- Drives the real personal-info interceptor through consecutive user expansions
--- without advancing the timer stub. A fixed re-entry delay used to discard the
--- second physical combo, including after a caught injection failure.

local helpers = require("tests.helpers")

local TARGET  = "modules.dynamic_hotstrings.personal_info"
local TRIGGER = "★"

local function key(char)
	return {
		getFlags = function() return { cmd = false, ctrl = false } end,
		getKeyCode = function() return 0 end,
		getCharacters = function() return char end,
	}
end

local function expand(interceptor, letter)
	interceptor(key("@"), "")
	interceptor(key(letter), "@")
	return interceptor(key(TRIGGER), "@" .. letter)
end

local function boot(outcomes)
	package.loaded[TARGET] = nil
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keylogger"] = {}
	package.loaded["ui.personal_info_editor"] = {}

	local record = { attempts = {}, synthetic = {} }
	package.loaded["adapters.synthetic_input"] = {
		emit_key_stroke = function(modifiers, value, delay)
			record.synthetic[#record.synthetic + 1] = {
				kind = "stroke", modifiers = modifiers, value = value, delay = delay,
			}
			return true
		end,
		emit_key_strokes = function(value)
			record.synthetic[#record.synthetic + 1] = { kind = "strokes", value = value }
			return true
		end,
	}

	local interceptor
	local keymap = {
		get_trigger_char = function() return TRIGGER end,
		register_interceptor = function(callback) interceptor = callback end,
		register_preview_provider = function() end,
		classify_trigger = function() return false, false, false end,
		inject_dynamic = function(deletes, text, emitter, category, is_private)
			local index = #record.attempts + 1
			local attempt = { deletes = deletes, text = text, category = category, is_private = is_private }
			record.attempts[index] = attempt
			if outcomes[index] == "throw" then error("forced personal-info replacement failure") end
			attempt.count, attempt.physical_echo, attempt.logical_text = emitter()
			attempt.emitter_ran = true
			return outcomes[index] == true
		end,
	}

	local PI = helpers.load_with_stubs(TARGET)
	local path = os.tmpname()
	local file = assert(io.open(path, "w"))
	file:write('[info]\nfirst_name = "Alice"\nemail_address = "alice@example.test"\n'
		.. '\n[letters]\np = "first_name"\ne = "email_address"\n')
	file:close()
	PI.start("", keymap, path, function(_, publish) return publish() end)
	PI.enable()
	os.remove(path)

	helpers.assert_type(interceptor, "function",
		"personal_info must register the real interceptor used by the keymap")
	return interceptor, record
end

helpers.describe("personal_info: consecutive expansions have no blind interval", function()
	helpers.it("processes two immediately consecutive combos without advancing timers", function()
		local interceptor, record = boot({ true, true })
		local first = expand(interceptor, "p")
		local second = expand(interceptor, "e")

		helpers.assert_eq(first, "consume")
		helpers.assert_eq(second, "consume",
			"the next physical combo must be accepted immediately, without a timer tick")
		helpers.assert_eq(#record.attempts, 2,
			"both user actions must reach the real module's replacement seam")
		helpers.assert_eq(record.attempts[1].text, "Alice")
		helpers.assert_true(record.attempts[1].emitter_ran)
		helpers.assert_eq(record.attempts[2].text, "alice@example.test")
	end)

	helpers.it("releases replacement ownership synchronously after a caught failure", function()
		local interceptor, record = boot({ "throw", true })
		local failed = expand(interceptor, "p")
		local recovered = expand(interceptor, "e")

		helpers.assert_nil(failed,
			"a failed replacement must pass its physical closing trigger through")
		helpers.assert_eq(recovered, "consume",
			"a caught failure must not block the immediately following personal expansion")
		helpers.assert_eq(#record.attempts, 2)
		helpers.assert_true(record.attempts[2].emitter_ran)
		helpers.assert_eq(record.attempts[2].logical_text, "alice@example.test")
	end)
end)

return true
