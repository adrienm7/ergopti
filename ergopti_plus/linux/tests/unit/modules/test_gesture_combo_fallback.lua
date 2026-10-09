--- tests/unit/modules/test_gesture_combo_fallback.lua

--- ==============================================================================
--- MODULE: Gesture Fallback Custody
--- DESCRIPTION:
--- Actual manager, emitter, Writer and broker over acknowledged controlled byte
--- ports. No device descriptor, compositor or physical delivery is qualified.
--- ==============================================================================

local helpers = require("tests.helpers")
local Input = require("infra.input_event")

--- Runs actual owners over controlled byte ports and restores every dependency.
--- @param options table Controlled constructor/wire refusals.
--- @param body function Receives the exact actual-owner environment.
local function with_environment(options, body)
	options = options or {}
	local names = { "logger.shim", "adapters.uinput_writer", "adapters.modifier_broker",
		"adapters.keyboard_hook", "modules.gestures.combo_emitter", "modules.gestures.manager" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	local original_execute = os.execute
	local s = { rows = {}, commands = {}, opens = 0, closes = 0, ioctls = 0, emergency = 0 }
	local ok, err = pcall(function()
		s.writer = helpers.load_module("adapters.uinput_writer")
		local last
		s.writer._set_backend({
			open = function()
				s.opens = s.opens + 1
				if options.during_open then options.during_open(s) end
				return 17
			end,
			ioctl = function()
				s.ioctls = s.ioctls + 1
				return not options.fail_constructor
			end,
			close = function() s.closes = s.closes + 1; return not options.fail_close end,
			write = function(_, bytes)
				local row = assert(Input.decode(bytes))
				if row.type == Input.EV_KEY then
					last = row
					s.rows[#s.rows + 1] = { row.code, row.value }
				elseif options.fail_sync and last and options.fail_sync(last.code, last.value) then return false end
				return true
			end,
		})
		s.broker_factory = helpers.load_module("adapters.modifier_broker")
		s.hook = helpers.load_module("adapters.keyboard_hook")
		local original_stop = s.hook.emergency_stop
		s.hook.emergency_stop = function(reason) s.emergency = s.emergency + 1; return original_stop(reason) end
		s.emitter = helpers.load_module("modules.gestures.combo_emitter")
		s.manager = helpers.load_module("modules.gestures.manager")
		os.execute = function(command) s.commands[#s.commands + 1] = command; return true end
		function s.open()
			assert(s.writer.open())
			s.capability = assert(s.writer.capture_output())
			s.broker = assert(s.broker_factory.attach(s.writer))
		end
		function s.run() return s.manager.execute_action("word_next", "controlled-fallback") end
		body(s)
	end)
	os.execute = original_execute
	if s.capability then pcall(s.writer.close_owned, s.capability)
	elseif s.writer then pcall(s.writer.close) end
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("gesture fallback custody", function()
	helpers.it("allows one X11 fallback only for an actually idle unavailable Writer", function()
		with_environment(nil, function(s)
			helpers.assert_eq(s.writer.unavailable_for_output(), true)
			s.run()
			helpers.assert_eq(s.commands, { "xdotool key ctrl+Right 2>/dev/null &" })
			helpers.assert_eq(s.rows, {})
			helpers.assert_eq(s.opens, 0)
		end)
	end)

	helpers.it("never runs a raw producer after actual native SYN refusal and retained debt", function()
		with_environment({ fail_sync = function(code, value) return code == 106 and value == 1 end }, function(s)
			s.open(); s.run()
			helpers.assert_eq(s.rows, { { 29, 1 }, { 106, 1 } })
			helpers.assert_eq(s.broker.has_debt(), true)
			helpers.assert_eq(s.emergency, 1)
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("a constructor callback cannot mistake the reserved closed channel for unavailable", function()
		with_environment({ during_open = function(s)
			helpers.assert_eq(s.writer.is_open(), false)
			helpers.assert_eq(s.writer.unavailable_for_output(), false)
			s.run()
		end }, function(s)
			helpers.assert_eq(s.writer.open(), true)
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.rows, {})
		end)
	end)

	helpers.it("a refused constructor close retains debt and cannot authorize a raw fallback", function()
		with_environment({ fail_constructor = true, fail_close = true }, function(s)
			helpers.assert_eq(s.writer.open(), false)
			helpers.assert_eq(s.writer.is_open(), false)
			helpers.assert_eq(s.writer.has_output_debt(), true)
			helpers.assert_eq(s.writer.unavailable_for_output(), false)
			s.run()
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.closes, 1, "ambiguous native close is not retried")
		end)
	end)

	helpers.it("an existing broker reservation refuses a second producer before any write", function()
		with_environment(nil, function(s)
			s.open()
			local reservation = assert(s.broker.begin())
			s.run()
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.rows, {})
			helpers.assert_eq(reservation.finish(), true)
		end)
	end)

	helpers.it("keeps a borrowed Ctrl owner after a failed native chord without lifting it or falling back", function()
		with_environment({ fail_sync = function(code, value) return code == 106 and value == 1 end }, function(s)
			s.open()
			helpers.assert_eq(s.broker.edge({}, 29, 1,
				function(code, value) return s.writer.emit(code, value) end).ok, true)
			s.run()
			helpers.assert_eq(s.rows, { { 29, 1 }, { 106, 1 } })
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.broker.has_debt(), true)
		end)
	end)

	helpers.it("retains the public success boolean and does not run another producer after full native completion", function()
		with_environment(nil, function(s)
			s.open()
			local accepted, result = s.emitter.press("ctrl+Right")
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(result.kind, "emitted")
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), false)
			helpers.assert_eq(s.rows, { { 29, 1 }, { 106, 1 }, { 106, 0 }, { 29, 0 } })
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("rejects missing and forged unavailable results from the actual manager boundary", function()
		with_environment(nil, function(s)
			for _, forged in ipairs({ false, "unavailable", { kind = "unavailable" } }) do
				package.loaded["modules.gestures.combo_emitter"] = {
					press = function() return false, forged end,
					can_fallback = s.emitter.can_fallback,
				}
				s.run()
			end
			package.loaded["modules.gestures.combo_emitter"] = { press = function() return false end }
			s.run()
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.opens, 0)
		end)
	end)

	helpers.it("issued unavailable receipts refuse copies edits metatables and replay", function()
		with_environment(nil, function(s)
			local accepted, result = s.emitter.press("ctrl+Right")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(result.kind, "unavailable")
			helpers.assert_eq(s.emitter.can_fallback({ kind = result.kind }, "ctrl+Right"), false)
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), true)
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), false)
			local _, edited = s.emitter.press("ctrl+Right"); edited.kind = "emitted"
			helpers.assert_eq(s.emitter.can_fallback(edited, "ctrl+Right"), false)
			local _, extra = s.emitter.press("ctrl+Right"); extra.allow = true
			helpers.assert_eq(s.emitter.can_fallback(extra, "ctrl+Right"), false)
			local _, meta = s.emitter.press("ctrl+Right"); setmetatable(meta, {})
			helpers.assert_eq(s.emitter.can_fallback(meta, "ctrl+Right"), false)
		end)
	end)

	helpers.it("a native generation acquired and closed after issuance makes the old unavailable receipt stale", function()
		with_environment(nil, function(s)
			local _, result = s.emitter.press("ctrl+Right")
			helpers.assert_eq(s.writer.open(), true)
			s.writer.close()
			helpers.assert_eq(s.writer.is_open(), false)
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), false)
		end)
	end)

	helpers.it("an unavailable receipt cannot authorize a different combo", function()
		with_environment(nil, function(s)
			local _, result = s.emitter.press("ctrl+Right")
			helpers.assert_eq(s.emitter.can_fallback(result, "alt+F4"), false)
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), false)
		end)
	end)

	helpers.it("a missing emitter or raised emitter failure cannot run another producer", function()
		with_environment(nil, function(s)
			package.loaded["modules.gestures.combo_emitter"] = true
			s.run()
			package.loaded["modules.gestures.combo_emitter"] = { press = function() error("controlled emitter failure") end }
			s.manager = helpers.load_module("modules.gestures.manager")
			local accepted = pcall(s.run)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("malformed or raised declared idle observations never create unavailable authority", function()
		with_environment(nil, function(s)
			for _, observe in ipairs({
				function() return "true", 0 end,
				function() return true, "0" end,
				function() return true, math.huge end,
				function() error("controlled observation failure") end,
			}) do
				-- Admit this deliberately malformed controlled source before its
				-- owner is constructed, rather than laundering a later replacement.
				s.writer.unavailable_for_output = observe
				s.emitter = helpers.load_module("modules.gestures.combo_emitter")
				s.manager = helpers.load_module("modules.gestures.manager")
				s.run()
			end
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.opens, 0)
		end)
	end)

	helpers.it("replacing a Writer module or export after issuance invalidates the retained observation", function()
		with_environment(nil, function(s)
			local _, result = s.emitter.press("ctrl+Right")
			local old = s.writer.emit; s.writer.emit = function() return true end
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+Right"), false)
			s.writer.emit = old
			local _, second = s.emitter.press("ctrl+Right")
			package.loaded["adapters.uinput_writer"] = { unavailable_for_output = function() return true, 0 end }
			helpers.assert_eq(s.emitter.can_fallback(second, "ctrl+Right"), false)
			package.loaded["adapters.uinput_writer"] = s.writer
		end)
	end)

	helpers.it("Writer export substitution inside is_open cannot mint a fresh unavailable receipt", function()
		with_environment(nil, function(s)
			local original = s.writer.is_open
			s.writer.is_open = function() s.writer.emit = function() return true end; return false end
			s.run()
			helpers.assert_eq(s.commands, {})
			s.writer.is_open = original
		end)
	end)

	helpers.it("a substituted Writer before a later press is not admitted as a fresh unavailable authority", function()
		with_environment(nil, function(s)
			package.loaded["adapters.uinput_writer"] = {
				emit = function() return true end,
				is_open = function() return false end,
				unavailable_for_output = function() return true, 0 end,
			}
			s.run()
			helpers.assert_eq(s.commands, {})
			helpers.assert_eq(s.opens, 0)
			package.loaded["adapters.uinput_writer"] = s.writer
		end)
	end)

	helpers.it("a substituted broker lookup before a later press cannot mint another-producer authority", function()
		with_environment(nil, function(s)
			local original = s.broker_factory.for_channel
			s.broker_factory.for_channel = function() return nil end
			s.run()
			helpers.assert_eq(s.commands, {})
			s.broker_factory.for_channel = original
		end)
	end)

	helpers.it("substituting the emitter module during its actual press refuses a successor producer", function()
		with_environment(nil, function(s)
			local original = s.emitter.press
			s.emitter.press = function(combo)
				local accepted, result = original(combo)
				package.loaded["modules.gestures.combo_emitter"] = { press = original, can_fallback = s.emitter.can_fallback }
				return accepted, result
			end
			s.manager = helpers.load_module("modules.gestures.manager")
			s.run()
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("an invalid combo is refused and never carries another-producer authority", function()
		with_environment(nil, function(s)
			local accepted, result = s.emitter.press("ctrl+UnknownNativeName")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(result.kind, "refused")
			helpers.assert_eq(s.emitter.can_fallback(result, "ctrl+UnknownNativeName"), false)
			helpers.assert_eq(s.opens, 0)
		end)
	end)
end)

helpers.describe("independent retained emitter authority", function()
	helpers.it("replacement exports after real SYN refusal cannot authorize a raw producer", function()
		with_environment({ fail_sync = function(code, value) return code == 106 and value == 1 end }, function(s)
			s.open()
			local accepted, result = s.emitter.press("ctrl+Right")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(s.rows, { {29, 1}, {106, 1} })
			helpers.assert_eq(s.broker.has_debt(), true)
			s.emitter.press = function() return false, { kind = "unavailable" } end
			s.emitter.can_fallback = function() return true end
			s.run()
			print("INDEPENDENT_FAKE_CERTIFIER rows=" .. #s.rows .. " debt=" .. tostring(s.broker.has_debt()) .. " raw=" .. #s.commands)
			helpers.assert_eq(s.commands, {}, "post-owner certifier replacement cannot mint unavailable custody")
		end)
	end)
end)

helpers.describe("retained manager issuer boundary", function()
	helpers.it("replacing only the admitted press export cannot acquire a new producer", function()
		with_environment(nil, function(s)
			local calls = 0
			s.emitter.press = function() calls = calls + 1; return true end
			s.run()
			helpers.assert_eq(calls, 0, "a later press replacement is never executed")
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("replacing only the admitted certifier before a later press refuses fallback", function()
		with_environment(nil, function(s)
			local calls = 0
			s.emitter.can_fallback = function() calls = calls + 1; return true end
			s.run()
			helpers.assert_eq(calls, 0, "a later certifier replacement is never executed")
			helpers.assert_eq(s.commands, {})
		end)
	end)

	helpers.it("a certifier replaced inside the admitted press cannot run at the fallback boundary", function()
		with_environment(nil, function(s)
			local original = s.emitter.press
			local calls = 0
			s.emitter.press = function(combo)
				local accepted, result = original(combo)
				s.emitter.can_fallback = function() calls = calls + 1; return true end
				return accepted, result
			end
			s.manager = helpers.load_module("modules.gestures.manager")
			s.run()
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(s.commands, {})
		end)
	end)
end)
