--- tests/unit/ui/test_managed_download_failure_callers.lua

--- ==============================================================================
--- MODULE: Managed Download Failure Caller Tests
--- DESCRIPTION:
--- Exercises actual Lua callers with controlled native boundaries. The shared
--- policy is loaded unchanged; transport, native windows and opener callbacks
--- are explicit test ports and do not prove real networking or GUI operation.
--- ==============================================================================

local helpers = require("tests.helpers")

local fixture_cleanups

local function isolated(body)
	local saved = {}
	local previous_cleanups = fixture_cleanups
	fixture_cleanups = {}
	local function replace(name, value)
		if saved[name] == nil then saved[name] = package.loaded[name] or false end
		package.loaded[name] = value
	end
	replace("logger.shim", { debug = function() end, info = function() end, warn = function() end,
		error = function() end, start = function() end, success = function() end, done = function() end })
	replace("infra.i18n", { get = function(key) return key end })
	local ok, err = xpcall(function() body(replace) end, debug.traceback)
	for index = #fixture_cleanups, 1, -1 do
		local closed, failure = pcall(fixture_cleanups[index])
		if not closed and ok then ok, err = false, failure end
	end
	fixture_cleanups = previous_cleanups
	for name, value in pairs(saved) do package.loaded[name] = value ~= false and value or nil end
	if not ok then error(err, 0) end
end

