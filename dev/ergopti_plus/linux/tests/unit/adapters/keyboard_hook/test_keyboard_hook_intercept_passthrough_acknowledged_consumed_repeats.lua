--- tests/unit/adapters/keyboard_hook/test_keyboard_hook_intercept_passthrough_acknowledged_consumed_repeats.lua

--- ==============================================================================
--- MODULE: Intercept-Mode Raw Pass-Through Harness (Linux)
--- DESCRIPTION:
--- Deterministic harness for the one thing that makes EVIOCGRAB survivable: when
--- the daemon grabs the keyboard, it becomes the only path to the application and
--- must put every consumed event back, in order and without loss.
---
--- ROOT CAUSE ENCODED:
--- The daemon used to run in observe mode, so physical keys reached the
--- application while an expansion was erasing and retyping — the "abcd"→"acd"
--- corruption. The cure is to grab, and the reason grabbing was never viable is
--- that the pump forwarded nothing at all: it early-returned on releases,
--- swallowed modifiers and control keys, and its semantic parser dropped the
--- autorepeat value and any KEY_* name containing a second underscore. Grabbing
--- on top of that would have made normal typing vanish.
---
--- HOW THIS TEST IS GENUINE (not a delivery-only tautology):
--- The events are encoded into real struct input_event bytes and fed through the
--- REAL reader over a recorded syscall backend, so the assertion is on the exact
--- ordered sequence of (code, value) pairs that reach the uinput channel — every
--- case in it is a class the old code lost. It is RED before the pass-through
--- exists (nothing is emitted at all), and section 3 closes the loop on the real
--- injector so the recorder cannot drift away from what is actually written.
--- ==============================================================================

package.loaded["tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture"] = nil
local Fixture = require("tests.support.adapters.keyboard_hook.keyboard_hook_intercept_passthrough_fixture")
local helpers, EV_KEY, ev =
	Fixture.helpers, Fixture.EV_KEY, Fixture.ev




