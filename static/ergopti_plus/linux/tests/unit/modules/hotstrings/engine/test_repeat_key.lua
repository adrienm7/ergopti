--- tests/unit/modules/hotstrings/engine/test_repeat_key.lua

--- ==============================================================================
--- MODULE: Magic-Key Repeat
--- DESCRIPTION:
--- The rule that turns `po★` into `poo`, and the conditions under which it must
--- stay out of the way.
---
--- WHY THIS EXISTS AT ALL:
--- The manifest declared `hotstrings.repeat_key_enabled` and the `repeat_key`
--- menu row as `platforms = ["ahk"]`, so a parity ratchet reading the manifest
--- reported Linux as complete while the keystroke did nothing and no row offered
--- it. The restriction was false the day it was written — macOS ships both the
--- engine and the toggle — and the way to close a gap the manifest describes
--- wrongly is to write the feature and correct the declaration, not to widen the
--- declaration over an absence.
---
--- WHAT IS ASSERTED HERE IS THE RULE, NOT THE KEYSTROKE:
--- `M.resolve` is pure, so the decision can be checked without a keyboard, a
--- display or an injector. The daemon's part — running it only when nothing else
--- matched — is one line at the call site and is asserted by the shape of the
--- result it builds.
--- ==============================================================================

local helpers = require("tests.helpers")

local RepeatKey = helpers.load_module("modules.hotstrings.repeat_key")

local STAR = "★"




-- =================================================================
-- =================================================================
-- ======= 1/ When it fires ========================================
-- =================================================================
-- =================================================================

