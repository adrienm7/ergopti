--- tests/support/agent_world.lua

--- ==============================================================================
--- MODULE: AI Agent World
--- DESCRIPTION:
--- Builds the real agent pipeline of the macOS driver around faked boundaries:
--- the gesture action registry, agent runner, shared agent logic, prediction
--- engine and remote backend (Cerebras, OpenAI dialect) are real; the HTTP
--- transport (captured, answered with canned bodies), the selection reader,
--- the command dialog, the connectors, the clock, the time zone, the focused
--- window and the tooltip canvas are faked. Labels and notices are read from
--- the real French catalogue.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local shared_lua = helpers.shared("lua/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path

local M = {}

local ENTRY_ID = "agent-cerebras"
M.MODEL = "qwen-3.8-27b"
local MODEL = M.MODEL
M.SELECTION = "On se voit jeudi 14h avec Paul pour le devis"
local SELECTION = M.SELECTION
-- Tuesday 29 September 2026, 10:30 in the machine's local time
M.NOW = os.time({ year = 2026, month = 9, day = 29, hour = 10, min = 30, sec = 0 })

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(helpers.shared(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

M.CONFIG = read_json("modules/llm/agent.json")

--- Returns one named closure upvalue.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value, number|nil index
function M.get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Encodes an OpenAI-dialect chat completion carrying one answer.
--- @param content string
--- @return string body
function M.completion_body(content)
	return json.encode({
		id = "chatcmpl-agent", object = "chat.completion",
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
	})
end

--- Builds the real pipeline around the faked boundaries.
--- @param options table|nil { system1, system2, mode, selection }.
--- @return table world
function M.build_world(options)
	options = options or {}
	local world = {
		posts = {}, notices = {}, renders = {}, loadings = 0, hides = 0, runs = {}, dialogs = {},
		selection = options.selection == nil and SELECTION or options.selection,
		dialog_answer = { "OK", "" },
		-- The local server's listing requests, the alerts and the button the
		-- user presses ("first" or the second), the notifications, the
		-- downloads the local-model owner asked for, and every log line
		gets = {}, alerts = {}, alert_answer = nil, notifications = {}, installs = {}, logs = {},
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	local _gestures = helpers.load_with_stubs("modules.gestures")
	world.actions = require("modules.gestures.actions")
	world.actions.init({ action_params = {} })
	local logger = helpers.make_logger_stub()
	for _, level in ipairs({ "debug", "info", "start", "success", "warn", "error" }) do
		logger[level] = function(_, message, ...)
			local ok, text = pcall(string.format, tostring(message), ...)
			world.logs[#world.logs + 1] = { level = level, text = ok and text or tostring(message) }
		end
	end
	package.loaded["infra.logger"] = logger

	local hs_stub = _G.hs
	local front_app = {
		title = function() return "Notes" end, name = function() return "Notes" end,
		bundleID = function() return "com.apple.Notes" end, path = function() return "/System/Applications/Notes.app" end,
		pid = function() return 7 end,
	}
	hs_stub.application = hs_stub.application or {}
	hs_stub.application.frontmostApplication = function() return front_app end

	for _, name in ipairs({
		"modules.llm", "modules.llm.profiles", "modules.llm.api_remote", "modules.llm.api_ollama",
		"modules.llm.api_mlx", "modules.llm.parser", "modules.llm.prompt_builder",
		"modules.llm.streaming_handler", "modules.llm.warmup_controller", "modules.llm.app_filter",
		"modules.llm.api_common", "modules.llm.prediction_engine", "modules.llm.progressive_reveal",
		"modules.llm.agent_runner", "modules.llm.agent_learning",
	}) do
		package.loaded[name] = nil
	end
	package.loaded["adapters.window_info"] = {
		focused_identity = function() return "7:101" end,
		getFocused = function()
			return { appId = "Notes", windowTitle = "Réunion devis", bundleId = "com.apple.Notes", executablePath = "" }
		end,
		getAll = function() return {} end,
	}
	package.loaded["adapters.system_info"] = { time_zone = function() return "Europe/Paris" end }
	package.loaded["modules.keymap.utils"] = { is_ignored_window = function() return false end }
	package.loaded["modules.shortcuts.script_control"] = nil
	package.loaded["modules.keylogger"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() end, log_llm_failed = function() end,
		log_llm_suggested = function() end, log_llm_dismissed = function() end,
	}
	package.loaded["modules.shortcuts.actions.text"] = {
		read_copied_selection = function(_, on_selection, on_empty)
			world.reads = (world.reads or 0) + 1
			if world.selection == "" then on_empty() else on_selection(world.selection) end
			return true
		end,
	}
	package.loaded["infra.dialog_util"] = {
		text_prompt = function(title, message, default, ok_label, cancel_label)
			world.dialogs[#world.dialogs + 1] = { title = title, message = message, default = default,
				ok = ok_label, cancel = cancel_label }
			local button = world.dialog_answer[1] == "OK" and ok_label or cancel_label
			return button, world.dialog_answer[2]
		end,
		block_alert = function(title, message, first, second, style)
			world.alerts[#world.alerts + 1] = { title = title, message = message, buttons = { first, second },
				style = style }
			return world.alert_answer == "first" and first or second
		end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, kind, on_click)
			world.notifications[#world.notifications + 1] = { title = title, body = body, kind = kind,
				on_click = on_click }
			return true
		end,
		debugLog = function() end,
	}
	package.loaded["modules.llm.agent_connectors"] = {
		run = function(action, on_done)
			world.runs[#world.runs + 1] = { action = action, on_done = on_done }
			return true
		end,
		list_tools = function(_, on_done)
			on_done({ "Mode focus" })
			return true
		end,
		open_automation_settings = function()
			world.settings_opened = true
			return true
		end,
	}
	package.loaded["ui.tooltip"] = {
		set_navigate_callback = function() end,
		set_enter_validates = function() end,
		set_llm_timeout = function() end,
		set_chain_start = function() return true end,
		show_loading = function() world.loadings = world.loadings + 1; return true end,
		show = function(content) world.notices[#world.notices + 1] = content; return true end,
		show_predictions = function(predictions, _, _, _, _, _, _, _, loading_text, slots)
			local texts = {}
			for index, prediction in ipairs(predictions) do texts[index] = prediction.to_type end
			world.renders[#world.renders + 1] = { texts = texts, loading = loading_text, slots = slots }
			return true
		end,
		is_hotstring_visible = function() return world.hotstring_visible == true end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		tint = function() return {} end,
		hide = function() world.hides = world.hides + 1; return true end,
		hide_forced_silent = function() world.hides = world.hides + 1; return true end,
	}
	-- The harness's i18n stub echoes keys: the labels and notices are read from
	-- the real French catalogue instead, so their arguments are compared too
	local i18n = require("infra.i18n")
	local Locale = require("infra.locale")
	Locale.set_locale("fr")
	i18n.get_locale = function() return "fr" end
	i18n.get = function(key)
		local text = Locale.get(key)
		if text == nil or text == "" then return key end
		return text
	end
	i18n.format = function(key, ...)
		local text = i18n.get(key)
		local args = table.pack(...)
		for n = 1, args.n do text = text:gsub("{" .. n .. "}", (tostring(args[n]):gsub("%%", "%%%%"))) end
		return text
	end
	world.i18n = i18n

	local core = require("modules.llm")
	local CoreState = M.get_upvalue(core.get_active_profile, "CoreState")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "agent-token", model = MODEL } })
	api.set_active_entry_id(ENTRY_ID)
	local _, ready_index = M.get_upvalue(api.is_ready, "_is_ready")
	debug.setupvalue(api.is_ready, ready_index, true)
	local client = M.get_upvalue(api.request_chat, "_vision_client")
	assert(type(client) == "table", "the remote chat client must be reachable")
	client.post = function(url, headers, body, callback)
		world.posts[#world.posts + 1] = { url = url, headers = headers, body = json.decode(body), callback = callback }
		return true
	end

	local local_client = M.get_upvalue(require("modules.llm.api_ollama").request_chat, "_vision_client")
	assert(type(local_client) == "table", "the local chat client must be reachable")
	local_client.post = function(url, headers, body, callback)
		world.posts[#world.posts + 1] = { url = url, headers = headers, body = json.decode(body), callback = callback }
		return true
	end
	local_client.get = function(url, headers, callback)
		world.gets[#world.gets + 1] = { url = url, headers = headers, callback = callback }
		return true
	end
	-- The AI menu registers the owner of model downloads; this world records them
	local ok_offer, offer = pcall(require, "modules.llm.local_model_offer")
	if ok_offer and type(offer) == "table" and type(offer.set_installer) == "function" then
		offer.set_installer(function(model, on_done)
			world.installs[#world.installs + 1] = { model = model, on_done = on_done }
			return true
		end)
	end

	local engine = require("modules.llm.prediction_engine")
	world.engine = engine
	engine.init({
		buffer = "", llm_buffer = "", mappings = {}, DELAYS = { llm_prediction = 1 },
		ignored_window_titles = {}, ignored_window_patterns = {}, suppress_rescan_keep_buffer = function() end,
	})
	engine.set_llm_enabled(true)
	local runner = require("modules.llm.agent_runner")
	world.runner = runner
	runner.set_clock(function() return M.NOW end)
	helpers.assert_eq(runner.set_mode(options.mode or "action"), true)
	helpers.assert_eq(runner.set_system2(options.system2 == nil and "cerebras" or options.system2), true)
	if options.system1 then helpers.assert_eq(runner.set_system1(options.system1), true) end
	world.timer_baseline = #hs_stub.timer.__timers
	package.loaded["modules.keymap"] = {
		request_agent_selection = function(parent) return runner.run_selection(parent) end,
		request_agent_command = function() return runner.run_command() end,
		toggle_agent_auto = function() return runner.toggle_auto() end,
	}
	return world
end

--- Fires every pending timer of the actions, in order.
--- @param world table
function M.settle(world)
	local timers = _G.hs.timer.__timers
	local progressed = true
	while progressed do
		progressed = false
		for index = world.timer_baseline + 1, #timers do
			local timer = timers[index]
			if timer.running and timer.fired == 0 and (tonumber(timer.delay) or 0) < 1.5 then
				timer:fire()
				progressed = true
				break
			end
		end
	end
end

--- Runs an action as the gesture registry dispatches it.
--- @param world table
--- @param id string Action id.
--- @return boolean started
function M.trigger(world, id)
	local started = world.actions.execute_single(id, "tap_3")
	M.settle(world)
	return started
end

--- Answers the local server's pending model listing, if a request asked for
--- one, with these installed models.
--- @param world table
--- @param names table Installed model names.
--- @return boolean answered
function M.list_local_models(world, names)
	local pending = world.gets[#world.gets]
	if not pending or pending.answered then return false end
	pending.answered = true
	local models = {}
	for index, name in ipairs(names) do models[index] = { name = name, model = name } end
	pending.callback({ ok = true, status = 200, body = json.encode({ models = json.array(models) }), headers = {} })
	return true
end

--- Tells whether a log line of a level holds a text.
--- @param world table
--- @param level string|nil nil for any level.
--- @param text string
--- @return boolean
function M.logged(world, level, text)
	for _, line in ipairs(world.logs) do
		if (level == nil or line.level == level) and line.text:find(text, 1, true) then return true end
	end
	return false
end

--- Answers one captured request as the provider would.
function M.answer(post, content)
	post.callback({ ok = true, status = 200, body = M.completion_body(content), headers = {} })
end

M.TWO_ACTIONS = 'ACTIONS: [{"type":"calendar","title":"Devis avec Paul","start":"2026-10-01T14:00"},'
	.. '{"type":"mail","to":["paul@example.com"],"subject":"Devis","body":"Bonjour Paul"}]'

--- Accepts candidate `index` as the keymap bridge does.
--- @return boolean applied
function M.accept(world, index)
	local prediction = world.engine.consume(index)
	helpers.assert_true(prediction ~= nil, "a candidate to accept")
	helpers.assert_eq(type(prediction.on_accept), "function", "the candidate runs its own action")
	return prediction.on_accept(prediction.to_type)
end

return M
