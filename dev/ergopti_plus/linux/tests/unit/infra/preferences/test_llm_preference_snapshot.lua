--- tests/unit/infra/preferences/test_llm_preference_snapshot.lua

--- ==============================================================================
--- MODULE: Exact AI Preference Snapshot Revisions
--- DESCRIPTION:
--- Exercises real classified files and acknowledged writes while manifest
--- defaults or validation callbacks run after the original source read.
--- ==============================================================================

local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Manifest = require("infra.manifest_reader")
local Outdated = require("config_outdated")

local function with_preferences(body)
	Sandbox.with_config('[llm]\nenabled = false\nagent_mode = "action"\n[llm.models]\nselected = "ollama"\n', function(path)
		local old_paths, old_preferences = package.loaded["infra.config_paths"], package.loaded["infra.llm_preferences"]
		local original_default = Manifest.default_for
		local original_validation = Outdated.manifest_value_fits
		local ok, reason = pcall(function()
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["infra.llm_preferences"] = nil
			body(require("infra.llm_preferences"), path)
		end)
		Manifest.default_for = original_default
		Outdated.manifest_value_fits = original_validation
		package.loaded["infra.config_paths"], package.loaded["infra.llm_preferences"] = old_paths, old_preferences
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
