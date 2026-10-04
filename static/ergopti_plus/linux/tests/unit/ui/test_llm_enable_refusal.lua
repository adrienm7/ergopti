--- tests/unit/ui/test_llm_enable_refusal.lua

--- ==============================================================================
--- MODULE: Local AI Enable Refusal UI
--- DESCRIPTION:
--- Acknowledges the actual origin through the existing native modal owner;
--- refused keyboard release cannot launch the dialog or install anything.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Paths = require("infra.paths")
local Shell = require("adapters.shell_runner")
local file = assert(io.open(Paths.shared("data/locales/en.json"), "rb"))
local labels = assert(Json.decode_lossless(file:read("*a")))
file:close()

local function with_notice(tool, body)
	local names = { "infra.i18n", "adapters.shell_runner", "adapters.keyboard_hook",
		"adapters.notifier", "ui.llm_enable_refusal", "window_titles" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local world = { order = {}, commands = {}, notifications = {}, captions = {}, release_ok = true, restore_ok = true }
	package.loaded["window_titles"] = { compose = function(caption)
		world.captions[#world.captions + 1] = caption
		world.composed_title = "Caption policy % ' — " .. caption
		return world.composed_title
	end }
	package.loaded["infra.i18n"] = { get = function(key) return assert(labels[key], key) end }
	package.loaded["adapters.shell_runner"] = {
		has_command = function(name) return name == tool end,
		quote = Shell.quote,
		exec_checked = function(command)
			world.order[#world.order + 1] = "dialog"
			world.commands[#world.commands + 1] = command
			return world.command_ok ~= false, world.answer
		end,
	}
	package.loaded["adapters.keyboard_hook"] = { while_released = function(callback, options)
		world.order[#world.order + 1] = "release"
		world.observer = type(options) == "table" and options.observer
		if not world.release_ok then
			if world.observer then world.observer("refused", { ok = false, reason = "release_failed" }) end
			return callback()
		end
		local result, answer = callback()
		world.order[#world.order + 1] = "restore"
		if world.observer then
			if world.restore_ok then world.observer("after", { ok = true })
			else world.observer("refused", { ok = false, reason = "regrab_failed" }) end
		end
		-- Production returns the dialog choice even when native restoration refuses.
		return result, answer
	end }
	package.loaded["adapters.notifier"] = { send = function(message, options)
		world.notifications[#world.notifications + 1] = { message, options }; return true
	end }
	package.loaded["ui.llm_enable_refusal"] = nil
	world.notice = require("ui.llm_enable_refusal")
	local ok, err = xpcall(function() body(world) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("AI refusal notice", function()
	for _, tool in ipairs({ "zenity", "kdialog" }) do
		helpers.it("requires an explicit restored replacement choice in " .. tool .. " (ai-enable-admission)", function()
			with_notice(tool, function(world)
				local opaque = {}
				local label = "Use LM Studio (model:2b, 127.0.0.1:1234) 50%'"
				world.answer = "replacement_1\n"
				local shown, retry, chosen = world.notice.show("http://127.0.0.1:11434", { { label = label, value = opaque } })
				helpers.assert_true(shown)
				helpers.assert_eq(retry, false)
				helpers.assert_eq(chosen, opaque)
				helpers.assert_eq(world.order, { "release", "dialog", "restore" })
				helpers.assert_true(world.commands[1]:find(Shell.quote(label), 1, true) ~= nil)
				world.restore_ok = false
				local _, _, refused = world.notice.show("http://127.0.0.1:11434", { { label = label, value = opaque } })
				helpers.assert_nil(refused)
			end)
		end)
	end

	helpers.it("does not infer replacement consent from retry or malformed native output (ai-enable-admission)", function()
		with_notice("zenity", function(world)
			local replacements = { { label = "Use LM Studio", value = {} } }
			for _, answer in ipairs({ "retry\n", "replacement_9\n", "replacement_1\nforeign", "" }) do
				world.answer = answer
				local shown, retry, chosen = world.notice.show("http://127.0.0.1:11434", replacements)
				helpers.assert_true(shown)
				helpers.assert_eq(retry, answer == "retry\n")
				helpers.assert_nil(chosen)
			end
		end)
	end)
	for _, tool in ipairs({ "zenity", "kdialog" }) do
		helpers.it("names and quotes the configured origin in " .. tool .. " (ai-enable-admission)", function()
			with_notice(tool, function(world)
				local origin = "http://127.0.0.1:11434/?label=50%' quoted"
				local shown, retry = world.notice.show(origin)
				helpers.assert_true(shown)
				helpers.assert_true(retry)
				helpers.assert_eq(world.order, { "release", "dialog", "restore" })
				helpers.assert_eq(#world.commands, 1)
				helpers.assert_eq(world.captions, { "Ollama is not answering" })
				local title_flag = tool == "zenity" and "--title=" or "--title "
				helpers.assert_true(world.commands[1]:find(title_flag .. Shell.quote(world.composed_title), 1, true) ~= nil)
				local expected = "The AI stays off: Ollama is not answering at " .. origin
					.. ". Start the server, then try enabling the AI again."
				helpers.assert_true(world.commands[1]:find(Shell.quote(expected), 1, true) ~= nil)
				helpers.assert_true(world.commands[1]:find(Shell.quote(labels["llm.unreachable.keep_off"]), 1, true) ~= nil)
				helpers.assert_true(world.commands[1]:find(Shell.quote(labels["button.retry"]), 1, true) ~= nil)
				helpers.assert_eq(#world.notifications, 0)
			end)
		end)
	end

	helpers.it("does not launch a dialog after native keyboard release refusal (ai-enable-admission)", function()
		with_notice("zenity", function(world)
			world.release_ok = false
			local shown, retry = world.notice.show("http://127.0.0.1:11434")
			helpers.assert_eq(shown, false)
			helpers.assert_eq(retry, false)
			helpers.assert_eq(world.order, { "release" })
			helpers.assert_eq(type(world.observer), "function")
			helpers.assert_eq(#world.commands, 0)
		end)
	end)

	helpers.it("reports refused restoration instead of claiming the acknowledgement settled (ai-enable-admission)", function()
		with_notice("zenity", function(world)
			world.restore_ok = false
			local shown, retry = world.notice.show("http://127.0.0.1:11434")
			helpers.assert_eq(shown, false)
			helpers.assert_eq(retry, false)
			helpers.assert_eq(world.order, { "release", "dialog", "restore" })
			helpers.assert_eq(type(world.observer), "function")
		end)
	end)


	for _, tool in ipairs({ "zenity", "kdialog" }) do
		helpers.it("keeps the AI off when the user declines " .. tool .. " retry (ai-enable-admission)", function()
			with_notice(tool, function(world)
				world.command_ok = false
				local shown, retry = world.notice.show("http://127.0.0.1:11434")
				helpers.assert_eq(shown, false)
				helpers.assert_eq(retry, false)
				helpers.assert_eq(world.order, { "release", "dialog", "restore" })
				helpers.assert_eq(#world.commands, 1)
			end)
		end)
	end

	helpers.it("keeps a visible address explanation without a native dialog package (ai-enable-admission)", function()
		with_notice(nil, function(world)
			local origin = "http://127.0.0.1:21434"
			local shown, retry = world.notice.show(origin)
			helpers.assert_true(shown)
			helpers.assert_eq(retry, false)
			helpers.assert_eq(#world.commands, 0)
			helpers.assert_eq(#world.notifications, 1)
			helpers.assert_true(world.notifications[1][1]:find(origin, 1, true) ~= nil)
		end)
	end)
end)
