--- tests/support/llm_engine_transcript_world.lua

--- ==============================================================================
--- MODULE: Linux Engine Transcript World
--- DESCRIPTION:
--- Builds the real Linux prediction engine (real profile registry, prompt
--- builder, parser and remote client) on recording fakes of its three ports and
--- exposes it to the shared transcript runner (_shared/lua/test/
--- llm_engine_transcript.lua): the TimerScheduler is the engine's injected
--- scheduler, the HttpClient is the remote client's transport, the
--- TooltipRenderer is the overlay the engine draws on. What each port is asked is
--- recorded in the corpus vocabulary.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("json")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")
local ProfilesFixture = require("tests.support.llm_profiles_fixture")
local InfoBar = require("llm.request_plan.info_bar")
local PromptBuilder = require("llm.prompt_builder")

local M = {}

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

-- Modules loaded afresh for each scenario, so they bind the recording ports
local RELOADED = {
	"modules.llm.prediction_engine", "modules.llm.settings", "modules.llm.profile_settings",
	"modules.llm.display_settings", "modules.llm.trigger_settings", "modules.llm.navigation_settings",
	"modules.llm.api_remote",
}
local FAKED = {
	"adapters.secure_field_detector", "adapters.http_client", "modules.llm.api_entries",
	"modules.llm.profiles", "modules.llm.api_ollama",
}

--- Runs body against a fresh engine on recording ports.
--- @param config table { debounce_ms, count, profile, user_prompt?, watch_timers_ms }
--- @param body function Receives the world.
function M.with_world(config, body)
	local stored = {
		["llm.models.selected"] = "api",
		["llm.profiles.active"] = config.profile,
		["llm.profiles.num_predictions"] = config.count,
		["llm.profiles.auto_profile_for_model"] = false,
		["llm.trigger.instant_on_word_end"] = false,
		["llm.trigger.debounce_ms"] = config.debounce_ms,
	}
	if config.user_prompt then
		stored["llm.user_profiles"] = require("llm.profile_registry_codec").encode({ {
			id = config.user_prompt.id, label = config.user_prompt.label,
			system_single = config.user_prompt.system_single, batch = false,
		} })
	end
	local watched = {}
	for _, ms in ipairs(config.watch_timers_ms) do watched[ms] = true end
	PreferencesFixture.with(function()
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local log, posts = {}, {}
		local world = { model_label = "qwen-3.8-27b" }
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
			isUrlBar = function() return false end,
		}
		package.loaded["adapters.http_client"] = {
			post = function(url, _, request_body, callback)
				local decoded = Json.decode(request_body)
				posts[#posts + 1] = { callback = callback }
				log[#log + 1] = { port = "http", call = "post", max_tokens = decoded.max_tokens }
				return true
			end,
			cancel = function() return true end,
		}
		require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"])
		package.loaded["modules.llm.api_entries"] = { active = function() return ENTRY end }
		local profiles = ProfilesFixture.without_inventory({
			init = function() return true end,
			is_enabled = function() return true end,
			get_current_model = function() return world.model_label end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		})
		package.loaded["modules.llm.profiles"] = profiles
		package.loaded["modules.llm.api_ollama"] = {
			chat = function() error("the scenario runs through the API") end,
			cancel = function() return true end,
		}
		local scheduler = Fakes.timer_scheduler()
		local fake_after = scheduler.after
		scheduler.after = function(delay_sec, fn)
			local delay_ms = math.floor(delay_sec * 1000 + 0.5)
			if watched[delay_ms] then log[#log + 1] = { port = "timer", call = "after", delay_ms = delay_ms } end
			return fake_after(delay_sec, fn)
		end
		local buffer = ""
		local showing = false
		local engine = require("modules.llm.prediction_engine")
		engine.init({ focus_id = function() return "owned-prediction-window" end,
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = { reset = function() buffer = "" end },
			context = { text = function() return buffer end, replaced = function() end },
			notify = function() return true end,
			overlay = {
				show = function(candidates, meta)
					showing = #candidates > 0
					if meta.loading ~= true then
						log[#log + 1] = { port = "tooltip", call = "show", candidates = #candidates,
							info = InfoBar.parts({ model = meta.model, profile_label = meta.profile }) }
					end
					return true
				end,
				hide = function() showing = false; return true end,
				is_showing = function() return showing end,
			},
			apply_prediction = function() return true end,
		})
		local handlers = engine.action_handlers()

		function world.keystroke(text)
			buffer = text
			engine.on_char(text:match("[%z\1-\127\194-\244][\128-\191]*$"), text, { app_id = "editor" })
		end
		function world.elapse(ms) scheduler.test.advance(ms / 1000) end
		function world.answer(index, text)
			local post = assert(posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end
		function world.toggle_live(value) return handlers.llm_live_prompt_toggle("tap_3", value) end
		function world.delete_prompt(id)
			helpers.assert_true(require("modules.llm.profile_settings").delete_user_profile(id))
		end
		function world.base_tokens(text)
			return PromptBuilder.build_params(text,
				{ max_words = require("modules.llm.settings").get("max_words") }).max_tokens
		end
		function world.profile_label(id)
			return InfoBar.short_profile_label(require("infra.i18n").get("llm.profile." .. id .. ".label"))
		end
		function world.calls() return log end

		local ok, err = pcall(body, world)
		engine.stop_live("scenario end", false)
		engine.dismiss()
		for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
		for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
		profiles.assert_no_inventory()
	end, { initial = stored })
end

return M
