--- tests/unit/settings/preferences/test_llm_preference_snapshot.lua

--- ==============================================================================
--- MODULE: Exact AI Preference Snapshot Revisions
--- DESCRIPTION:
--- Exercises real classified files and acknowledged writes while manifest
--- defaults or validation callbacks run after the original source read.
---
--- The managed archive download re-admits its source about 30 times per 64 KiB
--- chunk, and each admission read config.toml again: 28 full reads per chunk
--- (about 2 ms on WSL). The reader now reads the bytes only when the file's
--- change token moves; the last block counts the full reads and proves every
--- kind of edit is still seen on the next read.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("tests.lua.settings.unused_keys_contract").sandbox
local Manifest = require("menu.engine.manifest_reader")
local Outdated = require("settings.engine.migration.outdated")

local function with_preferences(body)
	Sandbox.with_config('[llm]\nenabled = false\nagent_mode = "action"\n[llm.models]\nselected = "ollama"\n', function(path)
		local old_paths, old_preferences = package.loaded["settings.engine.paths"], package.loaded["ai.engine.preferences"]
		local original_default = Manifest.default_for
		local original_validation = Outdated.manifest_value_fits
		local ok, reason = pcall(function()
			package.loaded["settings.engine.paths"] = { config = function() return path end }
			package.loaded["ai.engine.preferences"] = nil
			body(require("ai.engine.preferences"), path)
		end)
		Manifest.default_for = original_default
		Outdated.manifest_value_fits = original_validation
		package.loaded["settings.engine.paths"], package.loaded["ai.engine.preferences"] = old_paths, old_preferences
		if not ok then error(reason, 0) end
	end)

end

helpers.describe("exact preference snapshot revision", function()
	helpers.it("pins the revision before a validation callback can acquire source ownership", function()
		with_preferences(function(preferences)
			local validation, acquired = Outdated.manifest_value_fits, false
			local owner = { pending = function() return false end }
			Outdated.manifest_value_fits = function(...)
				if not acquired then acquired = true; helpers.assert_true(preferences.acquire(owner)) end
				return validation(...)
			end
			local values, _, revision = preferences.get_many({ "llm.agent_mode" })
			helpers.assert_eq(values["llm.agent_mode"], "action")
			helpers.assert_true(acquired)
			helpers.assert_eq(type(revision), "number")
			helpers.assert_eq(preferences.is_current_revision(revision), false)
			helpers.assert_true(preferences.release(owner))
		end)
	end)
	helpers.it("returns the unchanged source and its acknowledged revision as a third result", function()
		with_preferences(function(preferences, path)
			local before = Sandbox.read_bytes(path)
			local values, source, revision = preferences.get_many({ "llm.enabled", "llm.models.selected" })
			helpers.assert_eq(values["llm.enabled"], false)
			helpers.assert_eq(values["llm.models.selected"], "ollama")
			helpers.assert_eq(source, { status = "ok", content = before })
			helpers.assert_eq(type(revision), "number")
			helpers.assert_true(preferences.is_current_revision(revision))
		end)
	end)
	helpers.it("does not relabel an old snapshot after an acknowledged default callback write", function()
		with_preferences(function(preferences)
			local default, changed = Manifest.default_for, false
			Manifest.default_for = function(path)
				if path == "llm.models.ollama" and not changed then
					changed = true
					helpers.assert_true(preferences.set("llm.enabled", true))
				end
				return default(path)
			end
			local values, source, revision = preferences.get_many({ "llm.enabled", "llm.models.ollama" })
			helpers.assert_true(changed)
			helpers.assert_eq(values["llm.enabled"], false)
			helpers.assert_true(source.content:find("enabled = false", 1, true) ~= nil)
			helpers.assert_eq(type(revision), "number")
			helpers.assert_eq(preferences.is_current_revision(revision), false)
			helpers.assert_eq(preferences.get("llm.enabled"), true)
		end)
	end)
	helpers.it("retires old snapshots on same-byte writes and acknowledged ABA edits", function()
		with_preferences(function(preferences, path)
			helpers.assert_true(preferences.set("llm.models.ollama", "fixture"))
			local _, source, revision = preferences.get_many({ "llm.models.ollama" })
			helpers.assert_true(preferences.set("llm.models.ollama", "fixture"))
			helpers.assert_eq(Sandbox.read_bytes(path), source.content)
			helpers.assert_eq(type(revision), "number")
			helpers.assert_eq(preferences.is_current_revision(revision), false)
			local _, middle, next_revision = preferences.get_many({ "llm.models.ollama" })
			helpers.assert_true(preferences.set("llm.models.ollama", "another-fixture"))
			helpers.assert_true(preferences.set("llm.models.ollama", "fixture"))
			helpers.assert_eq(preferences.is_current_revision(next_revision), false)
			helpers.assert_eq(middle.status, source.status)
			helpers.assert_eq(Sandbox.read_bytes(path), middle.content)
		end)
	end)
end)

