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
	local previous = package.loaded["ui.model_browser.bridge"]
	local bridge = helpers.load_module("ui.model_browser.bridge")
	local seen = { refreshes = 0, cache = { "qwen3.5:0.8b" }, selected = {}, downloads = {} }
	local llm = {
		get_models = function() error("page reprojection cannot call an acquiring getter") end,
		get_cached_models = function() seen.cache_reads = (seen.cache_reads or 0) + 1; return seen.cache end,
		get_current_model = function() return "qwen3.5:0.8b" end,
		refresh_models = function() seen.refreshes = seen.refreshes + 1; return {} end,
		set_model = function(model) seen.selected[#seen.selected + 1] = model; return true end,
		download_model = function(model, label) seen.downloads[#seen.downloads + 1] = { model, label }; return true end,
	}
	local fixture = Document.new("model_browser", bridge, { llm = llm })
	local ok, failure = xpcall(function() body(fixture, bridge, seen) end, debug.traceback)
	local closed, acknowledgement = pcall(fixture.close)
	package.loaded["ui.model_browser.bridge"] = previous
	assert(ok, failure)
	assert(closed and acknowledgement, "actual Manager fixture must retire its owned document")
end

helpers.describe("model browser inventory document", function()
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
				helpers.assert_eq(name, "ui.model_browser.bridge")
				return bridge
			end)
			notify()
			helpers.assert_eq(rebuilt, 1)
			helpers.assert_eq(#f.effects, before + 1)
			helpers.assert_eq(seen.refreshes, 1)
		end)
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
			local selected = f.send({ action = "select_model", name = installed.name })
			helpers.assert_eq(seen.selected, { installed.runtime_name })
			helpers.assert_eq(f.manager.is_visible("model_browser"), false)
			-- Native close consumes the old response's document authority.
			helpers.assert_eq(selected, nil)
			helpers.assert_true(f.manager.show("model_browser"))
			f.handshake()
			f.send({ action = "select_model", name = available.name })
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