local function bridge_fixture(replace)
	local world = { current = true, retry_allowed = true, retries = 0, diagnostics = 0,
		diagnostics_available = false, evaluated = {} }
	-- Restore exact known native fixture ports even if construction throws
	-- before the fixture can return its owned close callback.
	for _, name in ipairs({ "lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline",
		"adapters.event_loop", "adapters.notifier", "ui.webkit_host", "ui.webview_manager",
		"infra.manifest_reader" }) do
		replace(name, package.loaded[name])
	end
	replace("ui.download_window.bridge", nil)
	local native_bridge = require("ui.download_window.bridge")
	local native_message = native_bridge.on_message
	native_bridge.on_message = function(...)
		world.native_result = native_message(...)
		return world.native_result
	end
	local document = require("tests.support.document_fixture").new("download_window", native_bridge, {})
	fixture_cleanups[#fixture_cleanups + 1] = document.close
	document.on_effect = function(code) world.evaluated[#world.evaluated + 1] = code end
	local routed = document.proxy()
	-- Existing cases assert the native caller's actual rejection value. The
	-- real manager separately drops a stale response after native retirement.
	local bridge = setmetatable({ on_message = function(payload, state)
		world.native_result = nil
		world.host_result = routed.on_message(payload, state)
		return world.native_result or world.host_result
	end }, { __index = native_bridge })
	local id = bridge.show({ kind = "ollama_model", label = "Independent model fixture",
		is_current = function() return world.current end,
		can_retry = function() return world.retry_allowed end,
		on_retry = function() world.retries = world.retries + 1; return true end,
		on_cancel = function() return true end,
		on_diagnostics = function() world.diagnostics = world.diagnostics + 1; return true end,
		can_open_diagnostics = function() return world.diagnostics_available end,
	})
	helpers.assert_true(type(id) == "number")
	return bridge, world, id
end

local function certificate()
	return { backend = "curl", stage = "tls", curl_exit = 60,
		failure_provenance = "verified", tls_verification = "enforced",
		foreign_secret = "private-password-and-url-must-never-render" }
end

local function action(id, epoch, name)
	return { action = "failure_action", id = name or "retry", session = id, epoch = epoch }
end

local function model_fixture(replace)
	local world = { starts = {}, updates = {}, completions = {}, consent = true }
	local http = {
		postStream = function(_, _, _, _, chunk, done)
			world.starts[#world.starts + 1] = { chunk = chunk, done = done }
			return true
		end,
		cancel = function()
			if world.cancel_throws then error("controlled retirement exception") end
			return world.cancel_ok ~= false
		end,
	}
	world.owned_http = {}
	replace("adapters.http_client", require("tests.support.owned_http_fixture").attach(http, world.owned_http))
	replace("ui.download_window.bridge", {
		show = function(opts) world.options = opts; return 47 end,
		session_id = function() return 47 end,
		update = function(...) world.updates[#world.updates + 1] = { ... }; return true end,
		complete = function(...) world.completions[#world.completions + 1] = { ... }; return true end,
		retire = function() world.retired = true; return true end,
	})
	replace("modules.llm.model_download", nil)
	return require("modules.llm.model_download"), world
end

local function updater_fixture(replace)
	local world = { state = "available", starts = {}, completions = {}, installs = 0, channel = "dev" }
	world.release = { tag = "v0.0.0-dev.150", download_url = "https://example.invalid/archive",
		checksum_url = "https://example.invalid/checksum" }
	replace("infra.installation", { is_source_run = function() return false end })
	replace("ui.download_window.bridge", {
		show = function(opts) world.options = opts; return 53 end,
		complete = function(...)
			local receipt = { ... }
			receipt.classify = world.options.classify_failure()
			world.completions[#world.completions + 1] = receipt
			return true
		end,
		retire = function() world.retired = true; return true end,
	})
	world.updater = {
		get_cached_release = function() return world.release end,
		get_channel = function() return world.channel end,
		get_state = function() return world.state end,
		download_update = function(url, done)
			helpers.assert_eq(url, world.release.download_url)
			world.starts[#world.starts + 1] = { done = done, retry = false }
			world.state = "downloading"
			return true
		end,
		download_release = function(release, done)
			helpers.assert_true(release == world.release)
			world.starts[#world.starts + 1] = { done = done, retry = true }
			world.state = "downloading"
			return true
		end,
		install_update = function() world.installs = world.installs + 1; return true end,
		cancel_update = function() return true end,
	}
	replace("ui.update_check.bridge", nil)
	return require("ui.update_check.bridge"), world
end

helpers.describe("managed download caller ownership", function()
	helpers.it("managed-failure-callers: native progress seed binds its actual session", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			helpers.assert_true(bridge.on_message("ready").pushed)
			helpers.assert_true(world.evaluated[1]:find('setKind("ollama_model",null,null,' .. id .. ');', 1, true) ~= nil)
			helpers.assert_eq(bridge.on_message("cancel").cancelled, false, "unbound strings cannot cancel an owner")
			helpers.assert_eq(bridge.on_message({ action = "cancel", session = id + 1 }).cancelled, false)
		end)
	end)

	helpers.it("managed-failure-callers: typed evidence renders a safe report and no unavailable opener", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			helpers.assert_true(bridge.complete(id, false, "Existing terminal message", certificate()))
			local ready = bridge.on_message("ready")
			local code = world.evaluated[#world.evaluated]
			helpers.assert_true(code:find('network.failure.certificate', 1, true) ~= nil)
			helpers.assert_true(code:find('private-password', 1, true) == nil)
			helpers.assert_true(code:find('open_proxy_settings', 1, true) == nil)
			helpers.assert_eq(bridge.on_message(action(id, ready.failure_epoch, "diagnostics")).accepted, false)
			helpers.assert_eq(world.diagnostics, 0)
		end)
	end)

	helpers.it("managed-failure-callers: old same-session failure epochs never borrow a newer retry", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			bridge.complete(id, false, "First failure", certificate())
			local first = bridge.on_message("ready").failure_epoch
			helpers.assert_true(bridge.on_message(action(id, first)).retried)
			helpers.assert_eq(world.retries, 1)
			bridge.complete(id, false, "Second failure", {})
			local second = bridge.on_message("ready").failure_epoch
			helpers.assert_true(second > first)
			helpers.assert_eq(bridge.on_message(action(id, first)).accepted, false)
			helpers.assert_eq(world.retries, 1)
			helpers.assert_true(bridge.on_message(action(id, second)).retried)
			helpers.assert_eq(world.retries, 2)
		end)
	end)

	helpers.it("managed-failure-callers: fresh capability and owner checks reject retained buttons", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			world.diagnostics_available = true
			bridge.complete(id, false, "Failure", {})
			local epoch = bridge.on_message("ready").failure_epoch
			world.retry_allowed = false
			helpers.assert_eq(bridge.on_message(action(id, epoch)).retried, false)
			world.diagnostics_available = false
			helpers.assert_eq(bridge.on_message(action(id, epoch, "diagnostics")).accepted, false)
			world.current = false
			world.retry_allowed, world.diagnostics_available = true, true
			helpers.assert_eq(bridge.on_message(action(id, epoch)).retried, false)
			helpers.assert_eq(bridge.on_message(action(id, epoch, "diagnostics")).accepted, false)
			helpers.assert_eq(world.retries + world.diagnostics, 0)
		end)
	end)

	helpers.it("managed-failure-callers: readiness replay publishes a fresh failure epoch and current capabilities", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			world.diagnostics_available = true
			helpers.assert_true(bridge.complete(id, false, "Native failure", {}))
			local first = bridge.on_message("ready")
			world.diagnostics_available = false
			local second = bridge.on_message("ready")
			helpers.assert_true(first.pushed and second.pushed)
			helpers.assert_true(second.failure_epoch > first.failure_epoch)
			helpers.assert_eq(bridge.on_message(action(id, first.failure_epoch)).retried, false)
			helpers.assert_eq(bridge.on_message(action(id, second.failure_epoch, "diagnostics")).accepted, false)
			helpers.assert_true(bridge.on_message(action(id, second.failure_epoch)).retried)
			helpers.assert_eq(world.retries, 1)
		end)
	end)

	helpers.it("managed-failure-callers: success cancellation and retirement cannot dispatch failed-operation actions", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			bridge.complete(id, true, "Installed")
			helpers.assert_eq(bridge.on_message(action(id, 1)).retried, false)
			helpers.assert_true(bridge.on_message("ready").pushed)
			helpers.assert_true(world.evaluated[#world.evaluated]:find('showNetworkFailure(', 1, true) == nil)
			bridge, world, id = bridge_fixture(replace)
			helpers.assert_true(bridge.on_message({ action = "cancel", session = id }).cancelled)
			local ready = bridge.on_message("ready")
			helpers.assert_eq(bridge.on_message(action(id, ready.failure_epoch)).retried, false)
			helpers.assert_true(world.evaluated[#world.evaluated]:find('ollama.download_cancelled', 1, true) ~= nil)
			helpers.assert_true(bridge.retire(id))
			helpers.assert_eq(bridge.on_message(action(id, ready.failure_epoch)), nil)
		end)
	end)

	helpers.it("managed-failure-callers: a reentrant capability check cannot dispatch a replaced failure owner", function()
		isolated(function(replace)
			local bridge, world, id = bridge_fixture(replace)
			helpers.assert_eq(bridge.show({ kind = "ollama_model", label = "Busy independent fixture" }), nil)
			bridge.complete(id, true, "Completed initial fixture")
			local armed = false
			local old = bridge.show({ kind = "ollama_model", label = "Reentrant independent fixture",
				on_retry = function() world.retries = world.retries + 1; return true end,
				can_retry = function()
					if armed then bridge.show({ kind = "ollama_model", label = "Replacement fixture" }) end
					return true
				end,
			})
			bridge.complete(old, false, "Failure", {})
			local epoch = bridge.on_message("ready").failure_epoch
			armed = true
			helpers.assert_eq(bridge.on_message(action(old, epoch)).accepted, false)
			helpers.assert_eq(world.host_result, nil, "actual manager drops the retired document response")
			helpers.assert_eq(world.retries, 0)
		end)
	end)

	helpers.it("managed-failure-callers: repeated old transport callbacks cannot settle a same-table model retry", function()
		isolated(function(replace)
			local model, world = model_fixture(replace)
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model", nil,
				function() return world.consent end))
			local receipt = certificate()
			world.starts[1].done({ ok = false, failure_receipt = receipt })
			helpers.assert_true(world.options.on_retry())
			world.starts[1].chunk('{"status":"success"}\n')
			world.starts[1].done({ ok = true })
			helpers.assert_eq(#world.completions, 1, "old completion cannot settle the later same-table attempt")
			helpers.assert_true(world.completions[1][4] == receipt, "native receipt passes without mutation")
			helpers.assert_eq(#world.updates, 0)
			helpers.assert_true(model.is_active())
			world.starts[2].chunk('{"status":"success"}\n')
			world.starts[2].done({ ok = true })
			helpers.assert_eq(#world.completions, 2)
			helpers.assert_eq(world.completions[2][2], true)
			helpers.assert_eq(world.options.on_retry(), false)
		end)
	end)

	helpers.it("managed-failure-callers: current consent and cancellation fence model retry", function()
		isolated(function(replace)
			local model, world = model_fixture(replace)
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model", nil,
				function() return world.consent end))
			world.starts[1].done({ ok = false })
			world.consent = false
			helpers.assert_eq(world.options.can_retry(), false)
			helpers.assert_eq(world.options.on_retry(), false)
			helpers.assert_eq(#world.starts, 1)
			world.consent = true
			helpers.assert_true(world.options.on_retry())
			helpers.assert_true(world.options.on_cancel())
			helpers.assert_eq(world.options.is_current(), false)
			helpers.assert_eq(world.options.on_retry(), false)
			world.starts[2].done({ ok = false, failure_receipt = certificate() })
			helpers.assert_eq(#world.completions, 1)
		end)
	end)

	helpers.it("managed-failure-callers: post-window admission retirement fences actual model dispatch", function()
		isolated(function(replace)
			local model, world = model_fixture(replace)
			helpers.assert_eq(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model", nil,
				function() model.shutdown(); return true end), false)
			helpers.assert_eq(#world.starts, 0)
			helpers.assert_eq(model.is_active(), false)
			helpers.assert_true(world.retired)
		end)
	end)

	helpers.it("managed-failure-callers: reentrant shutdown during retry admission cannot retain a cancelled busy owner", function()
		isolated(function(replace)
			local model, world = model_fixture(replace)
			local retire_on_admission = false
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model", nil,
				function()
					if retire_on_admission then
						retire_on_admission = false
						helpers.assert_true(model.shutdown())
					end
					return true
				end))
			world.starts[1].done({ ok = false })
			retire_on_admission = true
			helpers.assert_eq(world.options.on_retry(), false)
			helpers.assert_eq(#world.starts, 1, "retired retry cannot acquire another transport")
			helpers.assert_eq(model.is_active(), false, "retired retry cannot leave a cancelled busy owner")
			helpers.assert_true(world.retired)
		end)
	end)

	helpers.it("managed-failure-callers: updater retry binds exact cached consent and uses authenticated release download", function()
		isolated(function(replace)
			local bridge, world = updater_fixture(replace)
			helpers.assert_true(bridge.download_offered(world.updater, world.release, {}))
			local receipt = certificate()
			world.state = "idle"
			world.starts[1].done(nil, "Typed native failure", "download", receipt)
			helpers.assert_true(world.completions[1][4] == receipt)
			helpers.assert_true(world.completions[1].classify)
			helpers.assert_true(world.options.can_retry())
			helpers.assert_true(world.options.on_retry())
			helpers.assert_true(world.starts[2].retry)
			world.starts[1].done("/tmp/foreign-old-archive", nil)
			helpers.assert_eq(world.installs, 0, "old callback cannot install into a later attempt")
			world.state = "available"
			world.starts[2].done("/tmp/verified-current-archive", nil)
			helpers.assert_eq(world.installs, 1)
			helpers.assert_eq(world.completions[2][2], true)
			helpers.assert_eq(world.options.can_retry(), false)
		end)
	end)

	helpers.it("managed-failure-callers: verification keeps its own terminal message and newer releases revoke old consent", function()
		isolated(function(replace)
			local bridge, world = updater_fixture(replace)
			helpers.assert_true(bridge.download_offered(world.updater, world.release, {}))
			world.state = "idle"
			world.starts[1].done(nil, "Independent checksum mismatch", "verify", certificate())
			helpers.assert_eq(world.completions[1][4], nil)
			helpers.assert_eq(world.completions[1].classify, false)
			helpers.assert_eq(world.completions[1][3], "changelog_window.install_error_verify")
			helpers.assert_eq(world.options.can_retry(), false)
			world.release = { tag = "v0.0.0-dev.151", download_url = "https://example.invalid/other",
				checksum_url = "https://example.invalid/other-checksum" }
			helpers.assert_eq(world.options.is_current(), false)
			helpers.assert_eq(world.options.on_retry(), false)
			helpers.assert_eq(#world.starts, 1)
		end)
	end)

	helpers.it("managed-failure-callers: a duplicate busy update action cannot retire the active consent owner", function()
		isolated(function(replace)
			local bridge, world = updater_fixture(replace)
			helpers.assert_true(bridge.download_offered(world.updater, world.release, {}))
			helpers.assert_eq(bridge.download_offered(world.updater, world.release, {}), false)
			world.state = "idle"
			world.starts[1].done(nil, "Independent failure", "download", certificate())
			helpers.assert_eq(#world.completions, 1, "the original owner still publishes its actual terminal")
			helpers.assert_true(world.options.can_retry())
		end)
	end)
end)


helpers.describe("actual model cancellation preserves caller UI ownership", function()
	local function actual_bridge_fixture(replace)
		local _, world = model_fixture(replace)
		world.evaluated = {}
		for _, name in ipairs({ "lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline",
			"adapters.event_loop", "adapters.notifier", "ui.webkit_host", "ui.webview_manager",
			"infra.manifest_reader" }) do
			replace(name, package.loaded[name])
		end
		replace("ui.download_window.bridge", nil)
		local native_bridge = require("ui.download_window.bridge")
		local document = require("tests.support.document_fixture").new("download_window", native_bridge, {})
		fixture_cleanups[#fixture_cleanups + 1] = document.close
		document.on_effect = function(code) world.evaluated[#world.evaluated + 1] = code end
		local routed = document.proxy()
		local bridge = setmetatable({ on_message = function(payload, state)
			return routed.on_message(payload, state)
		end }, { __index = native_bridge })
		replace("modules.llm.model_download", nil)
		return require("modules.llm.model_download"), world, bridge
	end

	helpers.it("model-cancel-settlement: synchronous ACK leaves actual UI caller its cancellation presentation", function()
		isolated(function(replace)
			local model, world, bridge = actual_bridge_fixture(replace)
			local completions = 0
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model",
				function() completions = completions + 1 end, function() return world.consent end))
			local id = bridge.session_id()
			helpers.assert_true(bridge.on_message("ready").pushed)
			helpers.assert_true(bridge.on_message({ action = "cancel", session = id }).cancelled)
			helpers.assert_eq(model.is_active(), false)
			local ready = bridge.on_message("ready")
			helpers.assert_true(type(ready) == "table", "immediate caller cancellation must not retire its own UI")
			helpers.assert_true(ready.pushed)
			helpers.assert_true(world.evaluated[#world.evaluated]:find("ollama.download_cancelled", 1, true) ~= nil)
			helpers.assert_true(world.evaluated[#world.evaluated]:find("showNetworkFailure(", 1, true) == nil)
			world.starts[1].done({ ok = true })
			helpers.assert_eq(completions, 0, "cancellation cannot publish model completion")
		end)
	end)

	helpers.it("model-cancel-settlement: accepted cancellation keeps actual UI busy until independent asynchronous ACK", function()
		isolated(function(replace)
			local model, world, bridge = actual_bridge_fixture(replace)
			world.owned_http.settled = false
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model", nil,
				function() return world.consent end))
			local id = bridge.session_id()
			bridge.on_message("ready")
			helpers.assert_eq(bridge.on_message({ action = "cancel", session = id }).cancelled, false)
			helpers.assert_true(model.is_active())
			helpers.assert_true(type(bridge.on_message("ready")) == "table")
			world.consent = false
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(model.is_active(), false)
			helpers.assert_eq(bridge.on_message("ready"), nil, "late native settlement retires only its old namespace")
			local cancelled_terminal = false
			for _, code in ipairs(world.evaluated) do
				if code:find("done(false,", 1, true) and code:find("ollama.download_cancelled", 1, true) then
					cancelled_terminal = true
				end
			end
			helpers.assert_true(cancelled_terminal, "acknowledged cancellation precedes Retire's failure-control cleanup")
			helpers.assert_true(model.shutdown())
		end)
	end)

	helpers.it("model-cancel-settlement: refused termination retains owner then cleans after actual ACK", function()
		isolated(function(replace)
			local model, world, bridge = actual_bridge_fixture(replace)
			world.cancel_ok = false
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model"))
			local id = bridge.session_id()
			bridge.on_message("ready")
			helpers.assert_eq(bridge.on_message({ action = "cancel", session = id }).cancelled, false)
			helpers.assert_true(model.is_active())
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(model.is_active(), false)
			helpers.assert_eq(bridge.on_message("ready"), nil)
			helpers.assert_true(model.shutdown())
		end)
	end)

	helpers.it("model-cancel-settlement: throwing retirement unwinds claim without erasing physical debt", function()
		isolated(function(replace)
			local model, world, bridge = actual_bridge_fixture(replace)
			world.cancel_throws = true
			helpers.assert_true(model.start("http://127.0.0.1:11434", "qwen:2b", "Independent model"))
			local id = bridge.session_id()
			bridge.on_message("ready")
			helpers.assert_eq(bridge.on_message({ action = "cancel", session = id }).cancelled, false)
			helpers.assert_true(model.is_active())
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(model.is_active(), false, "asynchronous listener must not inherit an abandoned cancel frame")
			helpers.assert_eq(bridge.on_message("ready"), nil)
			helpers.assert_true(model.shutdown())
		end)
	end)
end)
