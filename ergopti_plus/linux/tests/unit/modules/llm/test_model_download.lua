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
	-- The real bridge: a fake that accepted any operation hid that the real one
	-- knew no "pull", so every download failed before reaching Ollama.
	package.loaded["infra.llm_bridge"] = nil
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
	transport.owned_http = {}
	require("tests.support.owned_http_fixture").attach(package.loaded["adapters.http_client"], transport.owned_http)
	replace("ui.download_window.bridge", {
		-- The real window refuses a session without a known kind; a model pull
		-- must name its own
		show = function(opts)
			shown = opts
			if window.during_show then window.during_show() end
			if opts.kind ~= "ollama_model" then return nil end
			return window.session
		end,
		update = function(...)
			window.updates[#window.updates + 1] = { ... }
			return true
		end,
		complete = function(...)
			if window.during_complete then window.during_complete() end
			if window.complete_refused or window.host_closed then return false end
			window.completions[#window.completions + 1] = { ... }
			return true
		end,
		focus = function(session_id) return session_id == window.session end,
		session_id = function() return window.session end,
		retire = function(session_id)
			window.retire_calls = (window.retire_calls or 0) + 1
			window.retired_session = session_id
			return not window.retire_refused and session_id == window.session
		end,
	})
	package.loaded["modules.llm.model_download"] = nil
	return require("modules.llm.model_download"), transport, window, function() return shown end
end

helpers.describe("Ollama model download: streaming transaction", function()
	helpers.it("linux-model-pull-retry-retirement: successful pulls refuse retained retry callbacks", function()
		local Download, transport, window, shown = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			transport.starts[1].on_chunk('{"status":"success"}\n')
			transport.starts[1].on_done({ ok = true })
			helpers.assert_eq(window.completions[1][2], true)
			helpers.assert_eq(shown().on_retry(), false, "success retires retry authorization")
			helpers.assert_eq(#transport.starts, 1, "a stale callback cannot dispatch another pull")
			helpers.assert_eq(Download.is_active(), false)
		end, debug.traceback)
		restore()
		if not ok then error(err) end
	end)

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

helpers.describe("Ollama model download: post-window consent admission", function()
	helpers.it("rechecks the requesting owner after progress UI before actual HTTP dispatch", function()
		local Download, transport, window = load_fixture()
		local current = true
		local Window = package.loaded["ui.download_window.bridge"]
		local original_show = Window.show
		Window.show = function(opts)
			local session = original_show(opts)
			current = false
			return session
		end
		local ok, err = xpcall(function()
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B", nil,
				function() return current end), false, "a reentrant native UI lifecycle change must refuse launch")
			helpers.assert_eq(#transport.starts, 0, "the existing real owner never dispatches /api/pull")
			helpers.assert_eq(#window.completions, 1, "the native progress session settles its refusal")
			helpers.assert_eq(window.completions[1][2], false)
			helpers.assert_eq(Download.is_active(), false)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
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

helpers.describe("model pull retains exact creator and native settlement debt", function()
	helpers.it("owned model termination acceptance waits for real cleanup ACK", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			transport.owned_http.settled = false
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			helpers.assert_eq(Download.shutdown(), false)
			helpers.assert_eq(#transport.cancels, 1)
			helpers.assert_eq(window.retire_calls, nil, "session retirement waits creator and transport proof")
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "other:2b", "Other"), false)
			transport.owned_http.operations[1]:acknowledge()
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_eq(window.retire_calls, 1)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("logical model completion keeps its native cleanup debt through shutdown", function()
		local Download, transport = load_fixture()
		local ok, err = xpcall(function()
			transport.owned_http.settled = false
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			transport.starts[1].on_chunk('{"status":"success"}\n')
			transport.starts[1].on_done({ ok = true })
			helpers.assert_eq(Download.is_active(), false, "logical job may complete while native closes remain")
			helpers.assert_eq(Download.shutdown(), false)
			transport.owned_http.operations[1]:acknowledge()
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("model window creator reserves cancellation before its exact session returns", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			window.during_show = function() window.shutdown_during_show = Download.shutdown() end
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"), false)
			helpers.assert_eq(window.shutdown_during_show, false)
			helpers.assert_eq(#transport.starts, 0)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_eq(window.retire_calls, 1)
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("model HTTP creator cannot outlive terminal source revocation", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			transport.owned_http.during_create = function()
				transport.shutdown_during_create = Download.shutdown()
			end
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"), false)
			helpers.assert_eq(transport.shutdown_during_create, false)
			helpers.assert_eq(#transport.starts, 0)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("model JSON creator retains cancellation until preparation unwinds", function()
		local Download, transport, window = load_fixture()
		local json = require("json")
		local encode = json.encode
		json.encode = function(value)
			transport.shutdown_during_encode = Download.shutdown()
			return encode(value)
		end
		local ok, err = xpcall(function()
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"), false)
			helpers.assert_eq(transport.shutdown_during_encode, false)
			helpers.assert_eq(#transport.starts, 0)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		json.encode = encode
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("unknown model HTTP acquisition never fabricates absence or cleanup ACK", function()
		local Download, transport = load_fixture()
		local ok, err = xpcall(function()
			transport.owned_http.during_create = function() error("unknown native constructor acquisition") end
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"), false)
			helpers.assert_eq(Download.shutdown(), false)
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "other:2b", "Other"), false)
			helpers.assert_eq(#transport.starts, 0)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("model source withdrawal and exact progress namespace", function()
	helpers.it("stale model settlement suppresses publication and releases its old namespace", function()
		local Download, transport, window = load_fixture()
		local allowed = true
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B", nil,
				function() return allowed end))
			allowed = false
			transport.starts[1].on_done({ ok = true })
			helpers.assert_eq(#window.completions, 1)
			helpers.assert_eq(window.completions[1][2], false)
			helpers.assert_eq(window.completions[1][3], require("infra.i18n").get("ollama.download_cancelled"))
			helpers.assert_eq(Download.is_active(), false)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "other:2b", "Other"))
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("known source withdrawal during model window construction retires only returned session", function()
		local Download, transport, window = load_fixture()
		local allowed = true
		local ok, err = xpcall(function()
			window.during_show = function() allowed = false end
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B", nil,
				function() return allowed end), false)
			helpers.assert_eq(#transport.starts, 0)
			helpers.assert_eq(Download.is_active(), false)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("superseding model progress serial never retires the foreign current session", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			window.session = 17
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(window.retire_calls, nil, "the foreign namespace receives no retirement call")
			helpers.assert_eq(window.session, 17)
			helpers.assert_eq(Download.is_active(), false)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("malformed model progress serial is refused rather than classified absent", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			window.session = "unclassified"
			helpers.assert_eq(Download.shutdown(), false)
			helpers.assert_eq(window.retire_calls, nil)
			window.session = 11
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(window.retired_session, 11)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("same model progress serial with refused retirement retains exact owner", function()
		local Download, transport, window = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			window.retire_refused = true
			helpers.assert_eq(Download.shutdown(), false)
			helpers.assert_true(Download.is_active())
			window.retire_refused = false
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_eq(Download.is_active(), false)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)
end)


helpers.describe("model preparation failure after source withdrawal", function()
	helpers.it("withdrawn model consent with encode error retires known old UI without HTTP", function()
		local Download, transport, window = load_fixture()
		local json, allowed = require("json"), true
		local encode = json.encode
		json.encode = function() allowed = false; error("controlled preparation error") end
		local ok, err = xpcall(function()
			helpers.assert_eq(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B", nil,
				function() return allowed end), false)
			helpers.assert_eq(#transport.starts, 0)
			helpers.assert_eq(#window.completions, 1)
			helpers.assert_eq(window.completions[1][2], false)
			helpers.assert_eq(window.completions[1][3], require("infra.i18n").get("ollama.download_cancelled"))
			helpers.assert_eq(Download.is_active(), false)
			helpers.assert_eq(window.retired_session, 11)
			helpers.assert_true(Download.shutdown())
		end, debug.traceback)
		json.encode = encode
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("model cancellation namespace publication", function()
	helpers.it("refused cancellation UI retains exact settled owner until visible ACK", function()
		local Download, transport, window, shown = load_fixture()
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			window.complete_refused = true
			helpers.assert_eq(Download.shutdown(), false)
			helpers.assert_eq(shown().classify_failure(), false, "cancelled cleanup cannot classify a server failure")
			helpers.assert_true(Download.is_active())
			helpers.assert_eq(window.retire_calls, nil)
			window.complete_refused = false
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(window.completions[1][2], false)
			helpers.assert_eq(window.completions[1][3], require("infra.i18n").get("ollama.download_cancelled"))
			helpers.assert_eq(window.retired_session, 11)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("cancelled UI callback cannot acknowledge or retire a superseding progress session", function()
		local Download, transport, window = load_fixture()
		local nested
		local ok, err = xpcall(function()
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			window.during_complete = function()
				nested = Download.shutdown()
				window.session = 17
			end
			helpers.assert_true(Download.shutdown())
			helpers.assert_eq(nested, false, "UI constructor frame has not unwound")
			helpers.assert_eq(window.retire_calls, nil)
			helpers.assert_eq(window.session, 17)
			helpers.assert_eq(Download.is_active(), false)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("actual daemon keeps model host until physical retirement", function()
	local function daemon_registry(prediction, webviews, state)
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "r"))
		local text = file:read("*a"); file:close()
		local capture = assert(text:match("(local shutdown_runtime = prediction_engine and prediction_engine%.shutdown_runtime.-)\nlocal shutdown = ShutdownCoordinator"))
		local registry = assert(text:match("local shutdown = ShutdownCoordinator%.new%(%{(.-)\n%}%)[\r\n]"))
		local env = setmetatable({
			ShutdownCoordinator = require("infra.shutdown_coordinator"), prediction_engine = prediction,
			webview_manager = webviews, dyn_hotstrings = false, updater = false, file_watchers = false,
			process_lifecycle = false, secure_field_detector = false, metrics = false,
			tooltip_preview = false, gestures = false, input_capture_gate = false,
			package = { loaded = {} }, require = function() return { cleanup = function() end, flush = function() end } end,
			TimerScheduler = { cancelAll = function() end }, Logger = { warn = function() end },
			keyboard_hook = { isRunning = function() return false end, stop = function() end, emergency_stop = function() end },
			event_loop = { stop = function() state.loops = state.loops + 1 end },
		}, { __index = _G })
		local body = capture .. "\nreturn ShutdownCoordinator.new({" .. registry .. "\n})"
		local compiled, why
		if setfenv then compiled, why = loadstring(body, "actual daemon model host order"); if compiled then setfenv(compiled, env) end
		else compiled, why = load(body, "actual daemon model host order", "t", env) end
		assert(compiled, why)
		return compiled()
	end

	helpers.it("actual model Complete and Retire precede host teardown after independent HTTP ACK", function()
		local Download, transport, window = load_fixture()
		local state = { loops = 0, hosts = 0 }
		local ok, err = xpcall(function()
			transport.owned_http.settled = false
			helpers.assert_true(Download.start("http://127.0.0.1:11434", "qwen:2b", "Qwen 2B"))
			local webviews = { shutdown = function()
				state.hosts = state.hosts + 1
				state.completed, state.retired = #window.completions, window.retired_session
				window.host_closed = true
			end }
			local coordinator = daemon_registry({ shutdown_runtime = Download.shutdown, cancel = function() end }, webviews, state)
			helpers.assert_true(coordinator.request("terminal model shutdown"))
			helpers.assert_true(coordinator.is_pending())
			helpers.assert_eq(state.hosts, 0)
			helpers.assert_eq(state.loops, 0)
			helpers.assert_eq(coordinator.poll(), false)
			webviews.shutdown = function() state.foreign = true end
			transport.owned_http.operations[1]:acknowledge()
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.completed, 1, "known cancellation completed before host destruction")
			helpers.assert_eq(state.retired, 11, "old namespace retired before host destruction")
			helpers.assert_eq(state.hosts, 1)
			helpers.assert_eq(state.foreign, nil, "host callback captured before retained polling")
			helpers.assert_eq(state.loops, 1)
			helpers.assert_true(coordinator.poll())
			helpers.assert_eq(state.hosts, 1)
		end, debug.traceback)
		restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("actual daemon without an AI owner retains its ordinary host teardown", function()
		local state = { loops = 0, hosts = 0 }
		local coordinator = daemon_registry(false, { shutdown = function() state.hosts = state.hosts + 1 end }, state)
		helpers.assert_true(coordinator.request("no optional AI module"))
		helpers.assert_eq(state.hosts, 1)
		helpers.assert_eq(state.loops, 1)
		helpers.assert_eq(coordinator.is_pending(), false)
	end)
end)
