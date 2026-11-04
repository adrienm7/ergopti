--- tests/unit/ui/editors/prompt_editor/test_save_errors.lua

--- ==============================================================================
--- MODULE: Prompt Editor Save Error Ownership (Linux)
--- DESCRIPTION:
--- Real profile storage refusals must request a visible error while preserving
--- the current editor draft. Retired pages must never notify for a successor.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs an isolated editor against real profile persistence in a private file.
--- @param body function
--- @param logger table|nil A fresh canonical logger for native sink reentry.
local function with_editor(body, logger)
	-- Load real transitives before replacing the one configuration-path owner.
	require("infra.llm_preferences")
	require("modules.llm.profile_settings")
	local names = {
		"infra.config_paths", "infra.llm_preferences", "modules.llm.profile_settings",
		"ui.webview_manager", "ui.prompt_editor.bridge", "logger.shim",
	}
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local path = os.tmpname()
	local function put(bytes)
		local file = assert(io.open(path, "wb")); assert(file:write(bytes)); assert(file:close())
	end
	local function read()
		local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); assert(file:close()); return bytes
	end
	put("")
	local paths = {}
	for key, value in pairs(previous["infra.config_paths"]) do paths[key] = value end
	paths.config = function() return path end
	package.loaded["infra.config_paths"] = paths
	if logger then package.loaded["logger.shim"] = logger end
	local profiles = helpers.load_module("modules.llm.profile_settings")
	package.loaded["infra.llm_preferences"] = nil
	local seen = { epoch = 0, visible = false, notices = {}, candidates = {}, closes = 0 }
	local manager = {
		show = function() seen.epoch = seen.epoch + 1; seen.visible = true; return true end,
		hide = function() seen.closes = seen.closes + 1; seen.visible = false; return true end,
		is_visible = function() return seen.visible end,
		current_epoch = function() return seen.visible and seen.epoch or nil end,
		page_current = function(_, epoch) return seen.visible and epoch == seen.epoch end,
		eval_js = function() return true end,
	}
	package.loaded["ui.webview_manager"] = manager
	local bridge = helpers.load_module("ui.prompt_editor.bridge")
	local state = { webview_manager = manager, notify_error = function(key)
		seen.notices[#seen.notices + 1] = key
		if seen.on_notice then seen.on_notice() end
	end }
	local fixture = { bridge = bridge, profiles = profiles, seen = seen, state = state, host = manager, put = put, read = read }
	fixture.persist = function(candidate)
		seen.candidates[#seen.candidates + 1] = candidate
		return profiles.save_user_profile(candidate, true, false)
	end
	fixture.open = function(saver, profile_id)
		assert(bridge.open(nil, saver or fixture.persist, { profile_id = profile_id or "user_save_fixture" }))
		local epoch = seen.epoch
		local context = { app_name = "prompt_editor", epoch = epoch, close_owned_window = function()
			if not manager.page_current("prompt_editor", epoch) then return false end
			return manager.hide("prompt_editor")
		end }
		local ready = bridge.on_message({ action = "ready" }, state, context)
		local payload = { action = "save", edit_id = ready.data.edit_id, epoch = ready.data.epoch,
			name = "Edited profile", prompt = "Continue {context} carefully", batch = false }
		return payload, context
	end
	fixture.save = function(payload, context) return bridge.on_message(payload, state, context) end
	local ok, err = pcall(body, fixture)
	if logger then logger.set_sink(nil) end
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	assert(os.remove(path))
	if not ok then error(err, 0) end
end

helpers.describe("prompt editor save error ownership", function()
	helpers.it("reports a real outdated profile registry without changing its bytes", function()
		with_editor(function(f)
			local original = "[llm]\nuser_profiles = []\n"
			f.put(original)
			local payload, context = f.open()
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.read(), original)
			helpers.assert_eq(f.seen.notices, { "prompt_editor.save_failed" })
			helpers.assert_eq(f.bridge.is_open(), true)
			helpers.assert_eq(f.seen.visible, true)
			helpers.assert_eq(f.seen.closes, 0)
		end)
	end)

	helpers.it("reports a real source conflict and retries the unchanged draft successfully", function()
		with_editor(function(f)
			f.put("# original source\n")
			f.profiles.list_user()
			local payload, context = f.open()
			f.put("# concurrent edit remains\n")
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.read(), "# concurrent edit remains\n")
			helpers.assert_eq(f.bridge.is_open(), true)
			helpers.assert_eq(f.save(payload, context), { saved = true, closed = true })
			helpers.assert_eq(f.seen.notices, { "prompt_editor.save_failed" })
			helpers.assert_eq(#f.seen.candidates, 2)
			helpers.assert_eq(f.seen.candidates[1], f.seen.candidates[2])
			helpers.assert_eq(f.profiles.list_user()[1].system_single, payload.prompt)
			helpers.assert_eq(f.seen.visible, false)
		end)
	end)

	helpers.it("saves a fresh profile and closes without an error notification", function()
		with_editor(function(f)
			local payload, context = f.open()
			helpers.assert_eq(f.save(payload, context), { saved = true, closed = true })
			helpers.assert_eq(f.profiles.list_user()[1].label, payload.name)
			helpers.assert_eq(f.seen.notices, {})
			helpers.assert_eq(f.bridge.is_open(), false)
		end)
	end)

	helpers.it("reports an exception from persistence and keeps the draft retryable", function()
		with_editor(function(f)
			local attempts = 0
			local payload, context = f.open(function(candidate)
				attempts = attempts + 1
				if attempts == 1 then error("inert storage failure") end
				return f.persist(candidate)
			end)
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.save(payload, context), { saved = true, closed = true })
			helpers.assert_eq(f.seen.notices, { "prompt_editor.save_failed" })
		end)
	end)

	helpers.it("ignores a save from the replaced page without notifying its successor", function()
		with_editor(function(f)
			local old, old_context = f.open()
			local current, current_context = f.open()
			helpers.assert_eq(f.save(old, old_context), nil)
			helpers.assert_eq(f.seen.notices, {})
			helpers.assert_eq(#f.seen.candidates, 0)
			helpers.assert_eq(f.save(current, current_context), { saved = true, closed = true })
		end)
	end)

	helpers.it("does not notify after the native page closes during persistence", function()
		with_editor(function(f)
			local payload, context = f.open(function() f.host.hide("prompt_editor"); return false end)
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.seen.notices, {})
			helpers.assert_eq(f.seen.visible, false)
		end)
	end)

	helpers.it("does not notify for a session replaced while its saver returns", function()
		with_editor(function(f)
			local payload, context = f.open(function() f.open(); return false end)
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.seen.notices, {})
			helpers.assert_eq(f.seen.visible, true)
			helpers.assert_eq(f.seen.epoch, 2)
		end)
	end)

	helpers.it("rechecks native page ownership after the real error logger sink", function()
		local logger = dofile(helpers.driver_root() .. "/../_shared/lua/logger/init.lua")
		with_editor(function(f)
			local warnings = 0
			local payload, context = f.open(function() return false end)
			logger.set_sink(function(line)
				if not line:find("Prompt editor save was refused", 1, true) then return end
				warnings = warnings + 1
				f.open()
			end)
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(warnings, 1)
			helpers.assert_eq(f.seen.notices, {})
			helpers.assert_eq(f.seen.epoch, 2)
		end, logger)
	end)

	helpers.it("contains notifier failure without closing the draft or blocking a retry", function()
		with_editor(function(f)
			local attempts = 0
			f.seen.on_notice = function() error("inert notification failure") end
			local payload, context = f.open(function(candidate)
				attempts = attempts + 1
				return attempts > 1 and f.persist(candidate) or false
			end)
			helpers.assert_eq(f.save(payload, context), { saved = false, closed = false })
			helpers.assert_eq(f.save(payload, context), { saved = true, closed = true })
			helpers.assert_eq(f.seen.notices, { "prompt_editor.save_failed" })
		end)
	end)

	helpers.it("(editor-close-successor) retains the real draft opened during native close", function()
		with_editor(function(f)
			local original, original_context = f.open()
			local successor, successor_context
			local hide = f.host.hide
			f.host.hide = function(...)
				local closed = hide(...)
				f.host.hide = hide
				successor, successor_context = f.open(nil, "user_successor_fixture")
				successor.name, successor.prompt = "Successor profile", "Keep this later draft"
				return closed
			end
			helpers.assert_eq(f.save(original, original_context), { saved = true, closed = true })
			helpers.assert_eq(f.bridge.is_open(), true, "the acknowledged old close cannot forget its successor")
			helpers.assert_eq(f.seen.visible, true)
			helpers.assert_eq(f.seen.epoch, 2)
			helpers.assert_eq(f.seen.closes, 1)
			helpers.assert_eq(f.save(original, original_context), nil, "the old page cannot resubmit into the successor")
			helpers.assert_eq(f.save(successor, successor_context), { saved = true, closed = true })
			local stored = assert(f.profiles.resolve_id("user_successor_fixture"))
			helpers.assert_eq(stored.label, successor.name)
			helpers.assert_eq(stored.system_single, successor.prompt)
			helpers.assert_eq(#f.profiles.list_user(), 2, "both distinct committed profiles remain readable")
			helpers.assert_eq(#f.seen.candidates, 2)
			helpers.assert_eq(f.seen.closes, 2)
			helpers.assert_eq(f.bridge.is_open(), false)
		end)
	end)

	helpers.it("(editor-close-successor) cancellation preserves the later profile save", function()
		with_editor(function(f)
			local original, original_context = f.open()
			local successor, successor_context
			local hide = f.host.hide
			f.host.hide = function(...)
				local closed = hide(...)
				f.host.hide = hide
				successor, successor_context = f.open()
				return closed
			end
			local response = f.bridge.on_message({ action = "cancel", edit_id = original.edit_id,
				epoch = original.epoch }, f.state, original_context)
			helpers.assert_eq(response, { cancelled = true, closed = true })
			helpers.assert_eq(#f.seen.candidates, 0, "cancellation cannot publish a profile")
			helpers.assert_eq(f.bridge.is_open(), true)
			helpers.assert_eq(f.seen.visible, true)
			helpers.assert_eq(f.save(successor, successor_context), { saved = true, closed = true })
			helpers.assert_eq(#f.seen.candidates, 1)
			helpers.assert_eq(f.profiles.list_user()[1].label, successor.name)
			helpers.assert_eq(f.seen.closes, 2)
		end)
	end)

	helpers.it("(editor-close-successor) an older replacement opener yields to native close reentry", function()
		with_editor(function(f)
			f.open()
			local successor, successor_context
			local hide = f.host.hide
			f.host.hide = function(...)
				local closed = hide(...)
				f.host.hide = hide
				successor, successor_context = f.open(nil, "user_later_native")
				return closed
			end
			local accepted = f.bridge.open(nil, function() error("superseded saver must not run") end,
				{ profile_id = "user_earlier_request" })
			helpers.assert_eq(accepted, false, "a later request supersedes the opener that caused native close")
			helpers.assert_eq(f.seen.epoch, 2, "the superseded opener cannot create a third window")
			helpers.assert_eq(f.save(successor, successor_context), { saved = true, closed = true })
			helpers.assert_eq(f.profiles.list_user()[1].id, "user_later_native")
		end)
	end)

	helpers.it("(editor-close-successor) an older native show cannot claim a later editor", function()
		with_editor(function(f)
			local successor, successor_context
			local show = f.host.show
			f.host.show = function(...)
				local shown = show(...)
				f.host.show = show
				successor, successor_context = f.open(nil, "user_later_show")
				return shown
			end
			local accepted = f.bridge.open(nil, function() error("superseded saver must not run") end,
				{ profile_id = "user_earlier_request" })
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(f.seen.epoch, 2)
			helpers.assert_eq(f.save(successor, successor_context), { saved = true, closed = true })
			helpers.assert_eq(f.profiles.list_user()[1].id, "user_later_show")
		end)
	end)
end)
