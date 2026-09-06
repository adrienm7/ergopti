--- tests/unit/modules/llm/test_model_download.lua

--- ==============================================================================
--- MODULE: Linux Ollama Model Download Tests
--- DESCRIPTION:
--- Proves streamed progress, terminal selection, retry ownership, and exact
--- cancellation without a network connection or a real WebKit window.
--- ==============================================================================

local helpers = require("tests.helpers")

local held = {}

local function replace(name, value)
	held[name] = package.loaded[name] or false
	package.loaded[name] = value
end

local function restore()
	for name, value in pairs(held) do package.loaded[name] = value ~= false and value or nil end
	held = {}
	package.loaded["modules.llm.model_download"] = nil
end

local function load_fixture()
	local transport = { starts = {}, cancels = {} }
	local window = { updates = {}, completions = {}, session = 11 }
	local shown = nil
	replace("infra.llm_bridge", {
		ollama_endpoint = function(base_url, path) return base_url .. "/api/" .. path end,
	})
	replace("adapters.http_client", {
		postStream = function(url, headers, body, opts, on_chunk, on_done)
			transport.starts[#transport.starts + 1] = {
				url = url, headers = headers, body = body, opts = opts,
				on_chunk = on_chunk, on_done = on_done,
			}
			return true
		end,
		cancel = function(owner)
			transport.cancels[#transport.cancels + 1] = owner
			return true
		end,
	})
	replace("ui.download_window.bridge", {
		show = function(opts) shown = opts; return window.session end,
		update = function(...)
			window.updates[#window.updates + 1] = { ... }
			return true
		end,
		complete = function(...)
			window.completions[#window.completions + 1] = { ... }
			return true
		end,
		focus = function(session_id) return session_id == window.session end,
		session_id = function() return window.session end,
	})
	package.loaded["modules.llm.model_download"] = nil
	return require("modules.llm.model_download"), transport, window, function() return shown end
end

helpers.describe("Ollama model download: streaming transaction", function()
	helpers.it("parses split NDJSON progress and settles only after Ollama success", function()
		local Download, transport, window = load_fixture()
		local completed = nil
		helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B",
			function(ok, tag) completed = { ok = ok, tag = tag } end))
		helpers.assert_eq(#transport.starts, 1)
		helpers.assert_eq(transport.starts[1].url, "http://127.0.0.1:11434/api/pull")
		transport.starts[1].on_chunk('{"status":"pulling","completed":25,')
		transport.starts[1].on_chunk('"total":100}\n{"status":"success"}\n')
		transport.starts[1].on_done({ ok = true })
		helpers.assert_true(#window.updates >= 1)
		helpers.assert_eq(window.updates[1][2], 25)
		helpers.assert_eq(window.completions[1][1], window.session)
		helpers.assert_eq(window.completions[1][2], true)
		helpers.assert_eq(completed, { ok = true, tag = "qwen:2b" })
		restore()
	end)

	helpers.it("keeps a failed request retryable and cancels only its named owner", function()
		local Download, transport, window, shown = load_fixture()
		helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
		transport.starts[1].on_done({ ok = false, error = "offline" })
		helpers.assert_eq(window.completions[1][2], false)
		helpers.assert_true(shown().on_retry())
		helpers.assert_eq(#transport.starts, 2)
		helpers.assert_true(shown().on_cancel())
		helpers.assert_eq(transport.cancels[1], "ollama_model_pull")
		helpers.assert_eq(Download.is_active(), false)
		restore()
	end)
end)

helpers.describe("shared model catalogue projection", function()
	helpers.it("derives Ollama runtime tags and keeps active/install identities coherent", function()
		local Catalogue = require("llm.model_catalogue")
		local source = { {
			label = "Provider",
			families = { {
				label = "Family",
				models = { {
					name = "Display 750M",
					type = "completion",
					parameters = { total = "750M", active = "250M" },
					hardware_requirements = { ollama = { ram_gb = 2 } },
					capabilities = { speed_tok_s = 50 },
					urls = {
						ollama = "https://ollama.com/library/display:750m",
						hf = "https://huggingface.co/example/display",
					},
				} },
			} },
		} }
		local payload = Catalogue.build(source, "ollama", "display:750m",
			function(_display, runtime) return runtime == "display:750m" end)
		helpers.assert_eq(payload.active, "Display 750M")
		helpers.assert_eq(payload.models[1].runtime_name, "display:750m")
		helpers.assert_eq(payload.models[1].params_b, 0.75)
		helpers.assert_eq(payload.models[1].active_b, 0.25)
		helpers.assert_true(payload.models[1].installed)
	end)
end)
