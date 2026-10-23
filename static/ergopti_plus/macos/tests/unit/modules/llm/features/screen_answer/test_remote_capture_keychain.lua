--- tests/unit/modules/llm/features/screen_answer/test_remote_capture_keychain.lua

--- ==============================================================================
--- MODULE: Screen Answer Pending Keychain Ownership Regression
--- DESCRIPTION:
--- Compose the actual screen answer, prediction engine and remote provider.
--- A captured private image awaiting a native credential must retain its
--- original request authority until the actual HTTP dispatch boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

-- Keep the process-wide shared logger identity outside native fixture scopes.
require("logger")

local MODULES = {
	"modules.llm.screen_answer", "modules.llm.prediction_engine", "modules.llm",
	"modules.llm.warmup_controller", "modules.llm.streaming_handler",
	"modules.llm.prompt_builder", "modules.llm.app_filter", "modules.llm.api_common",
	"modules.llm.api_remote", "modules.llm.api_mlx", "modules.llm.api_ollama",
	"modules.llm.profiles", "modules.keystats", "modules.shortcuts.script_control",
	"modules.shortcuts.actions.screenshot_save", "adapters.file_system",
	"adapters.json_codec", "adapters.storage", "adapters.timer_scheduler",
	"adapters.mouse_control", "infra.logger", "infra.timings", "infra.keycodes",
	"ui.tooltip", "llm.vision", "llm.rewrite", "llm.prompt_action", "llm.translate",
	"text_utils", "compat.utf8", "modules.llm.api_token_crypto", "adapters.http_client",
	"modules.llm.remote_response_classifier", "modules.llm.local_servers",
	"modules.llm.provider_uses", "modules.llm.progressive_reveal", "modules.llm.parser",
	"infra.manifest_reader", "llm.provider_config_policy", "llm.remote_formats",
	"llm.profile_selector", "llm.parser", "llm.prompt_builder", "llm.local_server_auth",
	"llm.local_server_discovery", "config_defaults", "diagnostics.operation_reporter",
	"hotstrings.personal_files", "infra.fs_dir", "infra.toml.reader", "lfs", "logger.shim",
	"toml_codec.basic_string", "toml_codec.bom", "toml_codec.key_path",
	"toml_codec.reader", "toml_codec.record_scanner",
}

