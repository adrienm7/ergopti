--- tests/unit/modules/hotstrings/test_repeat_key.lua

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
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local Writer = require("toml_codec.writer")
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
			Writer.batch_write = function(target, operations, files, expected)
				if controls.external then Sandbox.write_bytes(target, controls.external) end
				if controls.refuse then return false, "injected publication refusal" end
				return original(target, operations, files, expected)
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
			local config = require("toml_codec").decode(sandbox.read_bytes(path))
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
			helpers.assert_eq(require("toml_codec").decode(sandbox.read_bytes(path)).hotstrings.repeat_key_enabled, nil)
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
				require("config_outdated").reset_for_tests()
				local reported = require("config_outdated").collect_reports(function()
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
				local writer = require("toml_codec.writer")
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
			helpers.assert_true(require("toml_codec.writer").batch_write(path, operations))
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
			local writer = require("toml_codec.writer")
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
