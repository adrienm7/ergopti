--- tests/unit/ui/test_download_presentation_owner.lua

--- ==============================================================================
--- MODULE: Download Presentation and Original Operation Consent Tests
--- DESCRIPTION:
--- Uses the actual manager/document lease and bridge with controlled native ports.
--- Fresh display and cleanup intent cannot grant original retry/diagnostic consent.
--- These controls do not establish GTK/WebKit, entropy or OS process ownership.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_session(run)
	local names = { "lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline",
		"adapters.event_loop", "adapters.notifier", "ui.webkit_host", "ui.webview_manager",
		"ui.download_window.bridge", "infra.manifest_reader", "logger.shim", "infra.i18n" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
	local document
	local ok, primary = xpcall(function()
		package.loaded["logger.shim"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["ui.download_window.bridge"] = nil
		local bridge = require("ui.download_window.bridge")
		document = require("tests.support.document_fixture").new("download_window", bridge, {})
		local world = { consent = true, cancellations = 0, retries = 0, diagnostics = 0, effects = {} }
		document.on_effect = function(code)
			world.effects[#world.effects + 1] = { code = code, epoch = document.view().epoch }
		end
		world.show = function(label)
			return bridge.show({ kind = "ollama_model", label = label or "Independent old operation",
				is_current = function() return world.consent end,
				on_cancel = function()
					world.cancellations = world.cancellations + 1
					if world.cancel then return world.cancel() end
					return true
				end,
				on_retry = function() world.retries = world.retries + 1; return true end,
				can_retry = function() return true end,
				on_diagnostics = function() world.diagnostics = world.diagnostics + 1; return true end,
				can_open_diagnostics = function() return true end })
		end
		world.id = assert(world.show())
		world.ready = function() return document.handshake() end
		world.reopen = function()
			assert(document.manager.hide("download_window"))
			assert(bridge.focus(world.id))
			return document.handshake()
		end
		run(bridge, document, world)
	end, debug.traceback)
	if document then
		local closed, failure = pcall(document.close)
		if not closed and ok then ok, primary = false, failure end
	end
	for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
	if not ok then error(primary, 0) end
end

local function cancel(id) return { action = "cancel", session = id } end
local function certificate()
	return { backend = "curl", stage = "tls", curl_exit = 60,
		failure_provenance = "verified", tls_verification = "enforced" }
end

helpers.describe("download fresh presentation preserves original operation consent", function()
	helpers.it("reopened real document displays retained terminal data under its own lease", function()
		with_session(function(bridge, document, world)
			helpers.assert_true(world.ready().pushed)
			local old_owner = document.manager.capture_document_owner("download_window")
			helpers.assert_true(document.manager.hide("download_window"))
			helpers.assert_true(bridge.complete(world.id, true, "Independent retained terminal"))
			helpers.assert_true(bridge.focus(world.id))
			local ready = world.ready()
			helpers.assert_true(ready.pushed)
			helpers.assert_eq(document.manager.document_owner_retained(old_owner), false)
			helpers.assert_true(document.manager.capture_document_owner("download_window") ~= old_owner)
			helpers.assert_true(world.effects[#world.effects].code:find('done(true', 1, true) ~= nil)
			helpers.assert_true(world.effects[#world.effects].code:find("Independent retained terminal", 1, true) ~= nil)
			helpers.assert_eq(world.cancellations + world.retries + world.diagnostics, 0)
		end)
	end)
	helpers.it("closed presentation never receives queued progress and fresh display receives the retained value", function()
		with_session(function(bridge, document, world)
			world.ready()
			local old_epoch = document.view().epoch
			helpers.assert_true(document.manager.hide("download_window"))
			local before = #world.effects
			helpers.assert_true(bridge.update(world.id, 43, "Independent background progress"))
			helpers.assert_eq(#world.effects, before)
			helpers.assert_true(bridge.focus(world.id))
			helpers.assert_true(world.ready().pushed)
			helpers.assert_true(document.view().epoch ~= old_epoch)
			helpers.assert_true(world.effects[#world.effects].code:find("update(43", 1, true) ~= nil)
			helpers.assert_true(world.effects[#world.effects].code:find("Independent background progress", 1, true) ~= nil)
		end)
	end)
	helpers.it("reopened terminal display cannot refresh original retry or diagnostic consent", function()
		with_session(function(bridge, document, world)
			world.ready()
			helpers.assert_true(bridge.complete(world.id, false, "Independent trust refusal", certificate()))
			local ready = world.reopen()
			helpers.assert_true(ready.pushed)
			for _, action in ipairs({ "retry", "diagnostics" }) do
				local reply = document.send({ action = "failure_action", id = action,
					session = world.id, epoch = ready.failure_epoch })
				helpers.assert_true(type(reply) == "table" and reply.accepted == false)
			end
			helpers.assert_eq(world.retries + world.diagnostics, 0)
		end)
	end)
	helpers.it("stale old-document readiness and cancel cannot render or signal a reopened operation", function()
		with_session(function(_, document, world)
			world.ready()
			local old_view, old_metadata = document.view(), document.view().confirmed
			helpers.assert_true(world.reopen().pushed)
			local before = #world.effects
			helpers.assert_nil(document.send("ready", old_view, old_metadata))
			helpers.assert_nil(document.send(cancel(world.id), old_view, old_metadata))
			helpers.assert_eq(#world.effects, before)
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("fresh explicit cancel reaches only the exact background operation despite retired original consent", function()
		with_session(function(_, document, world)
			world.ready()
			world.consent = false
			helpers.assert_true(world.reopen().pushed)
			local reply = document.send(cancel(world.id))
			helpers.assert_true(reply.cancelled)
			helpers.assert_eq(world.cancellations, 1)
			helpers.assert_eq(world.retries + world.diagnostics, 0)
			helpers.assert_true(world.effects[#world.effects].code:find("ollama.download_cancelled", 1, true) ~= nil)
		end)
	end)
	for _, mode in ipairs({ "paused", "nil", "throw" }) do
		local refusal = mode
		helpers.it("cleanup requires literal unpaused receipt: " .. mode, function()
			with_session(function(_, document, world)
				document.state.is_paused = function()
					if refusal == "throw" then error("independent pause refusal") end
					if refusal == "nil" then return nil end
					return true
				end
				world.ready()
				local reply = document.send(cancel(world.id))
				helpers.assert_true(type(reply) == "table" and reply.cancelled == false)
				helpers.assert_eq(world.cancellations, 0)
			end)
		end)
	end
	helpers.it("a changed captured pause function cannot be refreshed by duplicate readiness", function()
		with_session(function(_, document, world)
			world.ready()
			document.state.is_paused = function() return false end
			helpers.assert_nil(document.send("ready"))
			local reply = document.send(cancel(world.id))
			helpers.assert_true(reply.cancelled == false)
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("pause-probe reentry cannot acquire duplicate cleanup intent", function()
		with_session(function(_, document, world)
			local armed, nested = false, nil
			document.state.is_paused = function()
				if armed then armed = false; nested = document.send(cancel(world.id)) end
				return false
			end
			world.ready()
			armed = true
			local reply = document.send(cancel(world.id))
			helpers.assert_true(reply.cancelled)
			helpers.assert_true(type(nested) == "table" and nested.cancelled == false)
			helpers.assert_eq(world.cancellations, 1)
		end)
	end)
	helpers.it("initial native document observation cannot enter duplicate refused cleanup", function()
		with_session(function(bridge, document, world)
			world.ready()
			local native_message, old_uri = bridge.on_message, document.on_uri
			local armed, nested, depth = true, nil, 0
			world.cancel = function() return false end
			local ok, failure = xpcall(function()
				-- Observe the real handler frame without changing its arguments,
				-- native return, manager admission or genuine leased message path.
				bridge.on_message = function(...)
					depth = depth + 1
					local called, result = pcall(native_message, ...)
					depth = depth - 1
					if not called then error(result, 0) end
					return result
				end
				document.on_uri = function()
					if armed and depth > 0 then
						armed = false
						nested = document.send(cancel(world.id))
					end
				end
				local reply = document.send(cancel(world.id))
				helpers.assert_true(reply.cancelled == false)
				helpers.assert_true(type(nested) == "table" and nested.cancelled == false)
				helpers.assert_eq(world.cancellations, 1, "one outer native probe cannot acquire two cleanup frames")
				world.cancel = function() return true end
				helpers.assert_true(document.send(cancel(world.id)).cancelled)
				helpers.assert_eq(world.cancellations, 2, "a later explicit cleanup intent owns its separate frame")
			end, debug.traceback)
			bridge.on_message, document.on_uri = native_message, old_uri
			if not ok then error(failure, 0) end
		end)
	end)
	helpers.it("cleanup callback reentry cannot signal the same operation twice", function()
		with_session(function(_, document, world)
			world.ready()
			local nested
			world.cancel = function() nested = document.send(cancel(world.id)); return true end
			helpers.assert_true(document.send(cancel(world.id)).cancelled)
			helpers.assert_true(nested.cancelled == false)
			helpers.assert_eq(world.cancellations, 1)
		end)
	end)
	helpers.it("native observation retirement refuses cleanup before the operation callback", function()
		with_session(function(_, document, world)
			world.ready()
			document.on_uri = function()
				document.on_uri = nil
				document.manager.hide("download_window")
			end
			helpers.assert_nil(document.send(cancel(world.id)))
			helpers.assert_eq(world.cancellations, 0)
		end)
	end)
	helpers.it("throwing cleanup releases only its intent frame and preserves the same operation for exact retry", function()
		with_session(function(_, document, world)
			world.ready()
			world.cancel = function() error("independent native cleanup refusal") end
			helpers.assert_eq(document.send(cancel(world.id)).cancelled, false)
			world.cancel = function() return true end
			helpers.assert_true(document.send(cancel(world.id)).cancelled)
			helpers.assert_eq(world.cancellations, 2)
		end)
	end)
	helpers.it("cleanup callback replacing the session cannot publish into or cancel its successor", function()
		with_session(function(bridge, document, world)
			world.ready()
			local old_id = world.id
			world.cancel = function()
				bridge.complete(old_id, true, "Independent old operation retired")
				world.id = assert(world.show("Independent successor"))
				return true
			end
			helpers.assert_nil(document.send(cancel(old_id)))
			helpers.assert_true(world.id ~= old_id)
			helpers.assert_eq(world.cancellations, 1)
			helpers.assert_true(world.ready().pushed)
			local reply = document.send(cancel(old_id))
			helpers.assert_true(reply.cancelled == false)
			helpers.assert_eq(world.cancellations, 1)
		end)
	end)
	helpers.it("unacknowledged document initialization cannot authorize presentation or cleanup", function()
		with_session(function(_, document, world)
			local view = document.start_load()
			document.finish_load(view)
			document.ack(view)
			helpers.assert_nil(document.manager.capture_document_owner("download_window"))
			helpers.assert_nil(document.send(cancel(world.id), view, view.metadata))
			helpers.assert_eq(world.cancellations + #world.effects, 0)
		end)
	end)
	helpers.it("native document refusal returns nil under an owned cleanup frame", function()
		with_session(function(bridge, document, world)
			world.ready()
			local owner = document.manager.capture_document_owner("download_window")
			local view, original_uri = document.view(), document.view().uri
			view.uri = "https://foreign.invalid/independent-page"
			helpers.assert_nil(bridge.on_message(cancel(world.id), document.state, { document_owner = owner }))
			helpers.assert_eq(world.cancellations, 0)
			view.uri = original_uri
			helpers.assert_true(document.send(cancel(world.id)).cancelled)
			helpers.assert_eq(world.cancellations, 1, "native refusal must release only its old intent frame")
		end)
	end)
	helpers.it("foreign pause state cannot borrow a genuine presentation lease for cleanup", function()
		with_session(function(bridge, document, world)
			world.ready()
			local owner = document.manager.capture_document_owner("download_window")
			local native_probes, foreign_probes, equality_probes = 0, 0, 0
			local foreign_state = { is_paused = function() foreign_probes = foreign_probes + 1; return false end }
			local original_metatable = getmetatable(document.state)
			local forged_identity = { __eq = function() equality_probes = equality_probes + 1; return true end }
			setmetatable(document.state, forged_identity)
			setmetatable(foreign_state, forged_identity)
			document.on_uri = function() native_probes = native_probes + 1 end
			local called, reply = pcall(bridge.on_message, cancel(world.id), foreign_state, { document_owner = owner })
			setmetatable(document.state, original_metatable)
			helpers.assert_true(called)
			helpers.assert_nil(reply)
			helpers.assert_eq(equality_probes, 0, "native state identity must never invoke foreign table equality")
			helpers.assert_eq(native_probes, 0, "foreign state must refuse before native document observations")
			helpers.assert_eq(foreign_probes, 0, "foreign state must never supply an operation pause probe")
			helpers.assert_eq(world.cancellations, 0)
			document.on_uri = nil
			helpers.assert_true(document.send(cancel(world.id)).cancelled)
			helpers.assert_eq(world.cancellations, 1, "foreign refusal must release only its own intent frame")
		end)
	end)
end)
return helpers
