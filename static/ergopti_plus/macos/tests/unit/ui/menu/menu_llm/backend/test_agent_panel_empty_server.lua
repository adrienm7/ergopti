--- tests/unit/ui/menu/menu_llm/backend/test_agent_panel_empty_server.lua

--- ==============================================================================
--- MODULE: AI Agent Menu (macOS)
--- DESCRIPTION:
--- Builds the real top-level AI agent menu through the shared manifest
--- renderer and drives its rows: the mode, the backend and model of System 1
--- and System 2, and the excluded applications. The setting transaction, the
--- model dialog, the tooltip and the application picker are faked; labels are
--- read from the real English catalogue.
---
--- ROOT CAUSES ENCODED:
--- 1. The manifest's agent_menu places the rows; every dynamic row must have
---    its handler here, or it silently vanishes.
--- 2. The backend lists are the vision backends' (local, then every provider
---    in order), the current one checked, and the model row shows the model in
---    force and stores "<backend>" or "<backend>|<model>".
--- 3. The automatic mode needs System 1: the menu refuses it without one.
--- 4. A local model nobody pulled must be visible and downloadable from the
---    menu, and choosing the local backend offers its download at once
---    (ai-agent-local-model).
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.ui.menu.menu_llm.backend.agent_panel_fixture"] = nil
local Fixture = require("tests.support.ui.menu.menu_llm.backend.agent_panel_fixture")
local base_state = Fixture.base_state
local row_starting = Fixture.row_starting
local titles = Fixture.titles
local with_panel = Fixture.with_panel





--- Reads the two independent inert status frames.
local function empty_status_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/llm_empty_status.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

