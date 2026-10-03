--- tests/support/agent_scenario.lua

--- ==============================================================================
--- MODULE: AI Agent Test Scenario (Linux)
--- DESCRIPTION:
--- Runs the real prediction engine, agent settings, connectors, learning store,
--- shared agent helpers and remote client (Cerebras, OpenAI dialect) with only
--- the boundaries scripted: the HTTP transport, the API key store, the
--- preferences file, the clock and time zone, the focused window, the text
--- dialog, the selection, the tooltip and the connectors' OS calls (programs,
--- files, the tools folder).
--- ==============================================================================

local M = {}

local Fakes = require("tests.fakes")
local Json = require("json")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

-- The key the user stored for Cerebras
M.ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

-- The request's fixed clock: Tuesday 29 September 2026, 14:05 local time
M.NOW = os.time({ year = 2026, month = 9, day = 29, hour = 14, min = 5, sec = 0 })

-- Modules loaded afresh for each scenario, so they bind the scripted boundaries
local RELOADED = {
	"modules.llm.prediction_engine", "modules.llm.settings", "modules.llm.profile_settings",
	"modules.llm.display_settings", "modules.llm.trigger_settings", "modules.llm.navigation_settings",
	"modules.llm.api_remote", "modules.llm.agent_settings", "modules.llm.agent_connectors",
	"modules.llm.agent_learning", "modules.llm.local_model_probe", "modules.llm.local_model_offer",
}
-- The boundaries a scenario scripts
local FAKED = {
	"adapters.secure_field_detector", "adapters.http_client", "modules.llm.api_entries",
	"modules.llm.profiles", "modules.llm.api_ollama", "adapters.shell_runner",
}

-- The preferences every scenario starts from: the menu's predictions go to the
-- remote API, System 2 is Cerebras and the agent runs on action
local BASE_PREFERENCES = {
	["llm.models.selected"] = "api",
	["llm.profiles.active"] = "basic",
	["llm.profiles.auto_profile_for_model"] = false,
	["llm.trigger.instant_on_word_end"] = false,
	["llm.agent_system2"] = "cerebras",
	["llm.agent_mode"] = "action",
}

