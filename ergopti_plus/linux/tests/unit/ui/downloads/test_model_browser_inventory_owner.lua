--- tests/unit/ui/downloads/test_model_browser_inventory_owner.lua

--- ==============================================================================
--- MODULE: Model Browser Inventory Document Ownership
--- DESCRIPTION:
--- Exercises the actual browser bridge, Manager and document lease across native
--- nonce/ACK boundaries. Controlled native capabilities are not WebKit proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local Document = require("tests.support.document_fixture")

local function with_browser(body)
	local previous = package.loaded["ai.ui.model_browser.bridge"]
	local bridge = helpers.load_module("ai.ui.model_browser.bridge")
	local seen = { refreshes = 0, cache = { "qwen3.5:0.8b" }, identity = {}, selected = {}, downloads = {} }
	local llm = {
		get_models = function() error("page reprojection cannot call an acquiring getter") end,
		get_cached_models = function() seen.cache_reads = (seen.cache_reads or 0) + 1; return seen.cache end,
		get_cached_models_status = function()
			seen.cache_reads = (seen.cache_reads or 0) + 1
			if seen.raise_status then error("synthetic inventory unavailable") end
			local cache, known = seen.cache, seen.unknown ~= true
			if seen.on_status_read then seen.on_status_read() end
			return cache, known, known and seen.identity or nil
		end,
		get_current_model = function() if seen.on_current then seen.on_current() end; return "qwen3.5:0.8b" end,
		get_backend = function() if seen.on_backend_read then seen.on_backend_read() end; return seen.backend or "ollama" end,
		set_backend = function(kind)
			seen.backend = kind
			if seen.on_backend then seen.on_backend() end
			return true
		end,
		refresh_models = function() seen.refreshes = seen.refreshes + 1; return {} end,
		set_model = function(model) seen.selected[#seen.selected + 1] = model; return true end,
		download_model = function(model, label) seen.downloads[#seen.downloads + 1] = { model, label }; return not seen.refuse_download end,
	}
	local fixture = Document.new("model_browser", bridge, { llm = llm })
	local ok, failure = xpcall(function() body(fixture, bridge, seen) end, debug.traceback)
	local closed, acknowledgement = pcall(fixture.close)
	package.loaded["ai.ui.model_browser.bridge"] = previous
	assert(ok, failure)
	assert(closed and acknowledgement, "actual Manager fixture must retire its owned document")
end

	helpers.it("(linux-model-inventory-owner) does not download a model installed after the page was drawn", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local available
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" and row.installed ~= true then available = row; break end
			end
			helpers.assert_not_nil(available)
			seen.cache[#seen.cache + 1] = available.runtime_name
			local result = f.send({ action = "download_model", backend = "ollama", name = available.name })
			helpers.assert_eq(result.downloading, false)
			helpers.assert_eq(seen.downloads, {})
		end)
	end)

helpers.describe("model browser inventory document", function()
	helpers.it("(inventory-review) does not publish stale known rows when the source becomes unknown during projection", function()
		with_browser(function(f, _, seen)
			seen.on_current = function() seen.on_current = nil; seen.cache = {}; seen.unknown = true end
			local ready = f.handshake()
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" then
					helpers.assert_eq(row.inventory_unknown, true, "source retired before payload publication")
					helpers.assert_eq(row.available, false)
				end
			end
		end)
	end)
	helpers.it("(inventory-review) retires the projection when the source is replaced with identical models", function()
		with_browser(function(f, _, seen)
			seen.on_current = function() seen.on_current = nil; seen.identity = {} end
			local ready = f.handshake()
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" then helpers.assert_eq(row.inventory_unknown, true) end
			end
		end)
	end)
	helpers.it("(inventory-review) retires the projection when a backend observation replaces its source", function()
		with_browser(function(f, _, seen)
			seen.on_backend_read = function() seen.on_backend_read = nil; seen.identity = {}; seen.backend = "api" end
			local ready = f.handshake()
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" then helpers.assert_eq(row.inventory_unknown, true) end
			end
		end)
	end)
	helpers.it("(inventory-review) refuses an old row after a same-model source successor", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local available
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" and row.installed ~= true then available = row; break end
			end
			helpers.assert_not_nil(available)
			seen.identity = {}
			local result = f.send({ action = "download_model", backend = "ollama", name = available.name })
			helpers.assert_eq(result.downloading, false)
			helpers.assert_eq(seen.downloads, {})
		end)
	end)
	for _, action in ipairs({ "select_model", "delete_model" }) do
		helpers.it("(inventory-review) refuses " .. action .. " after a same-model source successor", function()
			local previous = package.loaded["ai.ui.menu.backend_rows"]
			package.loaded["ai.ui.menu.backend_rows"] = { api_page = function() return { rows = {}, providers = {}, tools = {} } end }
			local ok, failure = pcall(with_browser, function(f, bridge, seen)
				local deletes = 0
				bridge.bind({ dialogs = {}, delete_model = function() deletes = deletes + 1; return true end,
					ollama_state = function() return true end, ollama_install_phase = function() return "idle" end,
					install_ollama = function() return true end })
				local ready, installed = f.handshake(), nil
				for _, row in ipairs(ready.data.models) do
					if row.runtime_name == "qwen3.5:0.8b" then installed = row; break end
				end
				helpers.assert_not_nil(installed)
				seen.identity = {}
				local result = f.send({ action = action, backend = "ollama", name = installed.name })
				if action == "delete_model" then helpers.assert_eq(result.deleted, false)
				else helpers.assert_eq(result.selected, false) end
				helpers.assert_eq(deletes, 0); helpers.assert_eq(seen.selected, {})
			end)
			package.loaded["ai.ui.menu.backend_rows"] = previous
			assert(ok, failure)
		end)
	end
	helpers.it("(inventory-review) replaces a projection invalidated during native publication with unknown rows", function()
		with_browser(function(f, _, seen)
			f.on_effect = function()
				f.on_effect = nil
				seen.cache, seen.unknown = {}, true
			end
			local ready = f.handshake()
			helpers.assert_true(ready.pushed)
			helpers.assert_true(#f.effects >= 2, "an invalidated effect must be superseded")
			helpers.assert_true(f.effects[#f.effects].code:find('inventory_unknown', 1, true) ~= nil)
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" then
					helpers.assert_eq(row.inventory_unknown, true)
					helpers.assert_eq(row.available, false)
				end
			end
		end)
	end)
	helpers.it("(inventory-review) refuses a download when the inventory is retired after its lookup", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local available
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" and row.installed ~= true then available = row; break end
			end
			helpers.assert_not_nil(available)
			seen.on_status_read = function()
				seen.on_status_read = nil
				f.on_uri = function() f.on_uri = nil; seen.cache, seen.unknown = {}, true end
			end
			local result = f.send({ action = "download_model", backend = "ollama", name = available.name })
			helpers.assert_eq(result.downloading, false)
			helpers.assert_eq(seen.downloads, {})
		end)
	end)
	helpers.it("(inventory-review) retains an explicit manual download while inventory is unknown", function()
		with_browser(function(f, _, seen)
			seen.cache, seen.unknown = {}, true
			f.handshake()
			local result = f.send({ action = "add_model", backend = "ollama", name = "manual:latest" })
			helpers.assert_eq(result.downloading, true)
			helpers.assert_eq(seen.downloads, { { "manual:latest", "manual:latest" } })
		end)
	end)
	helpers.it("(inventory-review) never projects stale custom models from an unknown inventory", function()
		with_browser(function(f, _, seen)
			seen.cache, seen.unknown = { "stale-custom:latest" }, true
			local ready = f.handshake()
			for _, row in ipairs(ready.data.models) do
				helpers.assert_true(row.runtime_name ~= "stale-custom:latest", "unknown data cannot offer removal")
			end
		end)
	end)
	helpers.it("(inventory-review) treats an inventory exception as unknown", function()
		with_browser(function(f, _, seen)
			seen.raise_status = true
			local ready = f.handshake()
			helpers.assert_true(ready.pushed)
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" then helpers.assert_eq(row.inventory_unknown, true) end
			end
		end)
	end)
	helpers.it("(inventory-review) refuses a stale click during reentrant page publication", function()
		with_browser(function(f, bridge, seen)
			local ready = f.handshake()
			local available
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" and row.installed ~= true then available = row; break end
			end
			helpers.assert_not_nil(available)
			local answer
			f.on_effect = function()
				f.on_effect = nil
				seen.cache, seen.unknown = {}, true
				answer = f.send({ action = "download_model", backend = "ollama", name = available.name })
			end
			local pushed, data = bridge.reproject_current()
			helpers.assert_true(pushed)
			helpers.assert_eq(answer.downloading, false)
			helpers.assert_eq(seen.downloads, {})
			for _, row in ipairs(data.models) do
				if row.backend == "ollama" then helpers.assert_eq(row.inventory_unknown, true) end
			end
		end)
	end)
	helpers.it("(inventory-review) preserves a newer reentrant projection over its interrupted predecessor", function()
		with_browser(function(f, bridge, seen)
			f.handshake()
			local newer
			f.on_effect = function()
				f.on_effect = nil
				seen.cache = { "fresh-custom:latest" }
				local pushed
				pushed, newer = bridge.reproject_current()
				helpers.assert_true(pushed)
			end
			local pushed = bridge.reproject_current()
			helpers.assert_eq(pushed, false, "the older projection lost ownership")
			helpers.assert_true(f.effects[#f.effects].code:find("fresh%-custom:latest") ~= nil)
			local found = false
			for _, row in ipairs(newer.models) do if row.runtime_name == "fresh-custom:latest" then found = true end end
			helpers.assert_true(found)
		end)
	end)
	helpers.it("(linux-model-inventory-owner) marks unknown inventory and restores rows when it becomes known", function()
		with_browser(function(f, _, seen)
			seen.cache, seen.unknown = {}, true
			local ready = f.handshake()
			local row
			for _, candidate in ipairs(ready.data.models) do
				if candidate.backend == "ollama" then row = candidate; break end
			end
			helpers.assert_not_nil(row)
			helpers.assert_eq(row.available, false)
			helpers.assert_eq(row.inventory_unknown, true)
			helpers.assert_eq(row.hint_key, "model_browser.inventory_unavailable")
			seen.unknown = false
			local refreshed = f.send("ready")
			for _, candidate in ipairs(refreshed.data.models) do
				if candidate.name == row.name and candidate.backend == "ollama" then
					helpers.assert_eq(candidate.inventory_unknown, nil)
					helpers.assert_true(candidate.available ~= false)
					return
				end
			end
			error("refreshed row missing")
		end)
	end)
	helpers.it("(linux-model-inventory-owner) refuses downloading while the current inventory is unknown", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local available
			for _, row in ipairs(ready.data.models) do
				if row.backend == "ollama" and row.installed ~= true then available = row; break end
			end
			helpers.assert_not_nil(available)
			seen.cache, seen.unknown = {}, true
			local effects = #f.effects
			local result = f.send({ action = "download_model", backend = "ollama", name = available.name })
			helpers.assert_eq(result.downloading, false)
			helpers.assert_eq(seen.downloads, {})
			helpers.assert_eq(#f.effects, effects)
		end)
	end)
	for _, unavailable in ipairs({ false, true }) do
		helpers.it("(linux-model-inventory-owner) rechecks installation after switching backends: " .. tostring(unavailable), function()
			with_browser(function(f, _, seen)
				seen.backend = "api"
				local ready = f.handshake()
				local installed
				for _, row in ipairs(ready.data.models) do
					if row.runtime_name == "qwen3.5:0.8b" then installed = row end
				end
				helpers.assert_not_nil(installed)
				seen.on_backend = function() if unavailable then seen.cache = nil else seen.cache = {} end end
				local result = f.send({ action = "select_model", backend = "ollama", name = installed.name })
				helpers.assert_eq(result.selected, false)
				helpers.assert_eq(seen.selected, {})
			end)
		end)
	end

	helpers.it("(linux-model-inventory-owner) refuses selection when the live inventory is unavailable", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local installed
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
			end
			helpers.assert_not_nil(installed)
			seen.cache = nil
			local effects = #f.effects
			local result = f.send({ action = "select_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(result.selected, false)
			helpers.assert_eq(seen.selected, {})
			helpers.assert_eq(#f.effects, effects, "unknown inventory must not repaint as empty")
		end)
	end)

	helpers.it("(linux-model-inventory-owner) refuses deletion of an obsolete installed row", function()
		local previous = package.loaded["ai.ui.menu.backend_rows"]
		package.loaded["ai.ui.menu.backend_rows"] = { api_page = function()
			return { rows = {}, providers = {}, tools = {} }
		end }
		local ok, failure = pcall(with_browser, function(f, bridge, seen)
			local deletions = 0
			bridge.bind({ dialogs = {}, delete_model = function() deletions = deletions + 1; return true end,
				ollama_state = function() return true end, ollama_install_phase = function() return "idle" end,
				install_ollama = function() return true end })
			local ready = f.handshake()
			local installed
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
			end
			helpers.assert_not_nil(installed)
			seen.cache = {}
			local result = f.send({ action = "delete_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(result.deleted, false)
			helpers.assert_eq(deletions, 0)
		end)
		package.loaded["ai.ui.menu.backend_rows"] = previous
		assert(ok, failure)
	end)

	helpers.it("(linux-model-inventory-owner) refuses a model removed after the page was drawn", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local installed
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
			end
			helpers.assert_not_nil(installed)
			seen.cache = {}
			local result = f.send({ action = "select_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(seen.selected, {})
			helpers.assert_eq(result.selected, false)
			helpers.assert_eq(f.manager.is_visible("model_browser"), true)
		end)
	end)

	for _, mode in ipairs({ "throw", "refuse", "inline" }) do
		helpers.it("(model-selector-listing-refusal) reports " .. mode .. " without leaking an exception", function()
			local previous, states = package.loaded["ai.ui.menu.backend_rows"], {}
			package.loaded["ai.ui.menu.backend_rows"] = { api_page = function(_, _, _, _, listings)
				if listings and listings.e1 then states[#states + 1] = listings.e1.state end
				return { rows = {}, providers = {}, tools = {} }
			end }
			local ok, failure = pcall(with_browser, function(f, bridge)
				bridge.bind({ dialogs = {}, delete_model = function() return false end,
					ollama_state = function() return true end, ollama_install_phase = function() return "idle" end,
					install_ollama = function() return true end,
					listing = { targets = function() return { { id = "e1", token = "synthetic-private-token" } } end,
						list = function(entry, callback)
							if mode == "throw" then error(entry.token) end
							if mode == "inline" then callback({ state = "listed", ids = {} }) end
							return false
						end } })
				local logger, messages = require("core.logger.engine.shim"), {}
				local previous_error = logger.error
				logger.error = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
				local called, result = pcall(f.handshake)
				logger.error = previous_error
				assert(called, result)
				if mode ~= "inline" then helpers.assert_true(#messages > 0) end
				for _, message in ipairs(messages) do
					helpers.assert_true(not message:find("synthetic-private-token", 1, true))
				end
				helpers.assert_eq(states[#states], mode == "inline" and "listed" or "failed")
			end)
			package.loaded["ai.ui.menu.backend_rows"] = previous
			assert(ok, failure)
		end)
	end

	helpers.it("(model-selector-private-error) keeps action exceptions out of the log", function()
		local previous = package.loaded["ai.ui.menu.backend_rows"]
		package.loaded["ai.ui.menu.backend_rows"] = { api_page = function()
			return { rows = {}, tools = {}, providers = { { id = "test", label = "Test",
				run = function() error("synthetic-private-token") end } } }
		end }
		local ok, failure = pcall(with_browser, function(f, bridge)
			bridge.bind({ dialogs = {}, delete_model = function() return false end,
				ollama_state = function() return true end, ollama_install_phase = function() return "idle" end,
				install_ollama = function() return true end })
			f.handshake()
			local logger, messages = require("core.logger.engine.shim"), {}
			local previous_error = logger.error
			logger.error = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
			local called, result = pcall(f.send, { action = "add_provider", backend = "api", provider = "test" })
			logger.error = previous_error
			assert(called, result)
			helpers.assert_eq(result.accepted, false)
			helpers.assert_true(#messages > 0)
			for _, message in ipairs(messages) do
				helpers.assert_true(not message:find("synthetic-private-token", 1, true))
			end
		end)
		package.loaded["ai.ui.menu.backend_rows"] = previous
		assert(ok, failure)
	end)

	helpers.it("(linux-model-selection-owner) does not select after page revocation during backend switch", function()
		with_browser(function(f, bridge, seen)
			seen.backend = "api"
			local ready = f.handshake()
			local installed
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
			end
			helpers.assert_not_nil(installed)
			seen.on_backend = function() bridge.on_window_acquiring(9999) end
			f.send({ action = "select_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(seen.selected, {})
		end)
	end)

	helpers.it("(linux-model-delete-owner) passes the page owner to the model deletion", function()
		local previous = package.loaded["ai.ui.menu.backend_rows"]
		package.loaded["ai.ui.menu.backend_rows"] = { api_page = function()
			return { rows = {}, providers = {}, tools = {} }
		end }
		local ok, failure = pcall(with_browser, function(f, bridge)
			local checked = false
			bridge.bind({ dialogs = {}, delete_model = function(_, page_current)
				helpers.assert_eq(type(page_current), "function")
				helpers.assert_eq(page_current(), true)
				bridge.on_window_acquiring(9999)
				helpers.assert_eq(page_current(), false)
				checked = true
				return false
			end, ollama_state = function() return true end,
				ollama_install_phase = function() return "idle" end, install_ollama = function() return true end })
			local ready = f.handshake()
			local installed
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
			end
			helpers.assert_not_nil(installed)
			f.send({ action = "delete_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(checked, true)
		end)
		package.loaded["ai.ui.menu.backend_rows"] = previous
		assert(ok, failure)
	end)

	for _, refused in ipairs({ true, false }) do
		helpers.it("(model-selector-download-receipt) reports request admission " .. tostring(not refused), function()
			with_browser(function(f, _, seen)
				f.handshake()
				seen.refuse_download = refused
				local logger, messages = require("core.logger.engine.shim"), {}
				local info, warn = logger.info, logger.warn
				logger.info = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
				logger.warn = function(_, fmt, ...) messages[#messages + 1] = string.format(fmt, ...) end
				local ok, result = pcall(f.send, { action = "add_model", backend = "ollama", name = "example:7b" })
				logger.info, logger.warn = info, warn
				assert(ok, result)
				helpers.assert_eq(result.downloading, not refused)
				local expected = refused and "could not be started" or "download requested"
				local found = false
				for _, message in ipairs(messages) do
					helpers.assert_true(not message:find("Model added", 1, true))
					if message:find(expected, 1, true) then found = true end
				end
				helpers.assert_true(found)
			end)
		end)
	end

	helpers.it("(model-selector-api-owner) passes the actual page lifetime to API callbacks", function()
		local previous, current = package.loaded["ai.ui.menu.backend_rows"], nil
		package.loaded["ai.ui.menu.backend_rows"] = {
			api_page = function(_, _, _, _, _, owner)
				current = owner
				return { rows = {}, providers = {}, tools = {} }
			end,
		}
		local ok, failure = pcall(with_browser, function(f, bridge)
			bridge.bind({ dialogs = {}, delete_model = function() return true end,
				ollama_state = function() return true end,
				ollama_install_phase = function() return "idle" end,
				install_ollama = function() return true end })
			f.handshake()
			helpers.assert_eq(type(current), "function")
			helpers.assert_eq(current(), true)
			bridge.on_window_acquiring(9999)
			helpers.assert_eq(current(), false)
		end)
		package.loaded["ai.ui.menu.backend_rows"] = previous
		assert(ok, failure)
	end)

	helpers.it("(linux-model-browser-owner) nonce ACK and physical timer retirement precede ready", function()
		with_browser(function(f, _, seen)
			helpers.assert_eq(f.send("ready"), nil)
			helpers.assert_eq(seen.refreshes, 0)
			local view = f.start_load(); local metadata = f.finish_load(view)
			f.ack(view, metadata)
			helpers.assert_eq(f.send("ready", view, metadata), nil)
			helpers.assert_eq(seen.refreshes, 0)
			f.timers[#f.timers]:ack_close()
			local ready = f.send("ready", view)
			helpers.assert_true(ready.pushed)
			helpers.assert_eq(seen.refreshes, 1)
			helpers.assert_true(#ready.data.models > 0)
			helpers.assert_true(f.effects[1].code:find("runLinuxOwnedDocumentEffect", 1, true) ~= nil)
		end)
	end)

	helpers.it("(linux-model-browser-owner) failed page nonce cannot acquire catalogue or refresh", function()
		with_browser(function(f, bridge, seen)
			local view = f.start_load(); f.finish_load(view, "invalid")
			helpers.assert_eq(f.send("ready", view, { generation = 1, token = "forged", page_nonce = "invalid" }), nil)
			helpers.assert_eq(bridge.reproject_current(), false)
			helpers.assert_eq(seen.refreshes, 0)
		end)
	end)

	helpers.it("(linux-model-browser-owner) notification reprojects only cached contemporary inventory", function()
		with_browser(function(f, bridge, seen)
			f.handshake()
			local before = #f.effects
			seen.cache = { "new-runtime:2b" }
			helpers.assert_true(bridge.reproject_current())
			helpers.assert_eq(#f.effects, before + 1)
			helpers.assert_eq(seen.refreshes, 1)
			helpers.assert_true((seen.cache_reads or 0) >= 2)
			f.send("refresh")
			helpers.assert_eq(seen.refreshes, 2)
		end)
	end)

	helpers.it("(linux-model-browser-owner) actual Main notification rebuilds tray and reprojects without HTTP", function()
		with_browser(function(f, bridge, seen)
			f.handshake()
			-- Baseline Main exceeds LuaJIT's upvalue limit. Execute only its actual
			-- constructor callback bytes; the real Manager/lease remains in this graph.
			local handle = assert(io.open("ergopti_hotstrings.lua", "r"))
			local source = handle:read("*a"); assert(handle:close())
			local callback = source:match("on_models_changed = (.-)\n\t\t\ton_offer =")
			assert(callback, "the production Main callback must exist")
			callback = callback:gsub(",%s*$", "")
			local compile = loadstring or load
			local factory = assert(compile("return function(rebuild_tray_menu, require) return " .. callback .. " end"))()
			local rebuilt, before = 0, #f.effects
			local notify = factory(function() rebuilt = rebuilt + 1 end, function(name)
				helpers.assert_eq(name, "ai.ui.model_browser.bridge")
				return bridge
			end)
			notify()
			helpers.assert_eq(rebuilt, 1)
			helpers.assert_eq(#f.effects, before + 1)
			helpers.assert_eq(seen.refreshes, 1)
		end)
	end)

	helpers.it("(model-selector-progress) a pull's percentage reaches its row and survives a new payload", function()
		with_browser(function(f, bridge)
			f.handshake()
			local before = #f.effects
			helpers.assert_eq(bridge.on_download_progress("unknown:tag", 10), false, "no row, nothing sent")
			helpers.assert_true(bridge.on_download_progress("qwen3.5:0.8b", 42))
			helpers.assert_eq(#f.effects, before + 1)
			helpers.assert_true(f.effects[#f.effects].code:find("injectProgress", 1, true) ~= nil)
			local _, data = bridge.reproject_current()
			local row
			for _, candidate in ipairs(data.models) do
				if candidate.runtime_name == "qwen3.5:0.8b" then row = candidate end
			end
			helpers.assert_eq(row.pending, "download")
			helpers.assert_eq(row.progress, 42)
			helpers.assert_eq(bridge.on_download_progress("qwen3.5:0.8b", nil), false, "the end clears it")
			_, data = bridge.reproject_current()
			for _, candidate in ipairs(data.models) do
				if candidate.runtime_name == "qwen3.5:0.8b" then row = candidate end
			end
			helpers.assert_nil(row.progress)
		end)
	end)

	-- model-selector-install-button: the Ollama group's install button follows
	-- the runtime, MLX cannot run here, and the click runs the AI enable that
	-- offers Ergopti's own Ollama download.
	helpers.it("(model-selector-install-button) Install Ollama follows the runtime and runs the AI enable", function()
		-- The API rows are another owner's (test_model_selector_api_listing);
		-- the real one would load the HTTP stack this fixture does not provide.
		local saved_rows = package.loaded["ai.ui.menu.backend_rows"]
		package.loaded["ai.ui.menu.backend_rows"] = {
			api_page = function() return { rows = {}, providers = {}, tools = {} } end,
		}
		local ok, failure = pcall(with_browser, function(f, bridge)
			local phase, ollama_ok, installs = "idle", false, {}
			bridge.bind({
				dialogs = {}, delete_model = function() return true end, on_changed = function() end,
				ollama_state = function()
					if ollama_ok then return true end
					return false, "model_browser.reason_ollama_missing"
				end,
				ollama_install_phase = function() return phase end,
				install_ollama = function(_, on_changed) installs[#installs + 1] = on_changed; return true end,
			})
			local function backends()
				local _, data = bridge.reproject_current()
				local out = {}
				for _, b in ipairs(data.backends) do out[b.id] = b end
				return out
			end
			f.handshake()
			local b = backends()
			helpers.assert_eq(b.ollama.available, false, "a missing Ollama greys its rows")
			helpers.assert_eq(b.ollama.install, { state = "available" })
			helpers.assert_eq(b.mlx.install, { state = "unsupported", reason_key = "model_browser.reason_mlx_unsupported_os" })
			helpers.assert_nil(b.api.install, "the API installs nothing")
			f.send({ action = "group_action", backend = "ollama", id = "install" })
			helpers.assert_eq(#installs, 1, "the click runs the AI enable")
			phase = "running"
			helpers.assert_eq(backends().ollama.install, { state = "running" })
			f.send({ action = "group_action", backend = "ollama", id = "install" })
			helpers.assert_eq(#installs, 1, "a running install is not started twice")
			phase, ollama_ok = "ai_on", true
			b = backends()
			helpers.assert_eq(b.ollama.install, { state = "installed" })
			helpers.assert_eq(b.ollama.available, true, "the installed runtime unlocks its rows")
			ollama_ok = false
			helpers.assert_eq(backends().ollama.install,
				{ state = "unsupported", reason_key = "model_browser.reason_install_ai_on" })
			-- model-selector-install-refusal: a click the AI enable refuses says so
			-- on the page, the next click forgets it, a stale click repaints.
			phase = "idle"
			bridge.bind({
				dialogs = {}, delete_model = function() return true end, on_changed = function() end,
				ollama_state = function() return false, "model_browser.reason_ollama_missing" end,
				ollama_install_phase = function() return phase end,
				install_ollama = function(_, on_changed) installs[#installs + 1] = on_changed; return #installs > 2 end,
			})
			local painted = #f.effects
			f.send({ action = "group_action", backend = "ollama", id = "install" })
			helpers.assert_eq(#installs, 2, "the click reached the handler")
			helpers.assert_eq(#f.effects, painted + 1, "the refusal reaches the page")
			helpers.assert_eq(backends().ollama.install,
				{ state = "available", failed_key = "model_browser.install_not_started" })
			f.send({ action = "group_action", backend = "ollama", id = "install" })
			helpers.assert_eq(backends().ollama.install, { state = "available" }, "an accepted click forgets it")
			phase = "running"
			painted = #f.effects
			f.send({ action = "group_action", backend = "ollama", id = "install" })
			helpers.assert_eq(#installs, 3, "a stale click starts nothing")
			helpers.assert_eq(#f.effects, painted + 1, "and the page learns where the install stands")
			bridge._reset()
		end)
		package.loaded["ai.ui.menu.backend_rows"] = saved_rows
		assert(ok, failure)
	end)

	helpers.it("(linux-model-browser-owner) installed selection and available download retain their own page", function()
		with_browser(function(f, _, seen)
			local ready = f.handshake()
			local installed, available
			for _, row in ipairs(ready.data.models) do
				if row.runtime_name == "qwen3.5:0.8b" then installed = row end
				if not available and row.installed ~= true then available = row end
			end
			helpers.assert_not_nil(installed); helpers.assert_not_nil(available)
			helpers.assert_true(installed.installed)
			local selected = f.send({ action = "select_model", backend = "ollama", name = installed.name })
			helpers.assert_eq(seen.selected, { installed.runtime_name })
			helpers.assert_eq(f.manager.is_visible("model_browser"), false)
			-- Native close consumes the old response's document authority.
			helpers.assert_eq(selected, nil)
			helpers.assert_true(f.manager.show("model_browser"))
			f.handshake()
			-- model-selector-page: a model not downloaded offers its download,
			-- never its activation.
			f.send({ action = "select_model", backend = "ollama", name = available.name })
			helpers.assert_eq(seen.selected, { installed.runtime_name }, "selecting a missing model selects nothing")
			helpers.assert_eq(seen.downloads, {}, "selecting a missing model downloads nothing")
			f.send({ action = "download_model", backend = "ollama", name = available.name })
			helpers.assert_eq(seen.downloads, { { available.runtime_name, available.name } })
		end)
	end)

	for _, mode in ipairs({ "loading", "uri", "manager", "llm", "state" }) do
		helpers.it("(linux-model-browser-owner) " .. mode .. " replacement refuses retained projection", function()
			with_browser(function(f, bridge, seen)
				f.handshake()
				local before = #f.effects
				if mode == "loading" then f.view().loading = true
				elseif mode == "uri" then f.view().uri = "https://foreign.invalid/"
				elseif mode == "manager" then f.manager.eval_owned_js = function() error("replacement writer cannot execute") end
				elseif mode == "llm" then f.state.llm.get_cached_models = function() error("replacement getter cannot execute") end
				else f.manager.set_daemon_state({ llm = f.state.llm }) end
				helpers.assert_eq(bridge.reproject_current(), false)
				helpers.assert_eq(#f.effects, before)
				helpers.assert_eq(seen.refreshes, 1)
			end)
		end)
	end

	helpers.it("(linux-model-browser-owner) close and reopen require a fresh document with global cache", function()
		with_browser(function(f, bridge, seen)
			f.handshake()
			local old, old_metadata = f.view(), f.view().confirmed
			helpers.assert_true(f.manager.hide("model_browser"))
			helpers.assert_eq(bridge.reproject_current(), false)
			helpers.assert_true(f.manager.show("model_browser"))
			helpers.assert_eq(f.send("ready", old, old_metadata), nil)
			helpers.assert_eq(seen.refreshes, 1)
			seen.cache = { "qwen3.5:0.8b" }
			local ready = f.handshake()
			helpers.assert_true(ready.pushed)
			helpers.assert_eq(seen.refreshes, 2)
			helpers.assert_true(bridge.reproject_current())
		end)
	end)

	helpers.it("(linux-model-browser-owner) native observation cannot hand an interrupted effect to a successor", function()
		with_browser(function(f, bridge, seen)
			f.handshake()
			local before = #f.effects
			f.on_uri = function()
				f.on_uri = nil
				helpers.assert_true(f.manager.hide("model_browser"))
				helpers.assert_true(f.manager.show("model_browser"))
			end
			helpers.assert_eq(bridge.reproject_current(), false)
			helpers.assert_eq(#f.effects, before)
			helpers.assert_eq(seen.refreshes, 1)
			helpers.assert_true(f.handshake().pushed)
		end)
	end)
end)