-- The change token: real files, real lstat, a clock that can make the file old.
helpers.describe("AI preference reads follow the file's change token", function()
	local ok_luv, luv = pcall(require, "luv")
	if not ok_luv then
		helpers.it("needs the real luv backend", function()
			helpers.assert_true(false, "the unit lane installs luv; this block stats real files")
		end)
		return
	end
	local Writer = require("core.text.engine.toml_codec.writer")

	--- Runs `body` with every full read of `path` counted.
	--- @return integer reads
	local function counting_reads(path, body)
		local original, reads = Writer.read_classified, 0
		Writer.read_classified = function(candidate, ...)
			if candidate == path then reads = reads + 1 end
			return original(candidate, ...)
		end
		local ok, reason = pcall(body)
		Writer.read_classified = original
		if not ok then error(reason, 0) end
		return reads
	end

	--- Replaces `old` with `new` (same length) in place: same inode, same size.
	local function edit_in_place(path, old, new)
		helpers.assert_eq(#old, #new)
		local handle = assert(io.open(path, "r+b"))
		local at = assert(handle:read("*a"):find(old, 1, true))
		handle:seek("set", at - 1)
		handle:write(new)
		handle:close()
	end

	--- The file's quiet period has passed: a clock well past its stamps.
	local function long_after(preferences)
		preferences._set_clock_for_test(function() return (os.time() + 60) * 1000 end)
	end

	helpers.it("reads the bytes once while a settled file's token holds", function()
		with_preferences(function(preferences, path)
			long_after(preferences)
			local reads = counting_reads(path, function()
				for _ = 1, 50 do
					local values, source = preferences.get_many({ "llm.models.selected" })
					helpers.assert_eq(values["llm.models.selected"], "ollama")
					helpers.assert_eq(source.status, "ok")
				end
			end)
			preferences._set_clock_for_test(nil)
			-- One read records the token, the next proves it held: never one per call.
			helpers.assert_true(reads <= 2, reads .. " full reads for 50 admissions")
		end)
	end)

	helpers.it("sees a same-size in-place edit of a settled file on the next read", function()
		with_preferences(function(preferences, path)
			long_after(preferences)
			helpers.assert_eq(preferences.get_many({ "llm.enabled" })["llm.enabled"], false)
			helpers.assert_eq(preferences.get_many({ "llm.enabled" })["llm.enabled"], false)
			-- Past one coarse timestamp tick, as a real edit is: only the change
			-- time tells this edit apart.
			luv.sleep(30)
			edit_in_place(path, "enabled = false", "enabled = true ")
			local values, _, revision = preferences.get_many({ "llm.enabled" })
			preferences._set_clock_for_test(nil)
			helpers.assert_eq(values["llm.enabled"], true, "the edit was not seen")
			helpers.assert_true(preferences.is_current_revision(revision))
		end)
	end)

	helpers.it("sees an atomic replace of a settled file on the next read", function()
		with_preferences(function(preferences, path)
			long_after(preferences)
			preferences.get_many({ "llm.enabled" })
			preferences.get_many({ "llm.enabled" })
			local staged = path .. ".new"
			local handle = assert(io.open(staged, "wb"))
			handle:write("[llm]\nenabled = true\n[llm.models]\nselected = \"ollama\"\n")
			handle:close()
			assert(os.rename(staged, path))
			local values = preferences.get_many({ "llm.enabled" })
			preferences._set_clock_for_test(nil)
			helpers.assert_eq(values["llm.enabled"], true, "the replaced file was not read")
		end)
	end)

	helpers.it("reads the bytes on every call while the file is too recent to trust", function()
		with_preferences(function(preferences, path)
			-- The real clock: the sandbox has just written the file, so an edit
			-- within the same timestamp tick could keep every field of the token.
			local reads = counting_reads(path, function()
				for _ = 1, 5 do helpers.assert_eq(preferences.get_many({ "llm.enabled" })["llm.enabled"], false) end
				edit_in_place(path, "enabled = false", "enabled = true ")
				helpers.assert_eq(preferences.get_many({ "llm.enabled" })["llm.enabled"], true,
					"the edit made within the tick was not read")
			end)
			helpers.assert_eq(reads, 6, "a recent file must be read every time")
		end)
	end)
end)
