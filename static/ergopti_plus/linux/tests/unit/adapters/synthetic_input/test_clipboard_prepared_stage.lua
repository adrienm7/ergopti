--- tests/unit/adapters/synthetic_input/test_clipboard_prepared_stage.lua

--- ==============================================================================
--- MODULE: Prepared Clipboard Lifetime
--- DESCRIPTION:
--- Exercises the real clipboard stage with controlled native command boundaries.
--- A setter may commit after a reentrant close request; only its unwound frame
--- can restore the saved content and acknowledge retirement. No GUI claim.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_stage(body, options)
	options = options or {}
	local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server", "logger.shim",
		"adapters.keyboard_layout" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local s = { value = options.saved or "original", commands = {}, writes = {}, waits = {}, rows = {}, reads = 0,
		lookups = 0, backend_calls = 0, admissions = 0, live = true, inside = false }
	local function boundary(phase)
		if s.boundary then s.boundary(phase) end
	end
	local shell = {}
	function shell.has_command()
		s.backend_calls = s.backend_calls + 1; boundary("backend")
		return not options.unavailable
	end
	function shell.exec_checked()
		s.reads = s.reads + 1; boundary("read")
		if options.read_refused then return false, "", "controlled refusal" end
		return true, s.value
	end
	function shell.with_exact_stdin(_, value)
		boundary("build")
		s.command_count = (s.command_count or 0) + 1
		local command = "prepared-clipboard-command-" .. s.command_count
		s.commands[command] = value
		return command
	end
	function shell.run(command)
		local value = assert(s.commands[command])
		local phase = value == "replacement" and "set" or "restore"
		s.inside = true; boundary(phase)
		-- The physical setter deliberately commits AFTER its callback returns.
		s.value = value; s.writes[#s.writes + 1] = value; s.inside = false
		if s.failure == phase then
			s.failure = nil
			if options.throws then error("controlled native write exception") end
			return false
		end
		return true
	end
	package.loaded["adapters.shell_runner"] = shell
	package.loaded["infra.display_server"] = { is_wayland = function() return false end,
		is_x11 = function() return true end, kind = function() return "x11" end }
	package.loaded["logger.shim"] = helpers.make_logger_stub()
	package.loaded["adapters.keyboard_layout"] = { shortcut_keycode = function()
		s.lookups = s.lookups + 1; error("prepared paste must use the captured key")
	end }
	local ok, detail = xpcall(function()
		local clipboard = helpers.load_module("adapters.clipboard")
		s.channel = { emit = function(code, value)
			boundary("emit")
			s.rows[#s.rows + 1] = { code, value }
			return true
		end }
		s.stage = clipboard.new_paste_stage("replacement", function(ms)
			s.waits[#s.waits + 1] = ms
			boundary(ms == 30 and "settle" or "paste_wait")
			if options.wait_refused then
				if options.throws then error("controlled timer exception") end
				return false
			end
		end, 38, function()
			s.admissions = s.admissions + 1; boundary("admission")
			return s.live
		end)
		body(s)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

helpers.describe("prepared clipboard exact lifetime", function()
	helpers.it("constructs and closes an unused stage without desktop IO or admission", function()
		with_stage(function(s)
			helpers.assert_eq({ s.backend_calls, s.reads, #s.writes, #s.rows, #s.waits, s.admissions }, { 0, 0, 0, 0, 0, 0 })
			helpers.assert_eq(s.stage.close(), true)
			helpers.assert_eq(s.stage.close(), true)
			helpers.assert_eq(s.stage.prepare(), false)
			helpers.assert_eq(s.stage.paste(s.channel), false)
			helpers.assert_eq({ s.backend_calls, s.reads, #s.writes, #s.rows, #s.waits, s.admissions }, { 0, 0, 0, 0, 0, 0 })
		end)
	end)
	for _, saved in ipairs({ "original", "" }) do
		helpers.it("prepares before paste and restores the exact saved bytes length " .. #saved, function()
			with_stage(function(s)
				helpers.assert_eq(s.stage.paste(s.channel), false)
				helpers.assert_eq(s.reads, 0)
				helpers.assert_eq(s.stage.prepare(), true)
				helpers.assert_eq({ s.reads, s.writes, s.waits }, { 1, { "replacement" }, { 30 } })
				helpers.assert_eq(s.stage.prepare(), false, "preparation is one-shot")
				helpers.assert_eq(s.stage.paste(s.channel), true)
				helpers.assert_eq(s.rows, { { 29, 1 }, { 38, 1 }, { 38, 0 }, { 29, 0 } })
				helpers.assert_eq({ s.reads, #s.writes, s.waits, s.lookups }, { 1, 1, { 30, 120 }, 0 })
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.value, saved)
				helpers.assert_eq(s.writes, { "replacement", saved })
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(#s.writes, 2)
			end, { saved = saved })
		end)
	end
	for _, phase in ipairs({ "admission", "backend", "read", "build", "set", "settle" }) do
		helpers.it("defers close until the " .. phase .. " preparation frame unwinds", function()
			with_stage(function(s)
				local calls, admissions_after_close = 0, nil
				s.boundary = function(current)
					if current ~= phase or calls > 0 then return end
					calls = calls + 1
					helpers.assert_eq(s.stage.close(), false, "native preparation still owns its frame")
					admissions_after_close = s.admissions
					helpers.assert_eq(#s.writes, phase == "settle" and 1 or 0, "never restore inside the retiring frame")
				end
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(s.admissions, admissions_after_close, "a known revoked stage must not invoke admission observers again")
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.value, "original", "a setter committing after close must still be compensated")
				helpers.assert_eq(s.rows, {})
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(s.stage.paste(s.channel), false)
				if phase == "set" or phase == "settle" or phase == "build" then
					helpers.assert_eq(s.writes, { "replacement", "original" })
				end
			end)
		end)
	end
	for _, throws in ipairs({ false, true }) do
		helpers.it("restores after a setter commits then " .. (throws and "throws" or "refuses"), function()
			with_stage(function(s)
				s.failure = "set"
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.writes, { "replacement", "original" })
				helpers.assert_eq(s.value, "original")
				helpers.assert_eq(s.rows, {})
			end, { throws = throws })
		end)
		helpers.it("keeps restore debt after an acknowledgement " .. (throws and "throws" or "refuses"), function()
			with_stage(function(s)
				helpers.assert_eq(s.stage.prepare(), true)
				s.failure = "restore"
				helpers.assert_eq(s.stage.close(), false, "changed native bytes alone are not a successful receipt")
				helpers.assert_eq(s.value, "original")
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(s.stage.paste(s.channel), false)
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.writes, { "replacement", "original", "original" })
			end, { throws = throws })
		end)
		helpers.it("restores after the settle wait " .. (throws and "throws" or "refuses"), function()
			with_stage(function(s)
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.value, "original")
				helpers.assert_eq(s.writes, { "replacement", "original" })
			end, { wait_refused = true, throws = throws })
		end)
	end
	helpers.it("a late native setter cannot overwrite restoration after a close request", function()
		with_stage(function(s)
			local close_ack, requests = nil, 0
			s.boundary = function(phase)
				if phase ~= "set" then return end
				requests = requests + 1
				close_ack = s.stage.close()
			end
			helpers.assert_eq(s.stage.prepare(), false)
			helpers.assert_eq(requests, 1)
			helpers.assert_eq(s.value, "original", "restoring inside the setter would let its later commit overwrite the saved clipboard")
			helpers.assert_eq(close_ack, false, "the in-flight setter is not a physical retirement receipt")
			helpers.assert_eq(s.writes, { "replacement", "original" })
			helpers.assert_eq(s.stage.close(), true)
		end)
	end)
	for _, index in ipairs({ 2, 3, 4 }) do
		helpers.it("rechecks revocation after preparation admission " .. index, function()
			with_stage(function(s)
				local checks = 0
				s.boundary = function(phase)
					if phase ~= "admission" then return end
					checks = checks + 1
					if checks == index then helpers.assert_eq(s.stage.close(), false) end
				end
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(checks, index)
				helpers.assert_eq(s.reads, index == 2 and 0 or 1, "revocation before a native read must prevent that read")
				helpers.assert_eq(s.writes, index == 4 and { "replacement", "original" } or {}, "no setter starts after a stale affirmative callback")
				helpers.assert_eq(s.waits, {}, "revocation before the settle boundary prevents its native wait")
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.value, "original")
			end)
		end)
	end
	helpers.it("retains a restoration frame until its physical setter returns", function()
		with_stage(function(s)
			helpers.assert_eq(s.stage.prepare(), true)
			local entered = 0
			s.boundary = function(phase)
				if phase ~= "restore" then return end
				entered = entered + 1
				helpers.assert_eq(s.stage.close(), false)
				helpers.assert_eq(s.value, "replacement", "the physical restore has not committed yet")
			end
			helpers.assert_eq(s.stage.close(), true)
			helpers.assert_eq(entered, 1)
			helpers.assert_eq(s.value, "original")
		end)
	end)
	for _, phase in ipairs({ "emit", "paste_wait" }) do
		helpers.it("does not restore or acknowledge close during the " .. phase .. " paste frame", function()
			with_stage(function(s)
				helpers.assert_eq(s.stage.prepare(), true)
				local entered = 0
				s.boundary = function(current)
					if current ~= phase or entered > 0 then return end
					entered = entered + 1
					helpers.assert_eq(s.stage.close(), false)
					helpers.assert_eq(s.writes, { "replacement" })
					helpers.assert_eq(s.value, "replacement")
				end
				local issued = s.stage.paste(s.channel)
				helpers.assert_eq(entered, 1)
				if phase == "emit" then
					helpers.assert_eq(issued, false)
					helpers.assert_eq(s.rows, { { 29, 1 } }, "revocation after Ctrl DOWN cannot publish V DOWN")
				else
					helpers.assert_eq(issued, true, "the already completed chord keeps its physical delivery receipt")
				end
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.value, "original")
				helpers.assert_eq(s.stage.paste(s.channel), false)
			end)
		end)
	end
	helpers.it("refuses a nested preparation without a second native snapshot", function()
		with_stage(function(s)
			local nested
			s.boundary = function(phase)
				if phase == "read" then nested = s.stage.prepare() end
			end
			helpers.assert_eq(s.stage.prepare(), true)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(s.reads, 1)
			helpers.assert_eq(s.stage.close(), true)
		end)
	end)
	helpers.it("rechecks revocation after the admission callback following Ctrl DOWN", function()
		with_stage(function(s)
			helpers.assert_eq(s.stage.prepare(), true)
			local checks = 0
			s.boundary = function(phase)
				if phase ~= "admission" then return end
				checks = checks + 1
				if checks == 2 then
					helpers.assert_eq(s.stage.close(), false, "the paste frame still owns its native call")
				end
			end
			local issued = s.stage.paste(s.channel)
			helpers.assert_eq(s.rows, { { 29, 1 } }, "an affirmative stale admission cannot publish V after close")
			helpers.assert_eq(issued, false)
			helpers.assert_eq(checks, 2)
			helpers.assert_eq(s.stage.close(), true)
			helpers.assert_eq(s.value, "original")
		end)
	end)
	for _, mode in ipairs({ "unavailable", "read_refused" }) do
		helpers.it("refuses " .. mode .. " before replacing any clipboard bytes", function()
			with_stage(function(s)
				helpers.assert_eq(s.stage.prepare(), false)
				helpers.assert_eq(s.stage.close(), true)
				helpers.assert_eq(s.writes, {})
				helpers.assert_eq(s.rows, {})
				helpers.assert_eq(s.value, "original")
			end, { [mode] = true })
		end)
	end
end)

return helpers
