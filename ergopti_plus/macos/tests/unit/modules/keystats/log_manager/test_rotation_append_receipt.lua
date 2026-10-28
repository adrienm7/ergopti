--- tests/unit/modules/keystats/log_manager/test_rotation_append_receipt.lua

--- ==============================================================================
--- MODULE: Journal Append Receipt Tests
--- DESCRIPTION:
--- Actual append/update streams preserve a refused write's exact physical prefix.
--- The FILE proxy injects the documented nil/error receipt after writing real
--- bytes; actual native EFBIG controls are retained separately from this portable
--- boundary fixture. A retry must finish one owned row without replaying it.
--- ==============================================================================

local helpers = require("tests.helpers")
local CommandLines = require("tests.support.command_lines")
local shell_quote = require("text_utils").shell_quote
local TIMESTAMP = "2026-10-26 00:00:00.000"

--- Exercise one refused append against an actual unbuffered stream.
--- @param count function Select the number of real bytes written before refusal.
--- @param check function Inspect the pending writer and recover its exact entry.
local function with_receipt(count, check, options)
	options = options or {}
	helpers.with_stub_scope({ "modules.keystats.rotation", "adapters.ledger_append", "infra.logger" }, function()
		local path, original_open = os.tmpname(), io.open
		local prefix = '{"type":"typing","timestamp":"' .. TIMESTAMP .. '","text":"prior"}\n'
		if options.unterminated_prefix then prefix = prefix:sub(1, -2) end
		local seed = assert(original_open(path, "w")); assert(seed:write(prefix)); assert(seed:close())
		local handles, opens, closes, owner_calls = {}, 0, 0, 0
		local failures = options.failures or 1
		local controls = { read_bytes = 0, reads = 0, writes = 0, anchor = #prefix }
		function controls.rewrite(offset, bytes)
			local file = assert(original_open(path, "r+"))
			assert(file:seek("set", offset)); assert(file:write(bytes)); assert(file:close())
		end
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.ledger_append"] = { rollover = function(_, _, _, _, date, reset)
			owner_calls = owner_calls + 1
			return reset(date, {})
		end }
		local rotation = helpers.load_with_stubs("modules.keystats.rotation")
		io.open = function(filename, mode)
			local file, reason, code = original_open(filename, mode)
			if not file or filename ~= path or mode ~= "a+" then return file, reason, code end
			opens = opens + 1; handles[#handles + 1] = file
			return {
				setvbuf = function(_, ...) return file:setvbuf(...) end,
				seek = function(_, ...)
					if controls.seek_refusal then controls.seek_refusal = false; return nil, "injected seek refusal" end
					return file:seek(...)
				end,
				read = function(_, amount)
					controls.reads = controls.reads + 1
					if type(amount) == "number" then controls.read_bytes = controls.read_bytes + amount end
					if controls.read_refusal then controls.read_refusal = false; return nil, "injected read refusal" end
					return file:read(amount)
				end,
				close = function() closes = closes + 1; return file:close() end,
				write = function(_, bytes)
					controls.writes = controls.writes + 1
					if failures > 0 then
						failures = failures - 1
						local written = count(bytes)
						controls.refused_prefix_bytes = written
						if written > 0 then assert(file:write(bytes:sub(1, written))) end
						return nil, "injected receipt after physical prefix", 28
					end
					local accepted, detail, number = file:write(bytes)
					return accepted and true or nil, detail, number
				end,
			}
		end
		local entry = { type = "typing", timestamp = TIMESTAMP, text = options.text or "owned_once" }
		if options.reentry then
			controls.reentrant_results = {}
			package.loaded["infra.logger"].error = function()
				controls.reentrant_results[#controls.reentrant_results + 1] = rotation.append_log(entry)
				local _, _, status = rotation.read_new_entries()
				helpers.assert_eq(status, rotation.READ_STATUS_FAILED)
			end
		end
		local ok, reason = xpcall(function()
			rotation.init({ paths = { today_log_path = path }, state = {}, recovery_turn_bytes = options.recovery_turn_bytes or 65536 })
			helpers.assert_eq(rotation.append_log(entry), false, "the first native-style refusal must retain ownership")
			check(rotation, entry, function() return opens, closes, owner_calls end, controls)
			local file = assert(original_open(path, "r")); local bytes = assert(file:read("*a")); assert(file:close())
			helpers.assert_eq(bytes:sub(1, #prefix), prefix, "recovery must preserve all pre-existing bytes")
			local separator = options.unterminated_prefix and "\n" or ""
			local expected = prefix .. separator .. hs.json.encode(entry):gsub("\n", "") .. "\n"
			helpers.assert_eq(bytes, expected, "one accepted event must produce exactly one physical row")
			helpers.assert_eq(opens, 1, "recovery must retain the original append stream")
			helpers.assert_eq(closes, 0, "an unresolved append must not close its original stream")
			local rows, _, status = rotation.read_new_entries()
			helpers.assert_eq(status, rotation.READ_STATUS_EOF)
			helpers.assert_eq(#rows, 2, "the prior row and the single recovered row must be ingestible")
		end, debug.traceback)
		io.open = original_open
		for _, file in ipairs(handles) do if io.type(file) == "file" then assert(file:close()) end end
		assert(os.remove(path))
		if not ok then error(reason, 0) end
	end)
end

helpers.describe("rotation exact refused append receipt", function()
	helpers.it("(journal-append-receipt) preserves one public event and its exact SQLite duration through a refused retry", function()
		local root = helpers.driver_root() .. "../../.."
		local command = "python3 " .. shell_quote(root .. "/tools/diagnostics/hs274_journal_append_test.py")
			.. " JournalAppendReceiptTests.test_portable_public_retry_counts_one_event_and_duration 2>&1"
		local lines = CommandLines.read(command)
		helpers.assert_true(table.concat(lines, "\n"):find("Ran 1 test", 1, true) ~= nil,
			"the exact portable public-chain regression must run, not merely import its fixture")
	end)
	for _, cut in ipairs({ "zero", "partial", "before_lf", "complete" }) do
		helpers.it("(journal-append-receipt) resumes only the missing suffix after " .. cut, function()
			with_receipt(function(bytes)
				if cut == "zero" then return 0 end
				if cut == "partial" then return math.floor(#bytes / 2) end
				return cut == "before_lf" and #bytes - 1 or #bytes
			end, function(rotation, entry)
				helpers.assert_eq(rotation.append_log(entry), true, "the exact retained entry must settle after storage recovers")
			end)
		end)
	end
		helpers.it("(journal-append-receipt) fences tail ingestion and rollover until the owned row settles", function()
			with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, facts)
				local rows, offset, status = rotation.read_new_entries()
				helpers.assert_eq(rows, {}, "a complete unacknowledged object must not enter aggregation")
				helpers.assert_eq(offset, 0)
				helpers.assert_eq(status, rotation.READ_STATUS_FAILED)
				helpers.assert_eq(rotation.rollover("unused.sql", rotation.READ_STATUS_EOF,
					function() return true end, function() return true end), false)
				local _, closes, calls = facts()
				helpers.assert_eq(closes, 0, "rollover must not discard the original pending stream")
				helpers.assert_eq(calls, 0, "rollover must not publish retirement for unacknowledged bytes")
				helpers.assert_eq(rotation.append_log(entry), true)
			end)
		end)
		helpers.it("(journal-append-receipt) refuses a different logical entry while the first row remains pending", function()
			with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry)
				helpers.assert_eq(rotation.append_log({ type = "typing", timestamp = TIMESTAMP, text = "other" }), false)
				helpers.assert_eq(rotation.append_log(entry), true)
			end)
		end)
	helpers.it("(journal-append-receipt) survives another partial suffix write on the same stream", function()
		with_receipt(function(bytes) return math.floor(#bytes / 2) end, function(rotation, entry)
			helpers.assert_eq(rotation.append_log(entry), false, "the second partial write must remain pending")
			helpers.assert_eq(rotation.append_log(entry), true, "the original row must finish after both refusals")
		end, { failures = 2 })
	end)
	helpers.it("(journal-append-receipt) bounds physical prefix verification across multiple turns", function()
		with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, _, controls)
			local turns, accepted = 0, false
			repeat
				controls.read_bytes = 0
				accepted = rotation.append_log(entry)
				turns = turns + 1
				helpers.assert_true(controls.read_bytes <= 64 * 1024,
					"one recovery turn must bound actual FILE reads, including its EOF probe")
				helpers.assert_true(turns < 10, "the retained prefix must make forward progress")
			until accepted
			helpers.assert_true(turns >= 3, "the fixture must exceed two verification budgets")
		end, { text = string.rep("x", 150000) })
	end)
	for _, budget in ipairs({ 2, 17, 64, 129 }) do
		helpers.it("(journal-append-injected-budget) honors a " .. budget .. " byte injected retry budget", function()
			with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, _, controls)
				local expected_turns = math.ceil(controls.refused_prefix_bytes / (budget - 1))
				local turns, accepted = 0, false
				repeat
					controls.read_bytes = 0
					local writes_before = controls.writes
					accepted = rotation.append_log(entry)
					turns = turns + 1
					helpers.assert_true(controls.read_bytes <= budget,
						string.format("FILE requested %d bytes including EOF against the injected %d-byte budget",
							controls.read_bytes, budget))
					helpers.assert_true(turns <= expected_turns, "bounded retries must make forward progress")
					if not accepted then
						helpers.assert_eq(controls.writes, writes_before,
							"cooperative yielding must not append before the complete prefix is verified")
					end
				until accepted
				helpers.assert_eq(turns, expected_turns)
				helpers.assert_true(turns > 1, "the UTF-8 prefix must require cooperative retries")
			end, { text = string.rep("é🌍", 60), recovery_turn_bytes = budget })
		end)
	end

	for _, invalid in ipairs({ { name = "zero", value = 0 }, { name = "EOF-only", value = 1 },
		{ name = "fractional", value = 2.5 }, { name = "missing" } }) do
		helpers.it("(journal-append-injected-budget) refuses a " .. invalid.name .. " init budget before journal IO", function()
			helpers.with_stub_scope({ "modules.keystats.rotation", "infra.logger", "adapters.ledger_append" }, function()
				local logger = helpers.make_logger_stub()
				local errors, opens = 0, 0
				logger.error = function() errors = errors + 1 end
				package.loaded["infra.logger"] = logger
				package.loaded["adapters.ledger_append"] = {}
				local rotation = helpers.load_with_stubs("modules.keystats.rotation")
				local original_open = io.open
				io.open = function() opens = opens + 1; return nil, "unexpected journal IO" end
				local ok, reason = pcall(rotation.init, { paths = { today_log_path = "/tmp/unused-budget.log" },
					state = {}, recovery_turn_bytes = invalid.value })
				io.open = original_open
				helpers.assert_eq(ok, true, tostring(reason))
				helpers.assert_eq(rotation.is_initialized(), false)
				helpers.assert_eq(opens, 0, "invalid budgets must be refused before journal IO")
				helpers.assert_eq(errors, 1, "invalid dependency receipt must be observable once")
			end)
		end)
	end
	for _, fault in ipairs({ "read_refusal", "seek_refusal" }) do
		helpers.it("(journal-append-receipt) restarts exact prefix verification after " .. fault, function()
			with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, _, controls)
				helpers.assert_eq(rotation.append_log(entry), false, "the first bounded prefix turn must remain pending")
				controls[fault] = true
				helpers.assert_eq(rotation.append_log(entry), false, "a native IO refusal must preserve ownership")
				helpers.assert_eq(rotation.append_log(entry), false, "verification must restart at the original anchor")
				helpers.assert_eq(rotation.append_log(entry), false, "the original prefix must be checked again")
				helpers.assert_eq(rotation.append_log(entry), true)
			end, { text = string.rep("x", 150000) })
		end)
	end

	helpers.it("(journal-append-receipt) refuses changed physical prefix bytes and restarts verification", function()
		with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, _, controls)
			helpers.assert_eq(rotation.append_log(entry), false)
			local changed = controls.anchor + 65535
			controls.rewrite(changed, "!")
			helpers.assert_eq(rotation.append_log(entry), false, "content disagreement cannot authorize a suffix append")
			helpers.assert_eq(controls.writes, 1, "unknown prefix bytes must preserve the original pending write")
			controls.rewrite(changed, "x")
			helpers.assert_eq(rotation.append_log(entry), false, "comparison refusal must reset the original byte proof")
			helpers.assert_eq(rotation.append_log(entry), false)
			helpers.assert_eq(rotation.append_log(entry), true)
		end, { text = string.rep("x", 150000) })
	end)
	helpers.it("(journal-append-receipt) fences synchronous diagnostic reentry during the original write", function()
		with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry, _, controls)
			helpers.assert_eq(controls.reentrant_results, { false }, "diagnostics must not replay an active append")
			helpers.assert_eq(rotation.append_log(entry), true)
			helpers.assert_eq(controls.writes, 2, "only the original prefix and exact suffix may reach FILE.write")
		end, { reentry = true })
	end)

	helpers.it("(journal-append-receipt) retains the restart separator inside its exact serialized receipt", function()
		with_receipt(function(bytes) return #bytes - 1 end, function(rotation, entry)
			helpers.assert_eq(rotation.append_log(entry), true)
		end, { unterminated_prefix = true })
	end)

end)