--- Holds the real native data, renderer and locale owners over private bootstrap paths.
local function with_empty_server_owner(scenario)
	local previous, previous_hs, previous_getenv = {}, rawget(_G, "hs"), os.getenv
	for name, value in pairs(package.loaded) do previous[name] = value end
	local native, owner, receipt, acquired, scratch, fresh_bridge
	local ok, err = pcall(function()
		local driver = helpers.driver_root():gsub("/+$", "")
		local shared = assert(driver:match("^(.*)/[^/]+$")) .. "/_shared/lua"
		require("tests.support.module_isolation").purge(driver, shared)
		helpers.load_with_stubs("infra.logger")
		scratch = assert(os.tmpname())
		assert(os.remove(scratch))
		assert(hs.fs.mkdir(scratch))
		assert(hs.fs.mkdir(scratch .. "/metrics"))
		local ledger = assert(io.open(scratch .. "/metrics/karabiner_kc.log", "wb")); assert(ledger:close())
		local bootstrap = assert(io.open(scratch .. "/paths.toml", "wb"))
		assert(bootstrap:write('ConfigDirPath = "' .. scratch .. '/"\n'))
		assert(bootstrap:close())
		os.getenv = function(name)
			if name == "ERGOPTI_PATHS_FILE" then return scratch .. "/paths.toml" end
			return previous_getenv(name)
		end
		local paths = require("infra.config_paths")
		helpers.assert_eq(paths.init(scratch .. "/"), true)
		helpers.assert_eq(paths.get_config_dir(), scratch .. "/")
		package.loaded["infra.i18n"] = nil
		native = require("infra.i18n")
		local backend = require("infra.locale")
		native.set_locale_injector(function(code) backend.set_locale(code) end)
		native.init()
		owner = { pending = function() return false end }
		acquired = native.scope_acquire(owner)
		helpers.assert_eq(acquired, true)
		receipt = native.scope_capture(owner)
		helpers.assert_not_nil(receipt)
		helpers.assert_eq(native.scope_apply(owner, receipt, "en"), true)
		local corpus = empty_status_corpus()
		local servers = require("modules.llm.local_servers")
		servers.sweep({ { id = corpus.server_id, base_url = "http://localhost:1234/v1" } }, function(_, settle)
			settle({ ok = true, status = 200, body = corpus.empty_server_body }); return true
		end)
		helpers.assert_eq(servers.result(corpus.server_id).status, servers.STATUS_UP)
		helpers.assert_eq(servers.result(corpus.server_id).models, {})
		local applied, observations = {}, { refreshes = 0 }
		local state = { llm_agent_system1 = corpus.server_id, llm_agent_system2 = corpus.server_id,
			llm_agent_mode = "action", llm_agent_disabled_apps = {} }
		local ctx = { state = state, settings_mgr = { apply_setting_transaction = function(options)
			applied[#applied + 1] = options; state[options.key] = options.value; return true
		end }, update_menu = function() observations.refreshes = observations.refreshes + 1 end, observations = observations }
		local panel = require("ui.menu.menu_llm.agent_panel")
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		scenario(function() return panel.build(ctx) end, ctx, require("infra.manifest_menu"), native, applied, corpus, servers)
	end)
	local restored, released, forgotten = true, true, true
	if receipt then restored = native.scope_restore(owner, receipt) == true end
	if acquired then released = native.scope_release(owner) == true end
	if receipt then forgotten = native.scope_forget(owner, receipt) == true end
	local cleanup_ok, cleanup_error = pcall(function()
		fresh_bridge = fresh_bridge or package.loaded["modules.keylogger.kc_bridge"]
		if fresh_bridge and not rawequal(fresh_bridge, previous["modules.keylogger.kc_bridge"]) then fresh_bridge.stop() end
		local scheduler = package.loaded["adapters.timer_scheduler"]
		if scheduler and not rawequal(scheduler, previous["adapters.timer_scheduler"]) then
			helpers.assert_eq(scheduler.cancelAll(), true)
			helpers.assert_eq(scheduler.activeCount(), 0)
		end
		if scratch then
			os.remove(scratch .. "/metrics/karabiner_kc.log")
			os.remove(scratch .. "/paths.toml")
			if hs.fs.attributes(scratch .. "/hammerspoon") then assert(hs.fs.rmdir(scratch .. "/hammerspoon")) end
			if hs.fs.attributes(scratch .. "/metrics") then assert(hs.fs.rmdir(scratch .. "/metrics")) end
			assert(hs.fs.rmdir(scratch))
		end
	end)
	for name in pairs(package.loaded) do if previous[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(previous) do package.loaded[name] = value end
	_G.hs = previous_hs
	os.getenv = previous_getenv
	helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	for name, value in pairs(previous) do helpers.assert_eq(rawequal(package.loaded[name], value), true, name) end
	helpers.assert_eq(cleanup_ok, true, tostring(cleanup_error))
	helpers.assert_eq(restored, true, "actual translator inverse restores before releasing ownership")
	helpers.assert_eq(released, true)
	helpers.assert_eq(forgotten, true)
	if not ok then error(err, 0) end
end

--- Finds the genuine retained or discovered LM Studio submenu under System 1.
local function empty_server_rows(build)
	local system = assert(row_starting(build().submenu, "⚡"))
	local server = assert(row_starting(system.menu, "LM Studio"))
	return server.menu or {}, server
end

helpers.describe("Shared inert empty server status (llm-empty-status)", function()
	helpers.it("uses the genuine empty discovery receipt and shared inert caption (llm-empty-status)", function()
		with_empty_server_owner(function(build, ctx, menu, native, applied, corpus, servers)
			local definition = menu.get_array(corpus.agent.section)
			local original = definition[1]
			local ok, err = pcall(function()
				local rows = empty_server_rows(build)
				helpers.assert_eq(#rows, 1)
				helpers.assert_eq(rows[1].title, corpus.agent.english)
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_nil(rows[1].fn)
				definition[1] = { type = "label", id = corpus.agent.rows[1].id, i18n = corpus.marker_key,
					platforms = { "hs" }, unavailable = "hide" }
				rows = empty_server_rows(build)
				helpers.assert_eq(rows[1].title, corpus.marker_english)
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_nil(rows[1].fn)
				ctx.state.llm_agent_system1 = corpus.server_id .. "|" .. corpus.selected_model
				rows = empty_server_rows(build)
				helpers.assert_eq(#rows, 1)
				helpers.assert_eq(rows[1].title, corpus.selected_model)
				helpers.assert_eq(rows[1].checked, true)
				helpers.assert_type(rows[1].fn, "function")
				helpers.assert_eq(#applied, 0)
				helpers.assert_eq(ctx.observations.refreshes, 0)
				servers.sweep({ { id = corpus.server_id, base_url = "http://localhost:1234/v1" } }, function(_, settle)
					settle({ ok = true, status = 200, body = corpus.served_server_body }); return true
				end)
				ctx.state.llm_agent_system1 = corpus.server_id
				rows = empty_server_rows(build)
				helpers.assert_eq(rows[1].title, corpus.served_model)
				helpers.assert_type(rows[1].fn, "function")
				helpers.assert_eq(rows[1].fn(), true)
				helpers.assert_eq(ctx.state.llm_agent_system1, corpus.server_id .. "|" .. corpus.served_model)
				helpers.assert_eq(ctx.state.llm_agent_system2, corpus.server_id)
				helpers.assert_eq(#applied, 1)
				helpers.assert_eq(ctx.observations.refreshes, 0, "the native setting route delegates publication without a second direct refresh")
				helpers.assert_eq(applied[1].publish_setting, false)
				helpers.assert_eq(applied[1].runtime_fn, "set_llm_agent_system1")
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			helpers.assert_eq(native.get(corpus.agent.key), corpus.agent.english)
		end)
	end)
	helpers.it("refuses a missing or unbound leaf then repairs the original presentation (llm-empty-status)", function()
		with_empty_server_owner(function(build, ctx, menu, _, applied, corpus)
			local definition = menu.get_array(corpus.agent.section)
			local original = definition[1]
			local ok, err = pcall(function()
				definition[1] = nil
				local rows = empty_server_rows(build)
				helpers.assert_eq(rows, {})
				definition[1] = { type = "command", id = "unowned_server_empty", i18n = corpus.agent.key,
					platforms = { "hs" }, unavailable = "hide" }
				rows = empty_server_rows(build)
				helpers.assert_eq(rows, {})
				helpers.assert_eq(ctx.state.llm_agent_system1, corpus.server_id)
				helpers.assert_eq(ctx.state.llm_agent_system2, corpus.server_id)
				helpers.assert_eq(#applied, 0)
				helpers.assert_eq(ctx.observations.refreshes, 0)
			end)
			definition[1] = original
			helpers.assert_eq(ok, true, tostring(err))
			local repaired = empty_server_rows(build)
			helpers.assert_eq(repaired[1].title, corpus.agent.english)
			helpers.assert_eq(repaired[1].disabled, true)
			helpers.assert_nil(repaired[1].fn)
		end)
	end)
	helpers.it("restores exact native owners and private paths after a raised scenario (llm-empty-status)", function()
		local raised = {}
		local ok, err = pcall(function()
			with_empty_server_owner(function() error(raised, 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
	end)
end)


--- Independent complete fixed presentation, captured from the original native producer.
local function panel_frame_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_panel_frames.json"), "rb"))
	local raw = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("Agent complete declared presentation frames", function()
	for _, language in ipairs({ "en", "fr" }) do
		helpers.it("preserves the complete original hierarchy and native effects in " .. language, function()
			local corpus = panel_frame_corpus()
			local state = { llm_agent_system1 = "", llm_agent_system2 = "local", llm_agent_mode = "action",
				llm_agent_disabled_apps = { "hand.alpha", "hand.beta" } }
			with_panel(state, function(build, world)
				world.listed = {}
				local item = assert(build())
				local expected = corpus[language]
				helpers.assert_eq(item.label, expected.outer)
				helpers.assert_eq(titles(item.submenu), { expected.mode, "-", expected.system1, expected.system2, "-", expected.excluded })
				local first, second, excluded = item.submenu[3], item.submenu[4], item.submenu[6]
				helpers.assert_true(first.menu[1].checked)
				helpers.assert_eq(second.menu[1].checked, false)
				helpers.assert_true(second.menu[2].checked, "the original actual local backend remains selected")
				helpers.assert_eq(second.menu[#second.menu - 2].title, "-")
				helpers.assert_eq(second.menu[#second.menu - 1].title, expected.model)
				helpers.assert_eq(second.menu[#second.menu].title, expected.download)
				helpers.assert_eq(excluded.menu[1].title, corpus.picker_label)
				helpers.assert_eq(world.pickers[1].apps, state.llm_agent_disabled_apps)
				helpers.assert_eq(world.pickers[1].placeholder, expected.excluded)
				helpers.assert_eq(#world.applied, 0, "construction never commits an Agent setting")
				helpers.assert_eq(#world.installs, 0, "construction never starts a download")
				second.menu[#second.menu].fn()
				helpers.assert_eq(world.installs, { corpus.model })
				world.refuse_write = true
				world.pickers[1].on_change({ "hand.refused" })
				helpers.assert_eq(state.llm_agent_disabled_apps, { "hand.alpha", "hand.beta" })
				helpers.assert_eq(#world.applied, 0)
				world.refuse_write = false
				world.pickers[1].on_change({ "hand.changed" })
				helpers.assert_eq(world.applied[1].key, "llm_agent_disabled_apps")
				helpers.assert_eq(world.applied[1].runtime_fn, "set_llm_agent_disabled_apps")
			end, language)
		end)
	end

	helpers.it("reads every genuine frame and refuses complete declaration withdrawal before native discovery", function()
		local corpus = panel_frame_corpus()
		local state = base_state(); state.llm_agent_system2 = "local"
		with_panel(state, function(build, world)
			world.listed = {}
			local manifest = require("infra.manifest_menu")
			local root = manifest.get_root()
			local saved = {}
			for section, rows in pairs(corpus.frames) do
				saved[section] = root[section]
				helpers.assert_eq(root[section], rows, "independent canonical declaration: " .. section)
			end
			local original_agent_menu = root.agent_menu
			local ok, err = pcall(function()
				for section, original in pairs(saved) do
					local before = world.tool_lists or 0
					root[section] = nil
					helpers.assert_nil(build(), section .. " withdrawal cannot recreate fixed Agent frames")
					helpers.assert_eq(world.tool_lists or 0, before, "no discovery after missing-frame refusal")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
					root[section] = original
					helpers.assert_not_nil(build(), "fresh actual declaration restores the whole parent")
				end
				for section, original in pairs(saved) do
					root[section] = { { type = "group", id = "foreign_unbound_child", i18n = "menu.agent.title",
						platforms = { "hs" }, unavailable = "hide" } }
					helpers.assert_nil(build(), section .. " invalid child cannot publish the complete Agent parent")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
					root[section] = original
					helpers.assert_not_nil(build(), "the actual repaired frame remains admitted")
				end
				for section, original in pairs(saved) do
					for _, invalid in ipairs({ { false }, { {} }, { { i18n = false } }, { { i18n = 123 } } }) do
						local before = world.tool_lists or 0
						root[section] = invalid
						helpers.assert_nil(build(), section .. " malformed row refuses before child construction")
						helpers.assert_eq(world.tool_lists or 0, before)
						helpers.assert_eq(#world.applied, 0)
						helpers.assert_eq(#world.installs, 0)
					end
					root[section] = original
				end
				for section, original in pairs(saved) do
					for _, kind in ipairs({ "label", "---" }) do
						root[section] = { { type = kind, id = original[1].id, i18n = original[1].i18n,
							platforms = { "hs" }, unavailable = "hide" } }
						helpers.assert_nil(build(), section .. " wrong semantic row kind cannot replace its real child/command")
						helpers.assert_eq(#world.applied, 0)
						helpers.assert_eq(#world.installs, 0)
					end
					root[section] = original
				end
				local runner = require("modules.llm.agent_runner")
				local refresh_tools = runner.refresh_tools
				local late_ok, late_err = pcall(function()
					runner.refresh_tools = function(...)
						local result = refresh_tools(...)
						root.agent_system1_frame = { false }
						return result
					end
					helpers.assert_nil(build(), "a late thrown child refusal cannot publish a surviving partial parent")
					helpers.assert_eq(#world.applied, 0)
					helpers.assert_eq(#world.installs, 0)
				end)
				runner.refresh_tools = refresh_tools
				root.agent_system1_frame = saved.agent_system1_frame
				if not late_ok then error(late_err, 0) end
				local original_menu = root.agent_menu
				root.agent_menu = nil
				helpers.assert_nil(build(), "the genuine absent Agent child definition cannot become an empty fallback")
				root.agent_menu = original_menu
				helpers.assert_not_nil(build(), "the actual child definition repairs the parent route")
				local original = root.agent_system1_frame
				root.agent_system1_frame = { { type = "group", id = "agent_system1", i18n = "menu.agent.off",
					platforms = { "hs" }, unavailable = "hide" } }
				helpers.assert_eq(build().submenu[3].title, "Off", "the genuine changed declaration owns the parent caption")
				root.agent_system1_frame = original
			end)
			for section, original in pairs(saved) do root[section] = original end
			root.agent_menu = original_agent_menu
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("retains the genuine download callback and rechecks declaration withdrawal before delivery", function()
		local state = base_state(); state.llm_agent_system2 = "local"
		with_panel(state, function(build, world)
			world.listed = {}
			local item = assert(build())
			local retained = item.submenu[4].menu[#item.submenu[4].menu].fn
			local root = require("infra.manifest_menu").get_root()
			local saved = root.agent_download_frame
			local ok, err = pcall(function()
				root.agent_download_frame = nil
				helpers.assert_eq(retained(), false, "withdrawn command never enters the download owner")
				helpers.assert_eq(#world.installs, 0)
				root.agent_download_frame = saved
				helpers.assert_eq(retained(), true, "fresh declaration admits the original native callback")
				helpers.assert_eq(world.installs, { "qwen2.5:7b" })
			end)
			root.agent_download_frame = saved
			if not ok then error(err, 0) end
		end)
	end)
end)

--- Looks up the actual native submenu caption without manufacturing a fallback row.
local function find(rows, label)
	for _, row in ipairs(rows) do
		if row.title == label then return row end
	end
end

--- Prior physical 21-language model captions, frozen before the UI handoff.
local function agent_model_caption_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/agent_linux_system_frames.json"), "rb"))
	local raw = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("Agent canonical model caption getter (agent-model-caption-getter)", function()
	for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl",
		"no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		local language = code
		helpers.it("retains the actual model result through its canonical " .. language .. " caption (agent-model-caption-getter)", function()
			local corpus = agent_model_caption_corpus()
			with_panel({ llm_agent_system1 = corpus.spec, llm_agent_system2 = corpus.spec, llm_agent_mode = "action", llm_agent_disabled_apps = {} }, function(build, world)
				local item = assert(build())
				for _, index in ipairs({ 3, 4 }) do
					local rows = item.submenu[index].menu
					helpers.assert_eq(rows[#rows].title, corpus.locales[language].model)
					helpers.assert_eq(rows[#rows - 1].title, "-")
					helpers.assert_eq(type(rows[#rows].fn), "function")
				end
				helpers.assert_eq(#world.applied, 0)
			end, language)
		end)
	end

	for _, status in ipairs({ "unknown", "installed", "missing" }) do
		local state = status
		helpers.it("passes the same native model result for local status " .. state .. " (agent-model-caption-getter)", function()
			local corpus = agent_model_caption_corpus()
			with_panel({ llm_agent_system1 = "local|" .. corpus.model, llm_agent_system2 = "local|" .. corpus.model,
				llm_agent_mode = "action", llm_agent_disabled_apps = {} }, function(build, world)
				if state ~= "unknown" then world.listed = state == "installed" and { [corpus.model] = true } or {} end
				local item = assert(build())
				for _, index in ipairs({ 3, 4 }) do
					local rows = item.submenu[index].menu
					local position = state == "missing" and #rows - 1 or #rows
					local expected = state == "unknown" and "model" or state
					helpers.assert_eq(rows[position].title, corpus.locales.en[expected])
					helpers.assert_eq(type(rows[position].fn), "function")
				end
				helpers.assert_eq(#world.applied, 0)
				helpers.assert_eq(#world.installs, 0)
			end, "en")
		end)
	end

	helpers.it("refuses a foreign canonical model getter and repairs both actual native consumers (agent-model-caption-getter)", function()
		local corpus = agent_model_caption_corpus()
		local state = { llm_agent_system1 = corpus.spec, llm_agent_system2 = corpus.spec, llm_agent_mode = "action", llm_agent_disabled_apps = {} }
		with_panel(state, function(build, world)
			local declaration = require("infra.manifest_menu").get_array("agent_system_model_controls")[2]
			local getter = declaration.caption_getter
			local ok, err = pcall(function()
				declaration.caption_getter = "foreign_model_caption"
				local item = assert(build())
				for _, system in ipairs({ "system1", "system2" }) do
					helpers.assert_nil(find(item.submenu, corpus.locales.en.systems[system].remote),
						"a refused canonical model cannot publish an empty or fallback System parent")
				end
				helpers.assert_eq(state.llm_agent_system1, corpus.spec)
				helpers.assert_eq(state.llm_agent_system2, corpus.spec)
				helpers.assert_eq(#world.applied, 0)
			end)
			declaration.caption_getter = getter
			if not ok then error(err, 0) end
			local repaired = assert(build())
			helpers.assert_eq(repaired.submenu[3].menu[#repaired.submenu[3].menu].title, corpus.locales.en.model)
		end, "en")
	end)
end)