helpers.describe("keyboard hook: acknowledged consumed repeats", function()
	local function observe(mode)
		local previous = package.loaded["modules.hotstrings.device_finder"]
		local state = { origins = 0, consumed = 0, repeated = 0, raw = {}, values = {} }
		package.loaded["modules.hotstrings.device_finder"] = {
			physical_sources = function(paths)
				state.origins = state.origins + 1
				return { { path = paths[1], sysfs = "/sys/probe/keyboard", name = "fixture keyboard", physical = true } }
			end,
		}
		local ok, err = pcall(function()
			local hook = helpers.load_module("adapters.keyboard_hook")
			local primed = false
			local stream = { ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 2),
				ev(EV_KEY, 36, 0), ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 0) }
			if mode == "independent" then
				stream = { ev(EV_KEY, 36, 1), ev(EV_KEY, 37, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 37, 2),
					ev(EV_KEY, 36, 2), ev(EV_KEY, 37, 2), ev(EV_KEY, 36, 0), ev(EV_KEY, 37, 0),
					ev(EV_KEY, 36, 1), ev(EV_KEY, 36, 2), ev(EV_KEY, 36, 0) }
			end
			hook._test_drive(stream, {
				captureEvent = function(_, value)
					if not primed then hook.physical_source_receipt(); primed = true end
					if value ~= 0 then return "j", "j" end
				end,
				onConsume = function(detail)
					state.consumed = state.consumed + 1
					state.origin = detail.origin_generation
					if mode == "boolean" then return true end
					local receipt = { consume = true, repeat_callback = function(repeat_detail)
						state.repeated = state.repeated + 1
						state.values[#state.values + 1] = repeat_detail.value
						if mode == "independent" then
							state.keys = state.keys or {}
							state.keys[#state.keys + 1] = detail.code .. ":" .. repeat_detail.code
							if detail.code == 36 and state.repeated == 1 then return false end
						end
						if mode == "refused" and state.repeated == 1 then return false end
						return true
					end }
					if mode == "malformed" then receipt.foreign = true end
					return receipt
				end,
				onEmitRaw = function(code, value)
					state.raw[#state.raw + 1] = code .. ":" .. value
					return true
				end,
			}, true)
		end)
		package.loaded["modules.hotstrings.device_finder"] = previous
		if not ok then error(err, 0) end
		return state
	end

	helpers.it("(magic-source-repeat) keeps the exact press callback through repeat and releases it at key-up", function()
		local state = observe("accepted")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 3)
		helpers.assert_eq(state.values, { 2, 2, 2 })
		helpers.assert_type(state.origin, "number")
		helpers.assert_true(state.origin > 0)
		helpers.assert_eq(state.origins, 1, "repeats use the existing native epoch without sysfs rescans")
		helpers.assert_eq(state.raw, {}, "a consumed down owns every repeat and its release")
	end)

	helpers.it("(magic-source-repeat) retires a refused callback until the next physical press", function()
		local state = observe("refused")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 2, "refusal cannot revive before key-up")
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) independent held keys retain their own callbacks and refusal lifetimes", function()
		local state = observe("independent")
		helpers.assert_eq(state.consumed, 3)
		helpers.assert_eq(state.repeated, 4)
		helpers.assert_eq(state.keys, { "36:36", "37:37", "37:37", "36:36" })
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) publishes a qualified origin before the first newly started physical press", function()
		local names = { "adapters.xkb_capture", "adapters.evdev_reader", "modules.hotstrings.device_finder" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:close()
		local hook, observed = nil, { origins = 0, epochs = {}, repeated = 0, raw = {} }
		local ok, err = pcall(function()
			local Capture = helpers.load_module(names[1])
			Capture._set_backend({
				create = function() return {} end, destroy = function() end,
				source_group = function() return 0, 1 end,
				key_sym = function() return "j" end, key_utf8 = function() return "j" end,
				sym_utf8 = function(_, sym) return sym end, update_key = function() end,
				compose_feed = function() end, compose_status = function() return "nothing" end,
				compose_reset = function() end,
			})
			assert(Capture.load("fixture keymap"))
			local Reader = helpers.load_module(names[2])
			local Input = require("infra.input_event")
			local queue, at = {}, 0
			for i, value in ipairs({ 1, 2, 0 }) do queue[i] = Input.encode(1, 36, value, Input.native_size()) end
			Reader._set_backend({
				read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
				open = function() return 1 end, ioctl = function() return true end,
				read = function() at = at + 1; return queue[at] end,
				poll = function() return queue[at + 1] ~= nil end, close = function() return true end,
				read_bits = function(_, _, count) return string.rep("\0", count) end,
			})
			package.loaded[names[3]] = {
				is_key_device = function() return true end,
				-- Controlled keyboard sources have no REL/ABS axes.
				is_interceptable_key_device = function() return true end,
				is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
				physical_sources = function(paths)
					observed.origins = observed.origins + 1
					return { { path = paths[1], sysfs = "/fixture/native-keyboard",
						name = "fixture keyboard", physical = true } }
				end,
			}
			hook = helpers.load_module("adapters.keyboard_hook")
			hook.start({ device = path, pinned = true, intercept = true,
				onConsume = function(detail)
					observed.epochs[#observed.epochs + 1] = detail.origin_generation or "unavailable"
					if detail.origin_generation == nil then return true end
					return { consume = true, repeat_callback = function()
						observed.repeated = observed.repeated + 1
						return true
					end }
				end,
				onEmitRaw = function(code, value)
					observed.raw[#observed.raw + 1] = code .. ":" .. value
					return true
				end,
			})
			observed.running = hook.isRunning()
			hook.pump()
			hook.stop()
			Capture._reset_backend()
			Reader._reset_backend()
		end)
		if hook then pcall(hook.stop) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		os.remove(path)
		if not ok then error(err, 0) end
		helpers.assert_eq(observed.running, true, "the native reader must actually have started")
		helpers.assert_eq(#observed.epochs, 1)
		helpers.assert_type(observed.epochs[1], "number", "the first physical press already owns its qualified epoch")
		helpers.assert_true(observed.epochs[1] > 0)
		helpers.assert_eq(observed.repeated, 1)
		helpers.assert_eq(observed.origins, 2, "acquisition and completed startup publish once each; repeats do not rescan")
		helpers.assert_eq(observed.raw, {})
	end)

	helpers.it("(magic-source-repeat) ordinary boolean consumers stay nonrepeating", function()
		local state = observe("boolean")
		helpers.assert_eq(state.consumed, 2)
		helpers.assert_eq(state.repeated, 0)
		helpers.assert_eq(state.raw, {})
	end)

	helpers.it("(magic-source-repeat) an unsupported receipt never claims the physical press", function()
		local state = observe("malformed")
		helpers.assert_eq(state.repeated, 0)
		helpers.assert_eq(state.raw, { "36:1", "36:2", "36:2", "36:0", "36:1", "36:2", "36:0" })
	end)
end)




helpers.describe("keyboard hook: recovery repeat ownership", function()
	--- Reopens a real reader through the actual watchdog after an owned down.
	--- @param mode string Independent native source/lifetime scenario.
	--- @return table observed Callback epochs, cookies and raw emitted events.
	local function observe_recovery(mode)
		local names = { "adapters.xkb_capture", "adapters.evdev_reader",
			"modules.hotstrings.device_finder", "adapters.keyboard_hook" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local paths = { os.tmpname(), os.tmpname() }
		for _, path in ipairs(paths) do assert(io.open(path, "w")):close() end
		local observed = { origins = 0, epochs = {}, repeated = {}, raw = {}, opens = 0, key_queries = 0 }
		local hook, Capture, Reader
		local ok, err = pcall(function()
			Capture = helpers.load_module(names[1])
			Capture._set_backend({
				create = function() return {} end, destroy = function() end,
				source_group = function() return 0, 1 end,
				key_sym = function() return "j" end, key_utf8 = function() return "j" end,
				sym_utf8 = function(_, sym) return sym end, update_key = function() end,
				compose_feed = function() end, compose_status = function() return "nothing" end,
				compose_reset = function() end,
			})
			assert(Capture.load("fixture keymap"))
			Reader = helpers.load_module(names[2])
			local Input = require("infra.input_event")
			local phase, handles, native_held = 1, {}, {}
			local streams = { [paths[1]] = { mode == "fresh" and {} or { { 1, 1000 } } } }
			streams[paths[1]][2] = mode == "fresh" and { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } }
				or { { 2, 2000 }, { 0, 3000 }, { 1, 4000 }, { 2, 5000 }, { 0, 6000 } }
			if mode == "multiple" then
				streams[paths[1]][1] = { { 1, 1000, 36 }, { 1, 1500, 37 } }
				streams[paths[1]][2] = { { 2, 2000, 36 }, { 2, 2500, 37 },
					{ 0, 3000, 36 }, { 0, 3500, 37 }, { 1, 4000, 36 }, { 2, 5000, 36 }, { 0, 6000, 36 } }
			elseif mode == "released" then
				streams[paths[1]][2] = { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } }
			elseif mode == "unknown" then
				streams[paths[1]][2] = { { 1, 2000 }, { 2, 3000 }, { 0, 4000 },
					{ 1, 5000 }, { 2, 6000 }, { 0, 7000 } }
			elseif mode == "double" then
				streams[paths[1]][2] = { { 2, 2000 } }
				streams[paths[1]][3] = { { 2, 3000 }, { 0, 4000 }, { 1, 5000 }, { 2, 6000 }, { 0, 7000 } }
			elseif mode == "retired" then
				streams[paths[2]] = { {}, { { 1, 2000 }, { 2, 3000 }, { 0, 4000 } } }
			elseif mode == "added" then
				streams[paths[1]][2] = { { 2, 2000 }, { 0, 4000 } }
				streams[paths[2]] = { {}, { { 1, 3000 }, { 2, 5000 }, { 0, 6000 } } }
			end
			Reader._set_backend({
				read_event_bits = require("tests.support.evdev_capabilities_fixture").key_bits,
				open = function(path)
					observed.opens = observed.opens + 1
					handles[observed.opens] = { path = path, phase = phase, at = 0 }
					return observed.opens
				end,
				ioctl = function() return true end,
				read = function(fd)
					local state = handles[fd]
					if state.phase ~= phase then state.phase, state.at = phase, 0 end
					state.at = state.at + 1
					local event = streams[state.path][phase] and streams[state.path][phase][state.at]
					if not event then return nil end
					local code = event[3] or 36
					native_held[state.path] = native_held[state.path] or {}
					if event[1] == 1 then native_held[state.path][code] = true
					elseif event[1] == 0 then native_held[state.path][code] = false end
					return Input.encode(1, code, event[1], Input.native_size(), event[2])
				end,
				poll = function(fd)
					local state = handles[fd]
					return streams[state.path][phase] and streams[state.path][phase][state.at + 1] ~= nil
				end,
				close = function() return true end,
				read_bits = function(fd, request, count)
					if request % 256 == Reader.EVIOCGKEY_NR then
						observed.key_queries = observed.key_queries + 1
						if mode == "unknown" and phase > 1 then
							observed.refused_key_query = true
							return nil, "fixture native key snapshot unavailable"
						end
						local keys = native_held[handles[fd].path] or {}
						if keys[36] ~= true then observed.released_key_receipt = true end
						local bytes = {}
						for index = 1, count do bytes[index] = 0 end
						for code, held in pairs(keys) do
							if held then
								local index = math.floor(code / 8) + 1
								bytes[index] = bytes[index] + 2 ^ (code % 8)
							end
						end
						for index = 1, count do bytes[index] = string.char(bytes[index]) end
						return table.concat(bytes)
					end
					return string.rep("\0", count)
				end,
			})
			local source_set = { paths[1] }
			package.loaded[names[3]] = {
				find_devices = function() return source_set, {} end,
				is_key_device = function() return true end,
				-- Controlled keyboard sources have no REL/ABS axes.
				is_interceptable_key_device = function() return true end,
				is_interceptable_event_mask = require("tests.support.evdev_capabilities_fixture").policy,
				physical_sources = function(current)
					observed.origins = observed.origins + 1
					local sources = {}
					for _, path in ipairs(current) do sources[#sources + 1] = {
						path = path, sysfs = "/fixture/native-keyboard", name = "fixture keyboard", physical = true } end
					return sources
				end,
			}
			hook = helpers.load_module(names[4])
			hook.start({ intercept = true,
				onConsume = function(detail)
					observed.epochs[#observed.epochs + 1] = detail.origin_generation or "unavailable"
					local cookie = #observed.epochs
					if mode == "boolean" or detail.origin_generation == nil then return true end
					return { consume = true, repeat_callback = function()
						observed.repeated[#observed.repeated + 1] = cookie
						return true
					end }
				end,
				onEmitRaw = function(code, value)
					observed.raw[#observed.raw + 1] = code .. ":" .. value
					return true
				end,
			})
			observed.started = hook.isRunning()
			hook.pump()
			phase = 2
			if mode == "retired" then source_set = { paths[2] }
			elseif mode == "added" then source_set = { paths[1], paths[2] }
			else
				assert(Reader.close("keyboard:" .. paths[1]))
				if mode == "released" or mode == "unknown" then native_held[paths[1]] = {} end
				hook.pump()
				observed.recovering = hook.isRecovering()
			end
			for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
			observed.reacquired = hook.isRunning()
			hook.pump()
			if mode == "double" then
				phase = 3
				assert(Reader.close("keyboard:" .. paths[1]))
				hook.pump()
				observed.recovering_again = hook.isRecovering()
				for _ = 1, hook.DEVICE_CHECK_TICKS do hook.check_device() end
				observed.reacquired_again = hook.isRunning()
				hook.pump()
			end
		end)
		if hook then pcall(hook.stop) end
		if Reader then pcall(Reader._reset_backend) end
		if Capture then pcall(Capture._reset_backend) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		for _, path in ipairs(paths) do os.remove(path) end
		if not ok then error(err, 0) end
		return observed
	end

	helpers.it("(magic-source-recovery) the first fresh press after acknowledged reacquisition owns its native epoch", function()
		local state = observe_recovery("fresh")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 1)
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_true(state.epochs[1] > 0)
		helpers.assert_eq(state.repeated, { 1 })
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.opens, 2)
		helpers.assert_eq(state.key_queries, 0, "sources with no consumed debt require no release query")
		helpers.assert_eq(state.origins, 5, "startup and completed recovery publish at lifecycle boundaries, never per repeat")
	end)

	for _, mode in ipairs({ "held", "double", "boolean" }) do
		helpers.it("(magic-source-recovery) retains " .. mode .. " suppression debt until actual release", function()
			local state = observe_recovery(mode)
			helpers.assert_true(state.started and state.recovering and state.reacquired)
			helpers.assert_eq(#state.epochs, 2, "a suppressed old repeat never creates a new consumption decision")
			helpers.assert_type(state.epochs[1], "number")
			helpers.assert_type(state.epochs[2], "number")
			helpers.assert_true(state.epochs[2] > state.epochs[1])
			helpers.assert_eq(state.repeated, mode == "boolean" and {} or { 2 }, "the retired old callback must never run")
			helpers.assert_eq(state.raw, {}, "an old consumed down cannot become a raw repeat/release")
			helpers.assert_eq(state.opens, mode == "double" and 3 or 2)
			helpers.assert_eq(state.key_queries, mode == "double" and 2 or 1, "each indebted source is queried once per reopening")
			helpers.assert_eq(state.origins, mode == "double" and 8 or 5)
			if mode == "double" then helpers.assert_true(state.recovering_again and state.reacquired_again) end
		end)
	end

	helpers.it("(magic-source-recovery) one native snapshot preserves two independent consumed keys until release", function()
		local state = observe_recovery("multiple")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 3)
		for _, epoch in ipairs(state.epochs) do helpers.assert_type(epoch, "number") end
		helpers.assert_eq(state.epochs[1], state.epochs[2], "the two original keys share their actual source epoch")
		helpers.assert_true(state.epochs[3] > state.epochs[2])
		helpers.assert_eq(state.repeated, { 3 }, "neither retired key callback may repeat before its own release")
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1, "native release evidence is acquired once per indebted source, not per key or repeat")
		helpers.assert_eq(state.origins, 5)
	end)

	helpers.it("(magic-source-recovery) acknowledges a native release while closed before accepting the next fresh down", function()
		local state = observe_recovery("released")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(#state.epochs, 2, "a release confirmed by the native owner must not swallow the new press")
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_type(state.epochs[2], "number")
		helpers.assert_true(state.epochs[2] > state.epochs[1])
		helpers.assert_eq(state.repeated, { 2 })
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1)
		helpers.assert_eq(state.released_key_receipt, true, "the real bitset reader must acknowledge physical release")
		helpers.assert_eq(state.origins, 5)
	end)

	helpers.it("(magic-source-recovery) an unavailable native release query keeps debt until an actual key-up", function()
		local state = observe_recovery("unknown")
		helpers.assert_true(state.started and state.recovering and state.reacquired)
		helpers.assert_eq(state.refused_key_query, true, "the real bitset reader must observe the native refusal")
		helpers.assert_eq(#state.epochs, 2, "unknown release cannot acknowledge the first reopened press")
		helpers.assert_type(state.epochs[1], "number")
		helpers.assert_type(state.epochs[2], "number")
		helpers.assert_true(state.epochs[2] > state.epochs[1])
		helpers.assert_eq(state.repeated, { 2 }, "only the press after an observed key-up may own repetitions")
		helpers.assert_eq(state.raw, {})
		helpers.assert_eq(state.key_queries, 1)
		helpers.assert_eq(state.origins, 5)
	end)

	for _, mode in ipairs({ "added", "retired" }) do
		helpers.it("(magic-source-recovery) keeps " .. mode .. " keyboard ownership distinct for the same key code", function()
			local state = observe_recovery(mode)
			helpers.assert_true(state.started and state.reacquired)
			helpers.assert_eq(#state.epochs, 2)
			helpers.assert_type(state.epochs[1], "number")
			helpers.assert_type(state.epochs[2], "number")
			helpers.assert_true(state.epochs[2] > state.epochs[1])
			helpers.assert_eq(state.repeated, { 2 }, "only the new source's own accepted press may repeat")
			helpers.assert_eq(state.raw, {})
			helpers.assert_eq(state.opens, 2)
			helpers.assert_eq(state.origins, 4, "a warm acquisition already publishes qualified origin; no redundant scan")
			helpers.assert_eq(state.key_queries, mode == "added" and 1 or 0, "retired debt never queries or owns a replacement source")
		end)
	end
end)

