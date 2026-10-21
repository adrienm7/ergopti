--- tests/unit/modules/llm/features/screen_answer/test_capture_admission.lua

--- ==============================================================================
--- MODULE: Screen Answer Capture Admission Regression
--- DESCRIPTION:
--- Drives the actual screen-answer and prediction-engine owners around a delayed
--- screenshot boundary. A revoked admission must prevent a private image POST;
--- a replaced capture must not regain authority while opening its loading UI.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local MODULES = {
	"modules.llm.screen_answer", "modules.llm.prediction_engine", "modules.llm",
	"modules.llm.warmup_controller", "modules.llm.streaming_handler",
	"modules.llm.prompt_builder", "modules.llm.app_filter", "modules.llm.api_common",
	"modules.llm.api_remote", "modules.llm.api_mlx", "modules.llm.api_ollama",
	"modules.llm.profiles", "modules.keylogger", "modules.shortcuts.script_control",
	"modules.shortcuts.actions.screenshot_save", "adapters.file_system",
	"adapters.json_codec", "adapters.storage", "adapters.timer_scheduler",
	"adapters.mouse_control", "infra.logger", "infra.timings", "infra.keycodes",
	"ui.tooltip", "llm.vision", "llm.rewrite", "llm.prompt_action", "llm.translate",
	"text_utils", "compat.utf8",
}

local function with_capture(callback)
	helpers.with_stub_scope(MODULES, function()
		local f = { captures = {}, posts = {}, loading = 0, hidden = 0, notices = {}, ready = true, paused = false }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = {
			read = function(path)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a"))
				assert(file:close())
				return bytes
			end,
		}
		package.loaded["adapters.json_codec"] = { decode = Json.decode }
		package.loaded["adapters.storage"] = { get = function() return nil end }
		package.loaded["adapters.mouse_control"] = {
			screen_frame_under_cursor = function() return { x = 0, y = 0, w = 640, h = 480 } end,
		}
		package.loaded["adapters.timer_scheduler"] = {
			cancel = function() return true end,
			now = function() return 0 end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_enabled = true, llm_min_words = 1, llm_max_words = 0, llm_debounce = 0 },
			get_current_model = function() return "text-model" end,
			is_backend_ready = function() return f.ready end,
			set_runtime_llm_enabled = function() return true end,
			cancel_streaming = function() return true end,
		}
		package.loaded["modules.llm.warmup_controller"] = {
			init = function() return true end, stop = function() return true end,
		}
		package.loaded["modules.llm.streaming_handler"] = {
			init = function() return true end,
			stop_watchdog = function() return true end,
			reset_failure_count = function() end,
		}
		package.loaded["modules.llm.api_mlx"] = { stop_warmup = function() return true end }
		package.loaded["modules.llm.api_ollama"] = { stop_warmup = function() return true end }
		package.loaded["modules.llm.api_common"] = {}
		package.loaded["modules.llm.prompt_builder"] = {}
		package.loaded["modules.llm.app_filter"] = {}
		package.loaded["modules.keylogger"] = {}
		package.loaded["modules.llm.profiles"] = { prompt_language = function() return "en" end }
		package.loaded["modules.shortcuts.script_control"] = {
			is_paused = function() return f.paused end,
		}
		package.loaded["modules.llm.api_remote"] = {
			stop_warmup = function() return true end,
			vision_provider_status = function() return true end,
			provider_format = function() return "openai" end,
			request_vision = function(_, _, body)
				f.posts[#f.posts + 1] = body
				return true
			end,
		}
		package.loaded["modules.shortcuts.actions.screenshot_save"] = {
			capture_image = function(_, _, _, on_image)
				f.captures[#f.captures + 1] = on_image
				return true
			end,
		}
		package.loaded["ui.tooltip"] = {
			set_navigate_callback = function() end,
			set_enter_validates = function() end,
			set_llm_timeout = function() end,
			mark_chain_complete = function() return true end,
			tint = function() return {} end,
			hide_forced_silent = function() f.hidden = f.hidden + 1; return true end,
			show_loading = function()
				f.loading = f.loading + 1
				if f.on_loading then f.on_loading() end
				return true
			end,
			show = function(text) f.notices[#f.notices + 1] = text; return true end,
		}
		local flow = helpers.load_with_stubs("modules.llm.screen_answer")
		package.loaded["infra.timings"] = { sec = function() return 0.1 end }
		package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
		local engine = require("modules.llm.prediction_engine")
		helpers.assert_true(engine.init({ buffer = "", llm_buffer = "", mappings = {}, DELAYS = {} }))
		f.flow, f.engine = flow, engine
		f.start = function()
			return flow.run("openai|vision-model", flow.MODE_REGION, "gestures", flow.ANSWERS_SCREEN)
		end
		callback(f)
	end)
end

helpers.describe("screen capture completion revalidates private dispatch", function()
	for _, change in ipairs({ "AI off", "preview off", "paused", "backend unavailable" }) do
		helpers.it("never sends a captured image after " .. change, function()
			with_capture(function(f)
				helpers.assert_true(f.start())
				if change == "AI off" then helpers.assert_true(f.engine.set_llm_enabled(false))
				elseif change == "preview off" then helpers.assert_true(f.engine.set_preview_ai_enabled(false))
				elseif change == "paused" then f.paused = true
				else f.ready = false end
				f.captures[1]("image", "private-image-base64")
				helpers.assert_eq(#f.posts, 0, "lost admission must prevent private image transport")
				helpers.assert_eq(f.loading, 0, "a cancelled admission must not reopen its UI")
			end)
		end)
	end

	helpers.it("sends the currently admitted captured image", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.captures[1]("image", "private-image-base64")
			helpers.assert_eq(#f.posts, 1)
			helpers.assert_eq(f.loading, 1)
		end)
	end)

	helpers.it("keeps a superseded capture from sending or opening UI", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			helpers.assert_true(f.start())
			f.captures[1]("image", "old-private-image")
			helpers.assert_eq(#f.posts, 0)
			f.captures[2]("image", "new-private-image")
			helpers.assert_eq(#f.posts, 1)
			helpers.assert_eq(f.loading, 1)
		end)
	end)

	helpers.it("drops a capture reset while its loading UI opens", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.on_loading = function() f.flow.reset() end
			f.captures[1]("image", "old-private-image")
			helpers.assert_eq(#f.posts, 0, "UI callbacks can revoke the screen reading before private dispatch")
			helpers.assert_eq(f.hidden, 1, "a revoked capture closes its loading surface")
		end)
	end)

	helpers.it("revalidates admission after opening its loading UI", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.on_loading = function() f.paused = true end
			f.captures[1]("image", "old-private-image")
			helpers.assert_eq(#f.posts, 0)
			helpers.assert_eq(f.hidden, 1, "the refused dispatch releases its own loading surface")
		end)
	end)

	helpers.it("preserves the successor surface opened from its loading callback", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.on_loading = function()
				f.on_loading = nil
				helpers.assert_true(f.start())
				f.captures[2]("image", "new-private-image")
			end
			f.captures[1]("image", "old-private-image")
			helpers.assert_eq(#f.posts, 1, "only the successor image is dispatched")
			helpers.assert_eq(f.loading, 2)
			helpers.assert_eq(f.hidden, 0, "the superseded callback cannot hide the successor")
		end)
	end)
end)