local function with_capture(callback)
	helpers.with_stub_scope(MODULES, function()
		local f = { captures = {}, pending = {}, posts = {}, loading = 0, hidden = 0, notices = {}, ready = true, paused = false }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a"))
				assert(file:close())
				return bytes, "ok"
			end,
			read = function(path)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a"))
				assert(file:close())
				return bytes
			end,
		}
		package.loaded["adapters.json_codec"] = {
			decode = Json.decode,
			encode = function(body)
				if f.on_encode then f.on_encode() end
				return Json.encode(body)
			end,
		}
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
			is_backend_ready = function()
				if f.on_readiness then f.on_readiness() end
				return f.ready
			end,
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
		package.loaded["modules.llm.prompt_builder"] = {}
		package.loaded["modules.llm.app_filter"] = {}
		package.loaded["modules.keystats"] = {}
		package.loaded["modules.llm.profiles"] = { prompt_language = function() return "en" end }
		package.loaded["modules.shortcuts.script_control"] = {
			is_paused = function() return f.paused end,
		}
		package.loaded["modules.llm.api_token_crypto"] = {
			is_encrypted = function(value) return value:sub(1, 9) == "keychain:" end,
			decrypt_async = function(_, done)
				f.pending[#f.pending + 1] = done
				return { cancel = function() return true end }
			end,
		}
		package.loaded["adapters.http_client"] = {
			new = function()
				return {
					cancel = function() return true end,
					get = function() error("this capture must not probe availability") end,
					post = function(url, headers, body, done)
						f.posts[#f.posts + 1] = { url = url, headers = headers, body = body, done = done }
						return true
					end,
				}
			end,
			encodeForQuery = function(value) return value end,
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
		package.loaded["infra.keycodes"] = { F16_LLM_CHAIN_SIGNAL = 106 }
		local remote = require("modules.llm.api_remote")
		remote.set_entries({ { id = "configured", provider = "openai", token = "keychain:original" } })
		local engine = require("modules.llm.prediction_engine")
		helpers.assert_true(engine.init({ buffer = "", llm_buffer = "", mappings = {}, DELAYS = {} }))
		f.flow, f.engine, f.remote = flow, engine, remote
		f.start = function()
			return flow.run("openai|vision-model", flow.MODE_REGION, "gestures", flow.ANSWERS_SCREEN)
		end
		callback(f)
	end)
end

helpers.describe("screen image authority survives pending native credentials", function()
	for _, change in ipairs({ "reset", "AI off", "preview off", "paused", "backend unavailable" }) do
		helpers.it("does not send an image resolved after " .. change, function()
			with_capture(function(f)
				helpers.assert_true(f.start())
				f.captures[1]("image", "private-image-base64")
				helpers.assert_eq(#f.pending, 1)
				helpers.assert_eq(#f.posts, 0, "the native key is still pending")
				if change == "reset" then f.flow.reset()
				elseif change == "AI off" then helpers.assert_true(f.engine.set_llm_enabled(false))
				elseif change == "preview off" then helpers.assert_true(f.engine.set_preview_ai_enabled(false))
				elseif change == "paused" then f.paused = true
				else f.ready = false end
				f.pending[1](true, "cleartext-key")
				helpers.assert_eq(#f.posts, 0, "revoked screen input must not reach HTTP after Keychain")
				if change == "reset" then helpers.assert_eq(f.hidden, 1) end
				for _, notice in ipairs(f.notices) do
					helpers.assert_true(notice ~= "llm.vision.read_failed", "cancellation is not a provider failure")
				end
			end)
		end)
	end

	helpers.it("dispatches a still-current image once its credential resolves", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.captures[1]("image", "private-image-base64")
			f.pending[1](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 1)
			helpers.assert_eq(f.posts[1].headers.Authorization, "Bearer cleartext-key")
		end)
	end)

	helpers.it("preserves a successor while the first screenshot awaits Keychain", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.captures[1]("image", "old-private-image")
			helpers.assert_true(f.start())
			f.captures[2]("image", "new-private-image")
			f.pending[1](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 0)
			helpers.assert_eq(f.hidden, 0, "the stale request cannot close its successor")
			f.pending[2](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 1)
			helpers.assert_true(f.posts[1].body:find("new-private-image", 1, true) ~= nil)
		end)
	end)

	helpers.it("rejects a reset reentering the last backend readiness check", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.captures[1]("image", "private-image")
			f.on_readiness = function() f.flow.reset() end
			f.pending[1](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 0, "a policy callback cannot restore a revoked generation")
			helpers.assert_eq(f.hidden, 1)
		end)
	end)

	helpers.it("checks authority after encoding the private body", function()
		with_capture(function(f)
			helpers.assert_true(f.start())
			f.captures[1]("image", "private-image")
			f.on_encode = function() f.flow.reset() end
			f.pending[1](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 0)
		end)
	end)

	for _, verdict in ipairs({ "false", "truthy", "raised" }) do
		helpers.it("requires strict continuation success for " .. verdict, function()
			with_capture(function(f)
				local failures = {}
				helpers.assert_true(f.remote.request_vision("openai", "vision-model", { messages = {} },
					function() error("no answer belongs to a cancelled request") end,
					function(reason) failures[#failures + 1] = reason end,
					function()
						if verdict == "raised" then error("owner unavailable") end
						if verdict == "truthy" then return 1 end
						return false
					end))
				f.pending[1](true, "cleartext-key")
				helpers.assert_eq(#f.posts, 0)
				helpers.assert_eq(#failures, 1)
				helpers.assert_eq(failures[1], "cancelled")
			end)
		end)
	end

	helpers.it("keeps vision calls without a continuation compatible", function()
		with_capture(function(f)
			helpers.assert_true(f.remote.request_vision("openai", "vision-model", { messages = {} },
				function() end, function() error("legacy request remains admitted") end))
			f.pending[1](true, "cleartext-key")
			helpers.assert_eq(#f.posts, 1)
		end)
	end)
end)
