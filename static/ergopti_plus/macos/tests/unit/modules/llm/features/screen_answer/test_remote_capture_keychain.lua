--- tests/unit/modules/llm/features/screen_answer/test_remote_capture_keychain.lua

--- ==============================================================================
--- MODULE: Screen Answer Pending Keychain Ownership Regression
--- DESCRIPTION:
--- Compose the actual screen answer, prediction engine and remote provider.
--- A captured private image awaiting a native credential must retain its
--- original request authority until the actual HTTP dispatch boundary.
--- ==============================================================================

local helpers = require("tests.helpers")
local PortFakes = require("tests.support.port_fakes")
local Json = require("core.text.engine.json")

-- Keep the process-wide shared logger identity outside native fixture scopes.
require("core.logger.engine")

local MODULES = {
	"modules.llm.screen_answer", "modules.llm.prediction_engine", "modules.llm",
	"modules.llm.warmup_controller", "modules.llm.streaming_handler",
	"modules.llm.prompt_builder", "modules.llm.app_filter", "modules.llm.api_common",
	"modules.llm.api_remote", "modules.llm.api_mlx", "modules.llm.api_ollama",
	"modules.llm.profiles", "modules.keystats", "modules.shortcuts.script_control",
	"modules.shortcuts.actions.screenshot_save", "core.fs.adapters.file_system",
	"core.fs.adapters.json_codec", "core.fs.adapters.storage", "core.events.timer_scheduler",
	"adapters.mouse_control", "core.logger.engine.logger", "infra.timings", "infra.keycodes",
	"ui.tooltip", "ai.engine.prediction.vision", "ai.engine.prediction.rewrite", "ai.engine.prediction.prompt_action", "ai.engine.prediction.translate",
	"core.text.engine.utils_core", "core.lifecycle.engine.compat.utf8", "modules.llm.api_token_crypto", "core.network.adapters.http_client",
	"ai.engine.policy.remote_response_classifier", "modules.llm.local_servers",
	"modules.llm.provider_uses", "modules.llm.progressive_reveal", "modules.llm.parser",
	"infra.manifest_reader", "ai.engine.policy.provider_config_policy", "ai.engine.api.remote_formats",
	"ai.engine.settings.profile_selector", "ai.engine.api.parser_core", "ai.engine.prediction.prompt_builder_core", "ai.engine.local_servers.auth",
	"ai.engine.local_servers.discovery", "settings.engine.publication.defaults", "diagnostics.engine.operation_reporter",
	"hotstrings.engine.catalogue.personal_files", "core.fs.engine.dir", "infra.toml.reader", "lfs", "core.logger.engine.shim",
	"core.text.engine.toml_codec.basic_string", "core.text.engine.toml_codec.bom", "core.text.engine.toml_codec.key_path",
	"core.text.engine.toml_codec.reader", "core.text.engine.toml_codec.record_scanner",
}

local function with_capture(callback)
	helpers.with_stub_scope(MODULES, function()
		local f = { captures = {}, pending = {}, posts = {}, loading = 0, hidden = 0, notices = {}, ready = true, paused = false }
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["core.fs.adapters.file_system"] = {
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
		package.loaded["core.fs.adapters.json_codec"] = {
			decode = Json.decode,
			encode = function(body)
				if f.on_encode then f.on_encode() end
				return Json.encode(body)
			end,
		}
		package.loaded["core.fs.adapters.storage"] = {
			-- The real adapter's read and write pair (api_remote's refused thinking fields)
			get = function() return nil end,
			read_exact = function() return true, nil end,
			set = function() return true end,
		}
		package.loaded["adapters.mouse_control"] = {
			screen_frame_under_cursor = function() return { x = 0, y = 0, w = 640, h = 480 } end,
		}
		package.loaded["core.events.timer_scheduler"] = PortFakes.timer_scheduler({
			now = function() return 0 end,
		})
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_enabled = true, llm_min_words = 1, llm_max_words = 0, llm_debounce = 0, llm_min_request_interval = 0 },
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
		package.loaded["core.network.adapters.http_client"] = {
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
		package.loaded["ui.tooltip"] = PortFakes.complete_tooltip({
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
		})
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