--- Runs body against the real engine with scripted boundaries.
--- @param opts table { stored?, selection?, command?, tools?, has_xdg_email?, run_fails?, paused?,
---   disabled?, window?, learning_path?, entries?, active_entry? } stored overrides
---   BASE_PREFERENCES; a stored value of false-y "" is kept. entries are the stored
---   API keys ({ ENTRY } by default); active_entry is the predictions' one (the
---   first entry by default, false for none).
--- @param body function Receives the scenario's world.
function M.run(opts, body)
	local stored = {}
	for key, value in pairs(BASE_PREFERENCES) do stored[key] = value end
	for key, value in pairs(opts.stored or {}) do stored[key] = value end
	PreferencesFixture.with(function(preferences)
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local world = {
			posts = {}, probes = {}, model_offers = {}, model_installs = {}, notices = {}, typed = {}, shown = nil, reads = 0, runs = {}, written = {}, removed = {},
			selection = opts.selection, command = opts.command, dialogs = {}, paused = opts.paused == true,
			tools = opts.tools or { "Envoyer la facture" }, preferences = preferences, buffer = "",
			window = opts.window or { app = "Mail", title = "Re: devis" }, secure = false, preview = false,
			base_url = "http://127.0.0.1:11434",
		}
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function() return world.secure end,
			isSecureApp = function() return false end,
			isUrlBar = function() return false end,
		}
		package.loaded["adapters.http_client"] = {
			get = function(url, headers, options, callback)
				world.probes[#world.probes + 1] = { url = url, options = options, callback = callback }
				return true
			end,
			postStream = function(url, headers, request_body, options, on_chunk, callback)
				world.posts[#world.posts + 1] = { url = url, headers = headers, body = Json.decode(request_body),
					on_chunk = on_chunk, callback = callback }
				return true
			end,
			post = function(url, headers, request_body, callback)
				world.posts[#world.posts + 1] = { url = url, headers = headers, body = Json.decode(request_body),
					callback = callback }
				return true
			end,
			cancel = function()
				world.cancels = (world.cancels or 0) + 1
				return true
			end,
		}
		local entries = opts.entries or { M.ENTRY }
		local active_entry = entries[1]
		if opts.active_entry ~= nil then active_entry = opts.active_entry or nil end
		package.loaded["modules.llm.api_entries"] = {
			active = function() return active_entry end,
			list = function() return entries end,
		}
		local ai_on = opts.disabled ~= true
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return ai_on end,
			get_current_model = function() return "ollama-model" end,
			get_base_url = function() return world.base_url end,
		}
		if opts.local_backend then
			package.loaded["modules.llm.api_ollama"] = nil
		else
			package.loaded["modules.llm.api_ollama"] = {
				chat = function() error("the scenario runs through the API") end,
				cancel = function() return true end,
			}
		end
		require("modules.llm.local_model_offer")._reset_for_test({
			confirm = not opts.native_model_dialog and function(title, text, offer_opts)
				if type(opts.on_model_confirm) == "function" then opts.on_model_confirm(world, offer_opts) end
				world.model_offers[#world.model_offers + 1] = { title = title, text = text }
				return opts.download_choice == true
			end or nil,
			install = function(base_url, model, callback)
				world.model_installs[#world.model_installs + 1] = { base_url = base_url, model = model, callback = callback }
				return true
			end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
		})

		if opts.native_model_dialog then
			package.loaded["adapters.shell_runner"] = {
				has_command = function(command) return command == "zenity" end,
				quote = function(value) return "'" .. value:gsub("'", "'\"'\"'") .. "'" end,
				exec_checked = function(command)
					world.model_offers[#world.model_offers + 1] = { command = command }
					if type(opts.on_model_confirm) == "function" then opts.on_model_confirm(world) end
					return opts.download_choice == true, "", opts.download_choice == true and nil or "command exited with status 1"
				end,
			}
		end

		local scheduler = Fakes.timer_scheduler()
		world.scheduler = scheduler
		local Connectors = require("modules.llm.agent_connectors")
		Connectors._set_deps_for_test({
			run = function(executable, args, options, callback)
				local run = { executable = executable, args = args, timeout_ms = options.timeout_ms, callback = callback }
				world.runs[#world.runs + 1] = run
				if opts.run_fails then return nil, "spawn failed" end
				return { cancel = function() end }
			end,
			has_command = function(name) return name ~= "xdg-email" or opts.has_xdg_email == true end,
			private_dir = function() return "/run/user/1000/ergopti-agent.TEST" end,
			write_file = function(path, content)
				world.written[#world.written + 1] = { path = path, content = content }
				return true
			end,
			remove = function(path)
				world.removed[#world.removed + 1] = path
				return true
			end,
			utc_stamp = function() return "20260929T120500Z" end,
			random_hex = function() return "0123456789abcdef" end,
			tools_dir = function() return "/home/user/.config/ergopti/agent_tools" end,
			list_executables = function() return world.tools end,
			clock = function() return 0 end,
		})
		local learning_path = opts.learning_path or os.tmpname()
		if not opts.learning_path then os.remove(learning_path) end
		world.learning_path = learning_path
		require("modules.llm.agent_learning")._reset_for_test({ path = learning_path, scheduler = scheduler })

		local engine = require("modules.llm.prediction_engine")
		engine.init({
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = {
				current_buffer = function() return world.buffer end,
				reset = function() world.buffer = "" end,
			},
			is_paused = function() return world.paused end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
			overlay = {
				show = function(candidates, meta)
					world.shown = { candidates = candidates, meta = meta }
					world.active = 1
					return true
				end,
				hide = function() world.shown = nil; return true end,
				is_showing = function() return world.shown ~= nil and #world.shown.candidates > 0 end,
				move = function(delta)
					local count = world.shown and #world.shown.candidates or 0
					if count < 2 then return false end
					world.active = ((world.active - 1 + delta) % count) + 1
					return true
				end,
				active_index = function() return world.active or 1 end,
			},
			apply_prediction = function(candidate)
				world.typed[#world.typed + 1] = candidate.to_type
				return true
			end,
			read_selection = function()
				world.reads = world.reads + 1
				if world.selection == nil then return false, "", "no_selection" end
				return true, world.selection, nil
			end,
			replace_selection = function() error("the agent never replaces the selection") end,
			focus_id = function() return world.window.app .. "\1" .. world.window.title end,
			focused_window = function() return world.window end,
			ask_text = function(title, prompt)
				world.dialogs[#world.dialogs + 1] = { title = title, prompt = prompt }
				return world.command
			end,
			now = function() return M.NOW end,
			timezone = function() return "Europe/Paris" end,
		})
		world.engine = engine
		world.handlers = engine.action_handlers()
		world.config = require("modules.llm.agent_settings").config()

		--- The remote server answers request `index` with `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			if post.on_chunk then
				post.on_chunk(Json.encode({ message = { content = text }, done = true }) .. "\n")
				post.callback({ ok = true, status = 200 })
				return
			end
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- The remote server answers request `index` with a JSON body.
		function world.respond_json(index, root)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200, body = Json.encode(root) })
		end

		--- The remote server refuses request `index`.
		function world.refuse(index, status, message)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = false, status = status, body = "", error_body = Json.encode({ message = message }) })
		end

		--- Lets the pacing timer run until request `index` is sent, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		--- Types text one character at a time, as the daemon feeds the engine.
		function world.type(text, app)
			for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
				world.buffer = world.buffer .. ch
				engine.on_char(ch, world.buffer, { app_id = app or "thunderbird",
					hotstring_preview_visible = world.preview })
			end
		end

		--- The candidate labels on offer.
		function world.offered()
			local texts = {}
			for index, candidate in ipairs(engine.get_suggestions()) do texts[index] = candidate.to_type end
			return texts
		end

		local ok, err = pcall(body, world)
		engine.dismiss()
		os.remove(learning_path)
		os.remove(learning_path .. ".tmp")
		Connectors._set_deps_for_test(nil)
		for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
		for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end, { initial = stored })
end

--- A translated string with {1}, {2}… filled.
--- @param key string
--- @param args table|nil
--- @return string
function M.text(key, args)
	local template = require("infra.i18n").get(key)
	return (template:gsub("{(%d+)}", function(index) return tostring((args or {})[tonumber(index)]) end))
end

return M
