--- tests/unit/ui/editors/prompt_editor/test_profile_roundtrip.lua

--- ==============================================================================
--- MODULE: Prompt Profile Editor Round Trips (Linux)
--- DESCRIPTION:
--- Exercise the real editor, profile settings and TOML writer. Only the native
--- window host is controlled; every persisted result is reopened from disk.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local uv = require("luv")

--- Isolates the real profile registry and native window port.
--- @param body function
local function with_editor(body)
	require("infra.llm_preferences")
	require("modules.llm.profile_settings")
	local names = { "infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings",
		"ui.webview_manager", "ui.prompt_editor.bridge" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local dir = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-profiles-XXXXXX"))
	local path = dir .. "/config.toml"
	local function read()
		local file = assert(io.open(path, "rb"))
		local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	local file = assert(io.open(path, "wb"))
	assert(file:write("# unrelated source stays intact\n[independent]\nkeep = 'sentinel'\n")); assert(file:close())
	local paths = {}
	for key, value in pairs(previous["infra.config_paths"]) do paths[key] = value end
	paths.config = function() return path end
	package.loaded["infra.config_paths"] = paths
	package.loaded["infra.llm_preferences"] = nil
	local profiles = helpers.load_module("modules.llm.profile_settings")
	local seen = { epoch = 0, visible = false, closes = 0 }
	local host = {
		show = function() seen.epoch = seen.epoch + 1; seen.visible = true; return true end,
		hide = function() seen.closes = seen.closes + 1; seen.visible = false; return true end,
		is_visible = function() return seen.visible end,
		current_epoch = function() return seen.epoch end,
		page_current = function(_, epoch) return seen.visible and epoch == seen.epoch end,
		eval_js = function() return true end,
	}
	package.loaded["ui.webview_manager"] = host
	local bridge = helpers.load_module("ui.prompt_editor.bridge")
	local f = { profiles = profiles, read = read, path = path, seen = seen, bridge = bridge }
	function f.seed(overrides)
		local profile = { id = "user_original", label = "Original", batch = false,
			system_single = "Continue {context}", system_multi = "Auxiliary body",
			system_multi_template = "Count {n}", stop_sequences = Json.array({ "END", "STOP" }) }
		for key, value in pairs(overrides or {}) do profile[key] = value end
		assert(profiles.save_user_profile(profile, false, false))
		return assert(profiles.resolve_id(profile.id))
	end
	function f.open(seed, options, callback)
		local create = not seed or options and options.as_new == true
		assert(bridge.open(seed, callback or function(candidate)
			return profiles.save_user_profile(candidate, false, not create)
		end, options))
		local context = { epoch = seen.epoch, close_owned_window = function() return host.hide() end }
		local state = { webview_manager = host }
		local ready = bridge.on_message({ action = "ready" }, state, context)
		assert(ready.pushed == true)
		local payload = { action = "save", edit_id = ready.data.edit_id, epoch = ready.data.epoch,
			name = ready.data.name, prompt = ready.data.prompt, batch = ready.data.mode == "batch" }
		return payload, function() return bridge.on_message(payload, state, context) end
	end
	function f.disk(id)
		-- A fresh settings instance must observe the same registry as the live one.
		local fresh = helpers.load_module("modules.llm.profile_settings")
		local persisted = assert(fresh.resolve_id(id))
		helpers.assert_eq(persisted, assert(profiles.resolve_id(id)))
		assert(read():find("keep = 'sentinel'", 1, true), "unrelated TOML bytes were changed")
		return persisted
	end
	local ok, err = pcall(body, f)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	local staging = uv.fs_lstat(path .. ".tmp")
	if staging then
		if staging.type == "directory" then assert(uv.fs_rmdir(path .. ".tmp")) else assert(os.remove(path .. ".tmp")) end
	end
	assert(os.remove(path)); assert(uv.fs_rmdir(dir))
	if not ok then error(err, 0) end
end

local function hidden_equal(actual, expected)
	helpers.assert_eq(actual.system_multi, expected.system_multi)
	helpers.assert_eq(actual.system_multi_template, expected.system_multi_template)
	helpers.assert_eq(actual.stop_sequences, expected.stop_sequences)
	if expected.stop_sequences then helpers.assert_eq(Json.is_array(actual.stop_sequences), true) end
end

helpers.describe("prompt editor profile round trips", function()
	helpers.it("renames a stored profile without losing its hidden options", function()
		with_editor(function(f)
			local original = f.seed()
			local payload, save = f.open(original)
			payload.name = "Renamed only"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.label, payload.name)
			hidden_equal(saved, original)
		end)
	end)

	helpers.it("edits the normal prompt and batch mode while retaining hidden options", function()
		with_editor(function(f)
			local original = f.seed()
			local payload, save = f.open(original)
			payload.prompt, payload.batch = "  New {context}  ", true
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.system_single, "New {context}")
			helpers.assert_eq(saved.batch, true)
			hidden_equal(saved, original)
		end)
	end)

	helpers.it("clones a profile under a new identity without altering the original", function()
		with_editor(function(f)
			local original = f.seed()
			local payload, save = f.open(original, { as_new = true, profile_id = "user_clone" })
			payload.name = "Clone"
			helpers.assert_eq(save(), { saved = true, closed = true })
			hidden_equal(f.disk("user_clone"), original)
			helpers.assert_eq(f.disk(original.id), original)
		end)
	end)

	helpers.it("snapshots the seed arrays before callers can mutate them", function()
		with_editor(function(f)
			local seed = f.seed()
			local expected = f.profiles.resolve_id(seed.id)
			local _, save = f.open(seed)
			seed.stop_sequences[1], seed.system_multi = "MUTATED", "Changed after opening"
			helpers.assert_eq(save(), { saved = true, closed = true })
			hidden_equal(f.disk(seed.id), expected)
		end)
	end)

	helpers.it("detaches each retry candidate from a callback that mutates and refuses it", function()
		with_editor(function(f)
			local original, attempts = f.seed(), 0
			local _, save = f.open(original, nil, function(candidate)
				attempts = attempts + 1
				if attempts == 1 then candidate.stop_sequences[1] = "CORRUPTED"; return false end
				return f.profiles.save_user_profile(candidate, false, true)
			end)
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(save(), { saved = true, closed = true })
			helpers.assert_eq(attempts, 2)
			hidden_equal(f.disk(original.id), original)
		end)
	end)

	helpers.it("retains a typed empty stop sequence list", function()
		with_editor(function(f)
			local original = f.seed({ stop_sequences = Json.array({}) })
			local _, save = f.open(original)
			helpers.assert_eq(save(), { saved = true, closed = true })
			hidden_equal(f.disk(original.id), original)
		end)
	end)

	helpers.it("shows the active raw prompt and preserves it verbatim on a rename", function()
		with_editor(function(f)
			local original = f.seed({ raw_prompt = "  Raw {context}\n" })
			local payload, save = f.open(original)
			helpers.assert_eq(payload.prompt, original.raw_prompt)
			payload.name = "Renamed raw"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.raw_prompt, original.raw_prompt)
			helpers.assert_eq(saved.system_single, original.system_single)
			hidden_equal(saved, original)
		end)
	end)

	helpers.it("edits the active raw prompt instead of preserving a stale override", function()
		with_editor(function(f)
			local original = f.seed({ raw_prompt = "Original raw" })
			local payload, save = f.open(original)
			payload.prompt = "  Edited {context}\n"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.raw_prompt, payload.prompt)
			helpers.assert_eq(saved.system_single, original.system_single)
			helpers.assert_eq(require("llm.profile_selector").resolve_system_prompt(saved, { context = "EXPANDED" }).system, payload.prompt)
			hidden_equal(saved, original)
		end)
	end)

	helpers.it("clones an active raw prompt with detached hidden settings", function()
		with_editor(function(f)
			local original = f.seed({ raw_prompt = "Original raw" })
			local payload, save = f.open(original, { as_new = true, profile_id = "user_raw_clone" })
			payload.prompt = "Clone raw"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk("user_raw_clone")
			helpers.assert_eq(saved.raw_prompt, payload.prompt)
			helpers.assert_eq(saved.system_single, original.system_single)
			hidden_equal(saved, original)
			helpers.assert_eq(f.disk(original.id), original)
		end)
	end)

	helpers.it("keeps an explicit empty raw override inactive when editing a normal prompt", function()
		with_editor(function(f)
			local original = f.seed({ raw_prompt = "" })
			local payload, save = f.open(original)
			payload.prompt = "Normal edit"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.raw_prompt, "")
			helpers.assert_eq(saved.system_single, payload.prompt)
		end)
	end)

	helpers.it("keeps a real staging refusal retryable without changing the profile or source", function()
		with_editor(function(f)
			local original = f.seed()
			local payload, save = f.open(original)
			payload.name = "Retry after filesystem refusal"
			local bytes = f.read()
			assert(uv.fs_mkdir(f.path .. ".tmp", 448))
			helpers.assert_eq(save(), { saved = false, closed = false })
			helpers.assert_eq(f.read(), bytes)
			helpers.assert_eq(f.profiles.resolve_id(original.id), original)
			helpers.assert_eq(f.seen.closes, 0)
			assert(uv.fs_rmdir(f.path .. ".tmp"))
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk(original.id)
			helpers.assert_eq(saved.label, payload.name)
			hidden_equal(saved, original)
		end)
	end)

	helpers.it("cancels an edited profile without writing its draft", function()
		with_editor(function(f)
			local original = f.seed()
			local payload, save = f.open(original)
			local bytes = f.read()
			payload.action, payload.prompt = "cancel", "Discarded"
			helpers.assert_eq(save(), { cancelled = true, closed = true })
			helpers.assert_eq(f.read(), bytes)
			helpers.assert_eq(f.disk(original.id), original)
		end)
	end)

	helpers.it("creates a fresh profile without inventing hidden raw or stop options", function()
		with_editor(function(f)
			local payload, save = f.open(nil, { profile_id = "user_fresh" })
			payload.name, payload.prompt = "Fresh", "New normal"
			helpers.assert_eq(save(), { saved = true, closed = true })
			local saved = f.disk("user_fresh")
			helpers.assert_eq(saved.raw_prompt, nil)
			helpers.assert_eq(saved.stop_sequences, nil)
			helpers.assert_eq(saved.system_single, payload.prompt)
		end)
	end)
end)