helpers.describe("magic-key repeat: the rule", function()

	helpers.it("doubles the character before the magic key", function()
		local out = RepeatKey.resolve("po" .. STAR, STAR)
		helpers.assert_true(out ~= nil, "typing the magic key after a letter must repeat it")
		helpers.assert_eq(out.replacement, "o", "the character immediately before the key")
		helpers.assert_eq(out.backspace_count, 1,
			"only the magic key is erased — the character before it stays and is joined "
				.. "by its copy, so the caret moves once rather than twice")
	end)

	helpers.it("repeats a multi-byte character whole", function()
		-- LuaJIT is 5.1-based and has no utf8 library, so a byte-wise
		-- implementation would repeat the last BYTE of "é" and emit mojibake.
		local out = RepeatKey.resolve("caf\195\169" .. STAR, STAR)
		helpers.assert_eq(out.replacement, "\195\169",
			"the whole codepoint, not its trailing byte")
	end)

	helpers.it("preserves three- and four-byte characters and word boundaries", function()
		for _, char in ipairs({ "漢", "𐐀" }) do
			local out = RepeatKey.resolve("a" .. char .. STAR, STAR)
			helpers.assert_true(out ~= nil)
			helpers.assert_eq(out.replacement, char)
			helpers.assert_eq(out.backspace_count, 1)
			helpers.assert_nil(RepeatKey.resolve(char .. STAR, STAR), "a word's first character is not repeated")
			helpers.assert_nil(RepeatKey.resolve("a" .. char .. STAR, STAR, false),
				"an unknown buffer boundary must not authorize repetition")
		end
	end)

	helpers.it("a delimiter the user added ends a word, as on Windows (PAR-8)", function()
		local Terminators = require("layouts.engine.layers.terminators")
		helpers.assert_true(RepeatKey.resolve("ab1" .. STAR, STAR) ~= nil, "before: a digit is a word character")
		helpers.assert_eq(Terminators.add_custom_terminator("custom_1", "1", "1", false), true)
		local repeated, resting = RepeatKey.resolve("ab1" .. STAR, STAR), RepeatKey.resolve("1a" .. STAR, STAR)
		helpers.assert_eq(Terminators.remove_custom_terminator("custom_1"), true)
		helpers.assert_eq(repeated, nil, "the delimiter itself is not repeated")
		helpers.assert_eq(resting, nil, "and the letter after it starts a word")
	end)

	helpers.it("works with a magic key the user chose", function()
		local out = RepeatKey.resolve("ab@", "@")
		helpers.assert_eq(out.replacement, "b",
			"the key is read from the caller, not baked in — a user who changed it "
				.. "must get the same behaviour")
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 2/ When it must not =====================================
-- =================================================================
-- =================================================================

helpers.describe("magic-key repeat: when it stays out of the way", function()

	helpers.it("does nothing when the buffer does not end with the magic key", function()
		helpers.assert_nil(RepeatKey.resolve("po" .. STAR .. "x", STAR),
			"this fires on the keystroke that typed the key; a magic key further back "
				.. "is history the user has moved past")
	end)

	helpers.it("does nothing when the magic key is the whole buffer", function()
		helpers.assert_nil(RepeatKey.resolve(STAR, STAR),
			"there is nothing before it to repeat")
	end)

	helpers.it("does not double the magic key itself", function()
		helpers.assert_nil(RepeatKey.resolve(STAR .. STAR, STAR),
			"two magic keys are a second trigger, not a repeat — doubling here would "
				.. "let a held key emit an unbounded run of them")
	end)

	helpers.it("refuses a missing or empty magic key rather than guessing", function()
		helpers.assert_nil(RepeatKey.resolve("po", ""))
		helpers.assert_nil(RepeatKey.resolve("po", nil))
		helpers.assert_nil(RepeatKey.resolve(nil, STAR))
	end)

end)




-- =================================================================
-- =================================================================
-- ======= 3/ The setting ==========================================
-- =================================================================
-- =================================================================

--- Runs canonical persistence over an exclusive file and isolated runtime cache.
--- @param source string|nil Configuration bytes.
--- @param body function Test body.
local function with_repeat(source, body)
	local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox
	local Writer = require("core.text.engine.toml_codec.writer")
	local loaded = {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local original = Writer.batch_write
	local ok, err = pcall(function()
		Sandbox.with_config(source, function(path)
			local controls = { legacy_writes = 0 }
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = {
				get = function() return true end,
				set = function() controls.legacy_writes = controls.legacy_writes + 1; return true end,
			}
			Writer.batch_write = function(target, operations, files, expected, on_error, admission, on_notice)
				if controls.external then Sandbox.write_bytes(target, controls.external) end
				if controls.refuse then return false, "injected publication refusal" end
				return original(target, operations, files, expected, on_error, admission, on_notice)
			end
			local function reload()
				package.loaded["modules.hotstrings.repeat_key"] = nil
				return require("modules.hotstrings.repeat_key")
			end
			body(reload(), controls, path, reload, Sandbox)
		end)
	end)
	Writer.batch_write = original
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

local SOURCE = '[hotstrings]\nrepeat_key_enabled = true\nunknown = "keep"\n[other]\nvalue = 42\n'

helpers.describe("repeat key menu persistence", function()
	helpers.it("the actual bootstrap reporter forwards native notification admission", function()
		local path = helpers.driver_root() .. "/ergopti_hotstrings.lua"
		local file = assert(io.open(path, "rb")); local source = assert(file:read("*a")); assert(file:close())
		local closure = assert(source:match('set_case_twin_reporter%((function%(message, admission%)[%s%S]-end)%)'), "bootstrap reporter must exist")
		local reporter = assert(loadstring("return " .. closure))()
		local notifier = require("adapters.notifier")
		local previous = notifier.send
		local ok, err = pcall(function()
			for _, result in ipairs({ false, true }) do
				notifier.send = function(message, options)
					helpers.assert_eq(message, "sample"); helpers.assert_eq(options.level, "error")
					return result
				end
				helpers.assert_eq(reporter("sample"), result)
			end
			local calls = 0
			notifier.send = function() calls = calls + 1; return true end
			helpers.assert_eq(reporter("sample", function() return false end), false)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(reporter("sample", function() return true end), true)
			helpers.assert_eq(calls, 1)
		end)
		notifier.send = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("a backwards clock does not suppress a new case-twin notice", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local writer = require("core.text.engine.toml_codec.writer")
		local path, time, reports = os.tmpname(), os.time, 0
		local file = assert(io.open(path, "w")); file:write("[section]\nkey = 1\nKEY = 2\n"); file:close()
		writer.set_case_twin_reporter(function() reports = reports + 1 end)
		local now = 100; os.time = function() return now end
		local ok, err = pcall(function()
			assert(writer.prepare_batch(path, {{ section = "section", key = "key", value = 3 }}) == false)
			now = 90
			helpers.assert_nil(writer.take_case_twin_notice())
			assert(writer.prepare_batch(path, {{ section = "section", key = "key", value = 3 }}) == false)
			helpers.assert_eq(reports, 2)
		end)
		os.time = time; os.remove(path); package.loaded["core.text.engine.toml_codec.writer"] = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("does not duplicate the case-twin notice from this exact write", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local ok, err = pcall(function()
			with_repeat('[hotstrings]\nrepeat_key_enabled = true\nREPEAT_KEY_ENABLED = false\n', function()
				local writer = require("core.text.engine.toml_codec.writer")
				local reports, notices, execute = 0, 0, os.execute
				writer.set_case_twin_reporter(function() reports = reports + 1 end)
				local rows = helpers.load_module("ui.menu.builder").build({ config = {
					any_enabled = function() return true end, get_groups = function() return {} end,
					is_group_enabled = function() return true end, is_section_enabled = function() return true end } })
				local function find(items)
					for _, row in ipairs(items or {}) do
						if row.title == require("infra.i18n").get("menu.hotstrings.repeat_key_toggle") then return row end
						local nested = find(row.menu); if nested then return nested end
					end
				end
				local row = assert(find(rows))
				os.execute = function(command) if command:find("dialog_host.lua", 1, true) then notices = notices + 1; return 0 end; return execute(command) end
				local called, result = pcall(row.fn)
				os.execute = execute
				helpers.assert_true(called); helpers.assert_eq(result, false)
				helpers.assert_eq(reports, 1); helpers.assert_eq(notices, 0)
			end)
		end)
		package.loaded["core.text.engine.toml_codec.writer"] = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("does not grant a notice receipt when the reporter refuses", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local ok, err = pcall(function()
			with_repeat('[hotstrings]\nrepeat_key_enabled = true\nREPEAT_KEY_ENABLED = false\n', function(subject)
				local writer = require("core.text.engine.toml_codec.writer")
				writer.set_case_twin_reporter(function() return false end)
				local committed, noticed = subject.toggle_with_notice()
				helpers.assert_eq({ committed, noticed }, { false, false })
			end)
		end)
		package.loaded["core.text.engine.toml_codec.writer"] = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("keeps nested case-twin notice receipts with their own attempts", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local writer = require("core.text.engine.toml_codec.writer")
		local outer, inner = os.tmpname(), os.tmpname()
		for _, path in ipairs({ outer, inner }) do
			local file = assert(io.open(path, "w")); file:write("[section]\nkey = 1\nKEY = 2\n"); file:close()
		end
		local inner_notice, outer_notice, nested = false, false, false
		writer.set_case_twin_reporter(function()
			if not nested then
				nested = true
				local committed = writer.batch_write(inner, {{ section = "section", key = "key", value = 3 }}, nil, nil, nil, nil,
					function() inner_notice = true end)
				assert(committed == false)
			end
		end)
		local committed = writer.batch_write(outer, {{ section = "section", key = "key", value = 3 }}, nil, nil, nil, nil,
			function() outer_notice = true end)
		os.remove(outer); os.remove(inner)
		package.loaded["core.text.engine.toml_codec.writer"] = previous
		helpers.assert_eq(committed, false)
		helpers.assert_eq({ outer_notice, inner_notice }, { true, true })
	end)
	helpers.it("keeps a previous legacy notice while delivering a new owned notice", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local writer = require("core.text.engine.toml_codec.writer")
		local path = os.tmpname()
		local file = assert(io.open(path, "w"))
		file:write("[first]\nkey = 1\nKEY = 2\n[second]\nitem = 1\nITEM = 2\n"); file:close()
		writer.set_case_twin_reporter(function() end)
		assert(writer.prepare_batch(path, {{ section = "first", key = "key", value = 3 }}) == false)
		local noticed = false
		assert(writer.batch_write(path, {{ section = "second", key = "item", value = 3 }}, nil, nil, nil, nil,
			function() noticed = true end) == false)
		local prior = writer.take_case_twin_notice()
		os.remove(path); package.loaded["core.text.engine.toml_codec.writer"] = previous
		helpers.assert_true(noticed)
		helpers.assert_eq(prior, "first.KEY")
	end)
	helpers.it("reports a new owned attempt even when the same old setting was recently reported", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local writer = require("core.text.engine.toml_codec.writer")
		local path = os.tmpname(); local file = assert(io.open(path, "w"))
		file:write("[first]\nkey = 1\nKEY = 2\n"); file:close()
		local reports, noticed = 0, false
		writer.set_case_twin_reporter(function() reports = reports + 1 end)
		assert(writer.prepare_batch(path, {{ section = "first", key = "key", value = 3 }}) == false)
		assert(writer.batch_write(path, {{ section = "first", key = "key", value = 3 }}, nil, nil, nil, nil,
			function() noticed = true end) == false)
		local previous_notice = writer.take_case_twin_notice()
		os.remove(path); package.loaded["core.text.engine.toml_codec.writer"] = previous
		helpers.assert_eq(reports, 2)
		helpers.assert_true(noticed)
		helpers.assert_eq(previous_notice, "first.KEY")
	end)
	helpers.it("an owned notice does not extend the legacy notice suppression window", function()
		local previous = package.loaded["core.text.engine.toml_codec.writer"]
		package.loaded["core.text.engine.toml_codec.writer"] = nil
		local writer = require("core.text.engine.toml_codec.writer")
		local path, old_time = os.tmpname(), os.time
		local file = assert(io.open(path, "w")); file:write("[first]\nkey = 1\nKEY = 2\n"); file:close()
		local reports, now = 0, 100
		writer.set_case_twin_reporter(function() reports = reports + 1 end)
		os.time = function() return now end
		local ok, err = pcall(function()
			local updates = {{ section = "first", key = "key", value = 3 }}
			assert(writer.prepare_batch(path, updates) == false)
			now = 104
			assert(writer.batch_write(path, updates, nil, nil, nil, nil, function() end) == false)
			now = 106
			assert(writer.prepare_batch(path, updates) == false)
			helpers.assert_eq(reports, 3)
		end)
		os.time = old_time; os.remove(path); package.loaded["core.text.engine.toml_codec.writer"] = previous
		if not ok then error(err, 0) end
	end)
	helpers.it("a held scope reports its refusal without consuming an older TOML notice", function()
		with_repeat(SOURCE, function()
			local builder = helpers.load_module("ui.menu.builder")
			local rows = builder.build({ config = { any_enabled = function() return true end,
				get_groups = function() return {} end, is_group_enabled = function() return true end,
				is_section_enabled = function() return true end } })
			local function find(items)
				for _, row in ipairs(items or {}) do
					if row.title == require("infra.i18n").get("menu.hotstrings.repeat_key_toggle") then return row end
					local nested = find(row.menu); if nested then return nested end
				end
			end
			local row = assert(find(rows))
			local preferences = require("infra.hotstring_preferences")
			local owner = {}; assert(preferences.acquire(owner))
			local prior = package.loaded["core.text.engine.toml_codec.writer"]
			package.loaded["core.text.engine.toml_codec.writer"] = nil
			local writer = require("core.text.engine.toml_codec.writer")
			local path = os.tmpname(); local file = assert(io.open(path, "w"))
			file:write("[section]\nkey = 1\nKEY = 2\n"); file:close()
			local reports = 0; writer.set_case_twin_reporter(function() reports = reports + 1 end)
			assert(writer.prepare_batch(path, {{ section = "section", key = "key", value = 3 }}) == false)
			local execute, notices = os.execute, 0
			os.execute = function(command) if command:find("dialog_host.lua", 1, true) then notices = notices + 1; return 0 end; return execute(command) end
			local called, result = pcall(row.fn)
			os.execute = execute
			local retained = writer.take_case_twin_notice()
			package.loaded["core.text.engine.toml_codec.writer"] = prior
			assert(preferences.release(owner)); os.remove(path)
			helpers.assert_true(called); helpers.assert_eq(result, false); helpers.assert_eq(reports, 1)
			helpers.assert_eq(notices, 1)
			helpers.assert_not_nil(retained, "the prior caller retains its own notice receipt")
		end)
	end)
	helpers.it("reports a refused real config write without redrawing success", function()
		with_repeat(SOURCE, function(subject, _, path, _, sandbox)
			local changes, notices = 0, 0
			local old, rename = os.execute, os.rename
			os.execute = function(command)
				if command:find("dialog_host.lua", 1, true) then notices = notices + 1; return 0 end
				return old(command)
			end
			local ok, err = pcall(function()
				local builder = helpers.load_module("ui.menu.builder")
				local rows = builder.build({ config = { any_enabled = function() return true end,
					get_groups = function() return {} end, is_group_enabled = function() return true end,
					is_section_enabled = function() return true end },
					on_menu_changed = function() changes = changes + 1 end })
				local function find(items)
					for _, row in ipairs(items or {}) do
						if row.title == require("infra.i18n").get("menu.hotstrings.repeat_key_toggle") then return row end
						local nested = find(row.menu); if nested then return nested end
					end
				end
				local row = assert(find(rows), "real repeat menu row must exist")
				os.rename = function(from, to) if to == path then return false, "inert refusal" end; return rename(from, to) end
				helpers.assert_eq(row.fn(), false)
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
				helpers.assert_eq(subject.is_enabled(), true)
				os.rename = rename
				local toggle = subject.toggle_with_notice
				subject.toggle_with_notice = function() assert(toggle() == true); error("inert post-save exception") end
				local called = pcall(row.fn)
				subject.toggle_with_notice = toggle
				helpers.assert_eq(called, false)
			end)
			os.execute, os.rename = old, rename
			helpers.assert_true(ok, tostring(err))
			helpers.assert_eq(changes, 0)
			helpers.assert_eq(notices, 1)
			helpers.assert_true(sandbox.read_bytes(path) ~= SOURCE)
			helpers.assert_eq(subject.is_enabled(), false)
		end)
	end)
end)
helpers.describe("magic-key repeat: canonical sparse preferences", function()
	helpers.it("keeps an empty canonical config neutral despite a legacy true", function()
		with_repeat(nil, function(subject, _, path, _, sandbox)
			helpers.assert_eq(subject.is_enabled(), false)
			helpers.assert_eq(sandbox.read_bytes(path), nil)
		end)
	end)

	helpers.it("reads canonical false instead of the legacy true", function()
		with_repeat('[hotstrings]\nrepeat_key_enabled = false\n', function(subject)
			helpers.assert_eq(subject.is_enabled(), false)
		end)
	end)

	helpers.it("persists true and preserves neighbors across fresh module load", function()
		with_repeat(SOURCE:gsub("enabled = true", "enabled = false"), function(subject, controls, path, reload, sandbox)
			helpers.assert_true(subject.set_enabled(true))
			local config = require("core.text.engine.toml_codec").decode(sandbox.read_bytes(path))
			helpers.assert_eq(config.hotstrings.repeat_key_enabled, true)
			helpers.assert_eq(config.hotstrings.unknown, "keep")
			helpers.assert_eq(config.other.value, 42)
			helpers.assert_true(subject.is_enabled())
			helpers.assert_true(reload().is_enabled())
			helpers.assert_eq(controls.legacy_writes, 0)
		end)
	end)

	helpers.it("clears the leaf sparsely without resurrecting legacy or cached true", function()
		with_repeat(SOURCE, function(subject, _, path, reload, sandbox)
			helpers.assert_true(subject.is_enabled())
			helpers.assert_true(subject.set_enabled(false))
			helpers.assert_eq(require("core.text.engine.toml_codec").decode(sandbox.read_bytes(path)).hotstrings.repeat_key_enabled, nil)
			helpers.assert_eq(subject.is_enabled(), false)
			helpers.assert_eq(reload().is_enabled(), false)
		end)
	end)

	helpers.it("preserves exact runtime and source when publication refuses", function()
		with_repeat(SOURCE, function(subject, controls, path, _, sandbox)
			helpers.assert_true(subject.is_enabled())
			controls.refuse = true
			helpers.assert_eq(subject.set_enabled(false), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			helpers.assert_true(subject.is_enabled())
		end)
	end)

	helpers.it("rejects an external edit between validation and publication", function()
		with_repeat(SOURCE, function(subject, controls, path, _, sandbox)
			helpers.assert_true(subject.is_enabled())
			controls.external = SOURCE .. "external = 9\n"
			helpers.assert_eq(subject.set_enabled(false), false)
			helpers.assert_eq(sandbox.read_bytes(path), controls.external)
			helpers.assert_true(subject.is_enabled())
		end)
	end)

	helpers.it("reads an outdated value as neutral, never a legacy value, and offers it (config-outdated-repeat-key)",
		function()
			with_repeat('[hotstrings]\nrepeat_key_enabled = "bad"\nunknown = "keep"\n', function(subject, _, path, _, sandbox)
				require("settings.engine.migration.outdated").reset_for_tests()
				local reported = require("settings.engine.migration.outdated").collect_reports(function()
					helpers.assert_eq(subject.is_enabled(), false)
				end)
				helpers.assert_eq(reported, { ["hotstrings.repeat_key_enabled"] = true })
				package.loaded["ui.menu.unused_keys_cleanup"] = nil
				local scan = require("ui.menu.unused_keys_cleanup").find(path)
				helpers.assert_eq(scan.status, "ok", "the cleanup scan never fails on it")
				local offered = {}
				for _, key in ipairs(scan.keys) do offered[table.concat(key.path, ".")] = true end
				helpers.assert_true(offered["hotstrings.repeat_key_enabled"], "the outdated value is offered")
				helpers.assert_true(subject.set_enabled(true), "a menu choice replaces the outdated value")
				helpers.assert_true(subject.is_enabled())
				helpers.assert_contains(sandbox.read_bytes(path), "repeat_key_enabled = true")
			end)
			with_repeat("hotstrings = true\n", function(subject, _, path)
				helpers.assert_eq(subject.is_enabled(), false)
				package.loaded["ui.menu.unused_keys_cleanup"] = nil
				helpers.assert_eq(require("ui.menu.unused_keys_cleanup").find(path).status, "ok",
					"an old scalar [hotstrings] never makes the cleanup scan unreadable")
			end)
		end)

	-- The typing path calls is_enabled() for every unmatched character inside the
	-- keyboard hook's guarded callback, whose error handler emergency-stops the
	-- hook: one malformed leaf must neither raise nor reread the disk per key.
	for _, source in ipairs({ '[hotstrings]\nrepeat_key_enabled = "true"\n', "[hotstrings\nbroken" }) do
		helpers.it("never raises on the typing path for " .. source:gsub("\n", " "), function()
			with_repeat(source, function(subject)
				local writer = require("core.text.engine.toml_codec.writer")
				local read = writer.read_classified
				local calls = 0
				writer.read_classified = function(...) calls = calls + 1; return read(...) end
				local ok, err = pcall(function()
					for _ = 1, 50 do helpers.assert_eq(subject.is_enabled(), false) end
				end)
				writer.read_classified = read
				if not ok then error(err, 0) end
				helpers.assert_eq(calls, 1, "a refused read is cached, not retried per keystroke")
			end)
		end)
	end

	helpers.it("does not coerce a nonboolean setter into activation", function()
		with_repeat(SOURCE, function(subject, _, path, _, sandbox)
			helpers.assert_eq(subject.set_enabled("false"), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)

	helpers.it("refreshes the leaf after an actual canonical clear candidate was published", function()
		with_repeat(SOURCE, function(subject, _, path)
			helpers.assert_true(subject.is_enabled())
			local operations = require("infra.manifest_reader").scope_operations("hotstrings", "clear")
			helpers.assert_true(require("core.text.engine.toml_codec.writer").batch_write(path, operations))
			helpers.assert_true(subject.refresh())
			helpers.assert_eq(subject.is_enabled(), false)
		end)
	end)

	helpers.it("retains the last valid runtime when an explicit refresh refuses", function()
		with_repeat(SOURCE, function(subject, _, path, _, sandbox)
			helpers.assert_true(subject.is_enabled())
			sandbox.write_bytes(path, '[hotstrings\nrepeat_key_enabled = "bad"\n')
			helpers.assert_eq(subject.refresh(), false)
			helpers.assert_true(subject.is_enabled())
		end)
	end)

	helpers.it("does not reread disk on each input-path query", function()
		with_repeat(SOURCE, function(subject)
			helpers.assert_true(subject.is_enabled())
			local writer = require("core.text.engine.toml_codec.writer")
			local read = writer.read_classified
			local calls = 0
			writer.read_classified = function(...) calls = calls + 1; return read(...) end
			local ok, err = pcall(function() for _ = 1, 100 do helpers.assert_true(subject.is_enabled()) end end)
			writer.read_classified = read
			if not ok then error(err, 0) end
			helpers.assert_eq(calls, 0)
		end)
	end)

	helpers.it("keeps the consumed setting during actual unused-key cleanup", function()
		with_repeat(SOURCE, function(_, _, path)
			package.loaded["ui.menu.unused_keys_cleanup"] = nil
			local scan = require("ui.menu.unused_keys_cleanup").find(path)
			helpers.assert_eq(scan.status, "ok")
			local found_unknown = false
			for _, key in ipairs(scan.keys) do
				helpers.assert_true(table.concat(key.path, ".") ~= "hotstrings.repeat_key_enabled")
				if table.concat(key.path, ".") == "hotstrings.unknown" then found_unknown = true end
			end
			helpers.assert_true(found_unknown)
		end)
	end)
end)




-- =================================================================
-- =================================================================
-- ======= 4/ The shared corpus ====================================
-- =================================================================
-- =================================================================

--- Decodes one shared hotstrings corpus file.
--- @param name string File name under _shared/tests/corpus/hotstrings.
--- @return table vectors
local function corpus_vectors(name)
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/" .. name
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	local corpus = assert(require("core.text.engine.json").decode(raw), name .. " must be valid JSON")
	assert(#corpus.vectors > 0, name .. " must hold vectors")
	return corpus.vectors
end

helpers.describe("magic-key repeat: the shared repeat_key_vectors.json corpus", function()
	for _, vector in ipairs(corpus_vectors("repeat_key_vectors.json")) do
		helpers.it(vector.id .. " (repeat-key-corpus)", function()
			local out = RepeatKey.resolve(vector.buffer, vector.magic_key, vector.start_is_word_boundary)
			if vector.fires then
				helpers.assert_true(out ~= nil, vector.description)
				helpers.assert_eq(out.replacement, vector.replacement, vector.description)
				helpers.assert_eq(out.backspace_count, 1)
			else
				helpers.assert_nil(out, vector.description)
			end
		end)
	end
end)

helpers.describe("idle word reset: the shared idle_reset_vectors.json corpus", function()
	local Engine = require("hotstrings.engine.matcher")
	for _, vector in ipairs(corpus_vectors("idle_reset_vectors.json")) do
		helpers.it(vector.id .. " (idle-reset-corpus)", function()
			-- A JSON null decodes to a sentinel table: only a number is a keystroke time.
			local last = type(vector.last_ms) == "number" and vector.last_ms or nil
			helpers.assert_eq(
				Engine.idle_resets_word(last, vector.now_ms, vector.idle_seconds, 0),
				vector.resets, vector.description)
		end)
	end
end)
