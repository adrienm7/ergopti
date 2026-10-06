--- tests/unit/ui/menu/menu_llm/test_models_selector_pause_gate.lua

--- ==============================================================================
--- MODULE: Regression — models_selector rows disabled when paused (M-16)
--- DESCRIPTION:
--- ModelsSelector.build() previously lacked a `paused` parameter and its rows had
--- no `disabled` field. While paused, clicking any model row called switch_model()
--- → guarded_check_requirements() which triggered backend warmup mid-pause —
--- violating the suspend-pause invariant.
---
--- Fix: thread `paused` into M.build(ctx) and set `disabled = paused or nil` on
--- every model-selection row (no_model, backend_default, user rows, preset rows).
---
--- Test: call build({paused=true}) with a minimal fake context and assert that
--- every menu item without a `menu` (direct action row) has disabled=true or fn
--- raises no error before switch_model could be reached (because disabled items are
--- greyed-out and macOS/hs won't invoke their fn). The simplest contract:
--- build returns a table of items all with disabled=true (or nil fn for non-switch
--- rows).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Build a minimal fake context that satisfies ModelsSelector.build() I/O contract
local function make_ctx(paused)
	local switch_calls = {}
	local disable_calls = 0
	return {
		state = {
			llm_model   = "",
			llm_backend = "mlx",
		},
		models_mgr = {
			get_installed_models = function() return {} end,
			get_presets          = function() return {} end,
			get_model_info       = function() return nil end,
			get_model_ram        = function() return 0 end,
			is_model_installed   = function() return false end,
		},
		switch_model  = function(m) switch_calls[#switch_calls + 1] = m end,
		disable_model = function() disable_calls = disable_calls + 1; return true end,
		save_prefs    = function() end,
		update_menu   = function() end,
		DEFAULT_STATE = { llm_model_mlx = "", llm_model_ollama = "" },
		paused        = paused,
		get_switch_calls = function() return switch_calls end,
		get_disable_calls = function() return disable_calls end,
	}
end





-- ==============================================================================
-- ==============================================================================
-- ======= 1/ All direct model rows have disabled=true when paused (M-16) =======
-- ==============================================================================
-- ==============================================================================

helpers.describe("M-16: models_selector rows disabled when paused", function()

	helpers.it("build({paused=true}) — every actionable row has disabled=true", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(true)
		local menu = MS.build(ctx)

		helpers.assert_true(type(menu) == "table", "build must return a table")
		helpers.assert_true(#menu > 0, "build must return at least one item")

		-- Provider rows since 2026-08-06: {label, action, items} rather than
		-- {title, fn, menu}, because the LLM model row is a manifest `list` slot
		-- and the shared renderer materialises what this file returns. The gate
		-- being checked is unchanged — an actionable row must be greyed while the
		-- script is paused — so the assertion follows the field names rather than
		-- being dropped with them.
		local checked = 0
		for i, item in ipairs(menu) do
			if type(item.label) == "string" and not item.separator and type(item.action) == "function" then
				checked = checked + 1
				helpers.assert_true(item.disabled == true,
					string.format("row %d ('%s') must have disabled=true when paused", i, item.label))
			end
		end
		helpers.assert_true(checked > 0,
			"no actionable row was inspected — a loop that matches nothing agrees with any output, "
				.. "which is exactly how a renamed field turns this test green over a broken gate")
	end)

	helpers.it("build({paused=false}) — rows are NOT disabled", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(false)
		local menu = MS.build(ctx)

		-- At least one actionable row should be enabled
		local found_enabled = false
		for _, item in ipairs(menu) do
			if type(item.label) == "string" and not item.separator and type(item.action) == "function" then
				if item.disabled ~= true then found_enabled = true end
			end
		end
		helpers.assert_true(found_enabled,
			"at least one model row must be enabled when paused=false")
	end)

	helpers.it("(no-model-runtime) the No Model row delegates the runtime transaction to the model switcher", function()
		package.loaded["ui.menu.menu_llm.models_selector"] = nil
		local MS = helpers.load_with_stubs("ui.menu.menu_llm.models_selector")
		local ctx = make_ctx(false)
		local menu = MS.build(ctx)
		local no_model
		for _, item in ipairs(menu) do
			if item.checked == true and type(item.action) == "function" then
				no_model = item
				break
			end
		end
		helpers.assert_not_nil(no_model, "the checked No Model action must be reachable")
		helpers.assert_eq(no_model.action(), true)
		helpers.assert_eq(ctx.get_disable_calls(), 1,
			"the selector must not mutate preferences without clearing runtime model state")
	end)
end)


--- Reads the independently pinned frame and platform expectations.
local function model_readout_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/model_readout_frames.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

--- Keeps genuine catalogue/renderer/locale owners private, including raised scenarios.
local function with_model_readout_owner(scenario)
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
		local manager = require("ui.menu.menu_llm.models_manager").new({ trigger_reload = function() end })
		fresh_bridge = package.loaded["modules.keylogger.kc_bridge"]
		local calls = {}
		local ctx = {
			state = { llm_backend = "ollama", llm_model = "", llm_user_models = {} },
			models_mgr = manager, DEFAULT_STATE = {}, paused = false,
			switch_model = function(name) calls[#calls + 1] = name end,
			disable_model = function() return true end,
			save_prefs = function() error("readout construction must not save") end,
			update_menu = function() error("readout construction must not refresh") end,
		}
		scenario(require("ui.menu.menu_llm.models_selector"), ctx,
			require("infra.manifest_menu"), native, calls, model_readout_corpus())
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

--- Finds the real curated model's sheet, not an injected provider result.
local function model_readout_sheet(rows, name)
	for _, provider in ipairs(rows) do
		for _, model in ipairs(provider.items or {}) do
			if type(model.label) == "string" and model.label:find(name, 1, true) then
				return model.items, model
			end
		end
	end
	error("actual curated model is missing: " .. name)
end

helpers.describe("Shared per-model readout frames (model-readout-frames)", function()
	for _, frame_name in ipairs({ "specs", "caps" }) do
		helpers.it("the actual " .. frame_name .. " sheet consumes shared presentation and retains selection (model-readout-frames)", function()
			with_model_readout_owner(function(selector, ctx, menu, native, calls, corpus)
				local expected = corpus[frame_name]
				local declared = menu.get_array(expected.section)
				local original = declared[3]
				local label = expected.platform_rows.hs[2].label
				local rows, model = model_readout_sheet(selector.build(ctx), corpus.native_model)
				local position
				for index, row in ipairs(rows) do if row.label == label then position = index end end
				helpers.assert_type(position, "number", "hand-pinned decorated heading must be reached")
				helpers.assert_eq(rows[position - 1].separator, true)
				helpers.assert_eq(rows[position].disabled, true)
				helpers.assert_nil(rows[position].action)
				helpers.assert_eq(rows[1].label, corpus.selection_english)
				helpers.assert_type(rows[1].action, "function")
				helpers.assert_type(model.action, "function")
				helpers.assert_eq(#calls, 0)
				rows[1].action()
				helpers.assert_eq(#calls, 1)
				helpers.assert_eq(calls[1], corpus.native_model)
				local ok, err = pcall(function()
					declared[3] = { type = "section_header", id = original.id, i18n = corpus.marker_key,
						platforms = { "hs" }, unavailable = "hide" }
					rows = model_readout_sheet(selector.build(ctx), corpus.native_model)
					helpers.assert_eq(rows[position].label, "— " .. corpus.marker_english .. " —",
						"the real allocator must use its current shared declaration")
					helpers.assert_eq(rows[position - 1].separator, true)
					helpers.assert_eq(rows[position].disabled, true)
					helpers.assert_nil(rows[position].action)
					local effects = 0
					declared[3] = { type = "command", id = "unowned_readout", i18n = corpus.marker_key,
						platforms = { "hs" }, unavailable = "hide", action = function() effects = effects + 1 end }
					helpers.assert_eq(#selector.build(ctx), 0, "unowned shared commands refuse the actual sheet")
					helpers.assert_eq(effects, 0)
					helpers.assert_eq(#calls, 1, "construction/refusal never selects another model")
				end)
				declared[3] = original
				helpers.assert_eq(ok, true, tostring(err))
				rows = model_readout_sheet(selector.build(ctx), corpus.native_model)
				helpers.assert_eq(rows[position].label, label)
				ctx.paused = true
				rows, model = model_readout_sheet(selector.build(ctx), corpus.native_model)
				helpers.assert_eq(rows[1].disabled, true)
				helpers.assert_eq(model.disabled, true)
				helpers.assert_eq(native.get_locale(), "en")
			end)
		end)
	end

	helpers.it("projects the handwritten Windows/macOS sheets and actual Linux absence (model-readout-frames)", function()
		with_model_readout_owner(function(_, _, _, native, _, corpus)
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = require("adapters.json_codec").decode, i18n = native,
					logger = helpers.make_logger_stub() }))
				for _, key in ipairs({ "specs", "caps" }) do
					local rows = assert(renderer.template_rows(corpus[key].section, {}, {}, {}))
					local expected = corpus[key].platform_rows[platform]
					helpers.assert_eq(#rows, #expected)
					for index, row in ipairs(rows) do
						helpers.assert_eq(row.separator, expected[index].separator)
						helpers.assert_eq(row.label, expected[index].label)
						helpers.assert_eq(row.disabled, expected[index].disabled)
						helpers.assert_nil(row.action)
					end
				end
			end
		end)
	end)

	helpers.it("restores genuine cached owners after a raised body (model-readout-frames)", function()
		local raised = {}
		local ok, err = pcall(function()
			with_model_readout_owner(function() error(raised, 0) end)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_eq(rawequal(err, raised), true)
	end)
end)


helpers.describe("Readout native constructor failure inverse (model-readout-frames)", function()
	helpers.it("restores the real private source owner when the catalogue open refuses (model-readout-frames)", function()
		local previous_open, previous_getenv = io.open, os.getenv
		local target = helpers.shared("modules/llm/models.json")
		local refused = 0
		io.open = function(path, ...)
			if path == target then refused = refused + 1; return nil, "owned catalogue open refusal" end
			return previous_open(path, ...)
		end
		local ok, err = pcall(function()
			with_model_readout_owner(function() error("refused constructor must not deliver its body") end)
		end)
		io.open = previous_open
		helpers.assert_eq(ok, false)
		helpers.assert_eq(refused, 1, "the actual catalogue reader must reach the native refusal")
		helpers.assert_true(tostring(err):find("cannot open models.json", 1, true) ~= nil, tostring(err))
		helpers.assert_eq(rawequal(os.getenv, previous_getenv), true)
	end)
end)


--- Reads handwritten expectations for the actual catalogue's first two families.
--- @return table expected
local function catalogue_boundary_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/model_catalogue_boundaries.json"), "rb"))
	local raw = file:read("*a"); assert(file:close())
	return assert(require("adapters.json_codec").decode(raw))
end

--- Finds an existing provider's real published model list.
--- @param rows table Native selector rows.
--- @param caption string Actual shipped provider caption.
--- @return table family_rows
local function catalogue_provider_rows(rows, caption)
	for _, row in ipairs(rows) do if row.label == caption then return row.items end end
	error("actual curated provider is missing: " .. caption)
end

helpers.describe("Model catalogue presentation boundaries", function()
	helpers.it("the actual per-model origin consumes its boundary and retains selection/source callbacks (model-catalogue-boundaries)", function()
		with_model_readout_owner(function(selector, ctx, menu, native, calls)
			local expected = catalogue_boundary_corpus()
			local declaration = menu.get_array(expected.boundaries.origin.section)
			local original = declaration[1]
			local ok, detail = xpcall(function()
				local sheet = model_readout_sheet(selector.build(ctx), expected.first_family_model)
				local position = expected.uninstalled_origin_position.hs
				helpers.assert_eq(sheet[position], { separator = true })
				helpers.assert_eq(sheet[1].label, native.get("menu.llm.select_model"))
				helpers.assert_type(sheet[1].action, "function")
				helpers.assert_type(sheet[position + 2].action, "function", "the actual model source callback stays native")
				helpers.assert_eq(#calls, 0)
				declaration[1] = { type = "label", id = "model_origin_marker", i18n = expected.published_marker_key,
					platforms = { "ahk", "hs" }, unavailable = "hide" }
				sheet = model_readout_sheet(selector.build(ctx), expected.first_family_model)
				helpers.assert_eq(sheet[position].label, expected.marker_english,
					"the unchanged real selector consumes the live shared origin boundary")
				helpers.assert_eq(sheet[position].disabled, true)
				helpers.assert_nil(sheet[position].action)
				sheet[1].action()
				helpers.assert_eq(calls, { expected.first_family_model })
				declaration[1] = { type = "command", id = "unowned_model_origin", i18n = expected.published_marker_key }
				helpers.assert_eq(selector.build(ctx), {}, "an unbound origin frame cannot fall back to native presentation")
				helpers.assert_eq(calls, { expected.first_family_model })
			end, debug.traceback)
			declaration[1] = original
			if not ok then error(detail, 0) end
			local sheet = model_readout_sheet(selector.build(ctx), expected.first_family_model)
			helpers.assert_eq(sheet[expected.uninstalled_origin_position.hs], { separator = true })
			helpers.assert_eq(#calls, 1)
		end)
	end)

	helpers.it("the actual second populated family consumes its boundary and retains model order (model-catalogue-boundaries)", function()
		with_model_readout_owner(function(selector, ctx, menu, _, calls)
			local expected = catalogue_boundary_corpus()
			local root, declaration = menu.get_root(), menu.get_array(expected.boundaries.family.section)
			local original = declaration[1]
			local ok, detail = xpcall(function()
				local rows = catalogue_provider_rows(selector.build(ctx), expected.provider_caption)
				helpers.assert_true(rows[1].label:find(expected.first_family_model, 1, true) ~= nil)
				helpers.assert_eq(rows[2], { separator = true })
				helpers.assert_true(rows[3].label:find(expected.second_family_model, 1, true) ~= nil)
				declaration[1] = { type = "label", id = "model_family_marker", i18n = expected.published_marker_key,
					platforms = { "ahk", "hs" }, unavailable = "hide" }
				rows = catalogue_provider_rows(selector.build(ctx), expected.provider_caption)
				helpers.assert_eq(rows[2].label, expected.marker_english,
					"the actual family grouping consumes its current shared boundary")
				helpers.assert_eq(rows[2].disabled, true)
				helpers.assert_nil(rows[2].action)
				helpers.assert_true(rows[1].label:find(expected.first_family_model, 1, true) ~= nil)
				helpers.assert_true(rows[3].label:find(expected.second_family_model, 1, true) ~= nil)
				rows[3].items[1].action()
				helpers.assert_eq(calls, { expected.second_family_model })
				root[expected.boundaries.family.section] = nil
				helpers.assert_eq(selector.build(ctx), {}, "a missing family boundary cannot become an undeclared separator")
				helpers.assert_eq(calls, { expected.second_family_model })
			end, debug.traceback)
			root[expected.boundaries.family.section] = declaration
			declaration[1] = original
			if not ok then error(detail, 0) end
			local rows = catalogue_provider_rows(selector.build(ctx), expected.provider_caption)
			helpers.assert_eq(rows[2], { separator = true })
			helpers.assert_eq(#calls, 1)
		end)
	end)

	helpers.it("the real renderer projects both inert boundaries and the actual Linux absence (model-catalogue-boundaries)", function()
		with_model_readout_owner(function(_, _, _, native)
			local expected = catalogue_boundary_corpus()
			local Renderer, Json = require("menu.renderer"), require("adapters.json_codec")
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(Renderer.new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = Json.decode, i18n = native, logger = require("infra.logger") }))
				for _, key in ipairs({ "family", "origin" }) do
					local boundary = expected.boundaries[key]
					helpers.assert_eq(renderer.template_rows(boundary.section, {}, {}, {}), boundary.projections[platform])
				end
			end
		end)
	end)
end)


local function hardware_boundary_corpus()
	local file = assert(io.open(helpers.shared("tests/corpus/menus/model_hardware_boundary.json"), "rb"))
	local bytes = assert(file:read("*a")); assert(file:close())
	return assert(require("adapters.json_codec").decode(bytes))
end

helpers.describe("Actual model hardware boundary (model-hardware-boundary)", function()
	helpers.it("consumes shared presentation and retains authentic value-based hardware presence (model-hardware-boundary)", function()
		with_model_readout_owner(function(selector, ctx, menu, _, calls)
			local expected = hardware_boundary_corpus()
			local actual
			for _, provider in ipairs(ctx.models_mgr.get_presets()) do
				for _, family in ipairs(provider.families or {}) do
					for _, model in ipairs(family.models or {}) do
						if model.name == expected.native_model then actual = model end
					end
				end
			end
			helpers.assert_not_nil(actual, "the hardware subject must come from the genuine current catalogue")
			helpers.assert_eq(actual.hardware_requirements.ollama, expected.hardware_ollama)
			local root, declaration = menu.get_root(), menu.get_array(expected.section)
			local original, hardware = declaration[1], actual.hardware_requirements
			local function hardware_sheet()
				local rows = model_readout_sheet(selector.build(ctx), expected.native_model)
				local position
				for index, row in ipairs(rows) do if row.label == expected.header.hs then position = index end end
				return rows, position
			end
			local ok, detail = xpcall(function()
				local rows, position = hardware_sheet()
				helpers.assert_type(position, "number")
				helpers.assert_eq(rows[position - 1], { separator = true })
				helpers.assert_eq(rows[position].disabled, true)
				helpers.assert_nil(rows[position].action)
				helpers.assert_eq(rows[position + 1].label, string.format("Download: %s GB", expected.hardware_ollama.download_gb))
				helpers.assert_eq(rows[position + 2].label, string.format("Memory (RAM): %s GB", expected.hardware_ollama.ram_gb))
				helpers.assert_type(rows[position + 1].action, "function")
				helpers.assert_type(rows[position + 2].action, "function")
				rows[position + 1].action(); rows[position + 2].action()
				helpers.assert_eq(#calls, 0, "existing hardware noop readouts must not select/install a model")
				declaration[1] = { type = "label", id = "hand_hardware_marker", i18n = expected.marker_key,
					platforms = { "ahk", "hs" }, unavailable = "hide" }
				rows, position = hardware_sheet()
				helpers.assert_eq(rows[position - 1].label, expected.marker_english)
				helpers.assert_eq(rows[position - 1].disabled, true)
				helpers.assert_nil(rows[position - 1].action)
				helpers.assert_eq(rows[position].label, expected.header.hs)
				rows[1].action()
				helpers.assert_eq(calls, { expected.native_model })
				declaration[1] = { type = "command", id = "unbound_hardware_marker", i18n = expected.marker_key }
				helpers.assert_eq(selector.build(ctx), {}, "unbound hardware presentation refuses the actual selector")
				helpers.assert_eq(calls, { expected.native_model })
				root[expected.section] = nil
				helpers.assert_eq(selector.build(ctx), {}, "withdrawn hardware declaration has no native separator fallback")
				root[expected.section] = declaration; declaration[1] = original
				-- Withdrawal uses the genuine private record; no invented shipped missing record.
				actual.hardware_requirements = { ollama = {} }
				rows, position = hardware_sheet()
				helpers.assert_eq(position ~= nil, expected.empty_ollama_map_header_visible.hs)
				actual.hardware_requirements = nil
				rows, position = hardware_sheet()
				helpers.assert_eq(position ~= nil, expected.missing_hardware_header_visible.hs)
				helpers.assert_eq(calls, { expected.native_model })
			end, debug.traceback)
			actual.hardware_requirements = hardware; root[expected.section] = declaration; declaration[1] = original
			if not ok then error(detail, 0) end
			local rows, position = hardware_sheet()
			helpers.assert_type(position, "number")
			helpers.assert_eq(rows[position - 1], { separator = true })
			helpers.assert_true(rawequal(actual.hardware_requirements, hardware))
			helpers.assert_eq(actual.hardware_requirements.ollama, expected.hardware_ollama)
			helpers.assert_eq(calls, { expected.native_model })
		end)
	end)

	helpers.it("projects the actual inert boundary and genuine Linux absence (model-hardware-boundary)", function()
		with_model_readout_owner(function(_, _, _, native)
			local expected = hardware_boundary_corpus()
			for _, platform in ipairs({ "ahk", "hs", "linux" }) do
				local renderer = assert(require("menu.renderer").new({ platform = platform,
					manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
					json_decode = require("adapters.json_codec").decode, i18n = native, logger = require("infra.logger") }))
				helpers.assert_eq(renderer.template_rows(expected.section, {}, {}, {}), expected.projections[platform])
			end
		end)
	end)
end)
