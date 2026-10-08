--- tests/unit/ui/menu/menu_llm/test_api_panel_system1_entries.lua

--- ==============================================================================
--- MODULE: API Panel Providers and System 1-Only Entries (macOS)
--- DESCRIPTION:
--- The API entries menu offers an "add" row for every provider of
--- api_providers.json, in the catalogue's order. An entry of a decisions
--- provider (TypeSafe's Jev) serves the agent's System 1 only: adding it keeps
--- the prediction backend, proves the key with the shared decisions probe
--- before anything is saved, and the entry pickers never list it; its own
--- Test and Remove rows manage it.
---
--- ROOT CAUSES ENCODED:
--- 1. A Jev entry is not a chat model: made the active entry, every
---    prediction would be sent to an endpoint that cannot answer one.
--- 2. The probe verdict helpers were locals declared after the add action's
---    closure, so the post-add Test resolved them to a nil global and the
---    verdict of an accepted probe was never shown.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local CATALOGUE = (function()
	local fh = assert(io.open(helpers.shared("modules/llm/api_providers.json"), "r"))
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end)()

local FRESH = {
	"modules.llm", "infra.i18n", "infra.logger", "infra.dialog_util",
	"infra.notifications", "infra.manifest_menu", "ui.menu.menu_llm.api_panel",
}

--- Installs the panel's doubles around the real catalogue.
--- @param args table { entries, active_id, prompts, persist_ok, test_verdict }.
--- @return table world
local function install(args)
	local world = {
		entries = args.entries, active_id = args.active_id or "", tests = {}, persisted = {},
		notifications = {}, warmups = 0, prompts = args.prompts or {}, prompt_index = 0, checks = 0,
	}
	world.api_remote = {
		PROVIDER_ORDER = CATALOGUE.provider_order,
		PROVIDERS = CATALOGUE.providers,
		get_entries = function() return world.entries end,
		set_entries = function(value) world.entries = value end,
		get_active_entry_id = function() return world.active_id end,
		set_active_entry_id = function(value) world.active_id = value end,
		get_active_entry = function()
			for _, entry in ipairs(world.entries) do
				if entry.id == world.active_id then return entry end
			end
			return nil
		end,
		get_test_request_spec = function() return { system_prompt = "s", user_text = "u", temperature = 0, max_tokens = 16 } end,
		check_availability = function(_, on_available)
			world.checks = world.checks + 1
			on_available()
			return true
		end,
		test_request = function(entry, spec, on_ok, on_fail)
			world.tests[#world.tests + 1] = { entry = entry, spec = spec }
			if args.test_verdict == false then
				on_fail("request_failed", { status = 401, message = "bad key" })
			else
				on_ok('{"ok":{"choice":"yes"}}', 42)
			end
			return true
		end,
	}
	package.loaded["modules.llm"] = {
		api_remote = world.api_remote,
		persist_api_entries = function(callback, options)
			world.persisted[#world.persisted + 1] = options or {}
			callback(args.persist_ok ~= false, nil, args.persist_ok ~= false)
		end,
	}
	package.loaded["infra.i18n"] = { get = function(key)
		if key == "menu.llm.api_unreachable_body" then return '"%s" did not respond' end
		if key == "menu.llm.api_remove_confirm_title" then return "Remove %s?" end
		return key
	end }
	package.loaded["infra.logger"] = { debug = function() end, info = function() end, warn = function() end,
		error = function() end }
	package.loaded["infra.dialog_util"] = {
		text_prompt = function()
			world.prompt_index = world.prompt_index + 1
			return "OK", world.prompts[world.prompt_index]
		end,
		block_alert = function(_, _, first) return first end,
	}
	package.loaded["infra.notifications"] = {
		notify = function(title, body, level)
			world.notifications[#world.notifications + 1] = { title = title, body = body, level = level }
			return true
		end,
	}
	local command_renderer = assert(require("menu.renderer").new({
		platform = "hs",
		manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
		json_decode = require("adapters.json_codec").decode,
		i18n = {
			get = package.loaded["infra.i18n"].get,
			-- These command rows never request a translated section.
			section = function() return {} end,
		},
		logger = helpers.make_logger_stub(),
	}))
	package.loaded["infra.manifest_menu"] = {
		command_row = command_renderer.command_row,
		template_rows = command_renderer.template_rows,
		get_array = command_renderer.get_array, render_rows = function(rows) return rows end }
	package.loaded["ui.menu.menu_llm.api_panel"] = nil
	world.panel = require("ui.menu.menu_llm.api_panel")
	world.ctx = {
		state = { llm_backend = "api", llm_model = "gpt-4o-mini" },
		paused = false,
		is_paused = function() return false end,
		keymap = { reset_predictions = function() return true end },
		update_menu = function() end,
		WarmupCtrl = { warmup = function() world.warmups = world.warmups + 1 end },
	}
	return world
end

--- The rows of the add submenu.
local function add_rows(rows)
	for _, row in ipairs(rows) do
		if type(row.items) == "table" and row.label:find("api_add_entry", 1, true) then return row.items end
	end
	return nil
end

--- The row whose label starts with a prefix.
local function row_starting(rows, prefix)
	for _, row in ipairs(rows) do
		if type(row.label) == "string" and row.label:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

local OPENAI = { id = "chat", provider = "openai", token = "k-chat", model = "gpt-4o-mini", label = "Chat" }
local JEV = { id = "jev", provider = "typesafe", token = "k-jev", model = "jev-latest", label = "Jev" }

helpers.describe("API panel: providers and System 1-only entries (macOS)", function()
	helpers.it("offers to add every provider of the catalogue, in its order", function()
		helpers.with_fresh_modules(FRESH, function()
			local world = install({ entries = {} })
			local _, rows = world.panel.build(world.ctx)
			local items = add_rows(rows)
			helpers.assert_eq(#items, #CATALOGUE.provider_order)
			for index, provider_id in ipairs(CATALOGUE.provider_order) do
				helpers.assert_eq(items[index].label, "➕ " .. CATALOGUE.providers[provider_id].label, "catalogue order")
			end
			for _, id in ipairs({ "openrouter", "groq", "together", "fireworks", "backboard", "typesafe", "openrouter_jev" }) do
				helpers.assert_true(CATALOGUE.providers[id] ~= nil, id .. " is in the catalogue")
			end
		end)
	end)

	helpers.it("adds a Jev entry without making it the prediction backend, after the decisions probe", function()
		helpers.with_fresh_modules(FRESH, function()
			local world = install({ entries = { OPENAI }, active_id = "chat",
				prompts = { CATALOGUE.providers.typesafe.base_url, "k-new", "jev-latest" } })
			local _, rows = world.panel.build(world.ctx)
			local typesafe_row = row_starting(add_rows(rows), "➕ TypeSafe (Jev)")
			helpers.assert_true(typesafe_row.action() == true, "the probe is sent")
			helpers.assert_eq(world.checks, 0, "no chat availability check")
			helpers.assert_eq(#world.tests, 1, "the decisions probe")
			helpers.assert_eq(world.tests[1].entry.provider, "typesafe")
			helpers.assert_nil(world.tests[1].spec, "the decisions probe needs no chat spec")
			helpers.assert_eq(world.active_id, "chat", "the prediction backend is kept")
			helpers.assert_eq(#world.entries, 2, "the proven entry is kept")
			helpers.assert_eq(#world.persisted, 1, "and saved")
			helpers.assert_eq(world.notifications[1].level, "success", "the verdict is shown")
			helpers.assert_eq(world.warmups, 1, "the kept backend warms up again")
		end)
	end)

	helpers.it("rolls a refused Jev entry back with the provider's verdict", function()
		helpers.with_fresh_modules(FRESH, function()
			local world = install({ entries = { OPENAI }, active_id = "chat", test_verdict = false,
				prompts = { CATALOGUE.providers.typesafe.base_url, "k-bad", "jev-latest" } })
			local _, rows = world.panel.build(world.ctx)
			row_starting(add_rows(rows), "➕ TypeSafe (Jev)").action()
			helpers.assert_eq(#world.entries, 1, "rolled back")
			helpers.assert_true(world.entries[1] == OPENAI)
			helpers.assert_eq(#world.persisted, 0, "nothing saved")
			helpers.assert_eq(world.notifications[1].level, "error")
			helpers.assert_true(world.notifications[1].body:find("[401] bad key", 1, true) ~= nil,
				"the provider's own message: " .. world.notifications[1].body)
		end)
	end)

	helpers.it("keeps Jev entries out of the pickers, with their own Test and Remove rows", function()
		helpers.with_fresh_modules(FRESH, function()
			local world = install({ entries = { OPENAI, JEV }, active_id = "chat" })
			local _, rows = world.panel.build(world.ctx)
			-- Every entry is named after its provider and model (api-entry-auto-name)
			helpers.assert_nil(row_starting(rows, "typesafe/jev-latest"), "not selectable as the prediction backend")
			helpers.assert_true(row_starting(rows, "openai/gpt-4o-mini") ~= nil)
			for _, row in ipairs(world.panel.build_model_picker(world.ctx)) do
				helpers.assert_true(row.label ~= "typesafe/jev-latest", "absent from the model picker")
			end

			local test = row_starting(rows, "menu.llm.api_test_entry (typesafe/jev-latest)")
			helpers.assert_true(test.action() == true)
			helpers.assert_eq(world.tests[1].entry.id, "jev", "the Jev entry is probed, not the active one")

			local remove = row_starting(rows, "🗑️ menu.llm.api_remove_entry (typesafe/jev-latest)")
			helpers.assert_true(remove.action() == true)
			helpers.assert_eq(#world.entries, 1)
			helpers.assert_eq(world.entries[1].id, "chat")
			helpers.assert_eq(world.active_id, "chat", "the active entry is kept")
			helpers.assert_eq(world.persisted[1].delete_entry_ids[1], "jev", "its key is deleted")
		end)
	end)

	helpers.it("shows the verdict of the probe offered after adding a chat entry", function()
		helpers.with_fresh_modules(FRESH, function()
			local world = install({ entries = {}, prompts = { "https://api.groq.com/openai/v1", "k-groq",
				"llama-3.3-70b-versatile" } })
			local _, rows = world.panel.build(world.ctx)
			row_starting(add_rows(rows), "➕ Groq").action()
			helpers.assert_eq(world.checks, 1, "the chat availability check")
			helpers.assert_eq(world.active_id, world.entries[1].id, "a chat entry becomes the prediction backend")
			helpers.assert_eq(#world.tests, 1, "the accepted probe is sent")
			local titles = {}
			for _, n in ipairs(world.notifications) do titles[#titles + 1] = n.title end
			helpers.assert_eq(table.concat(titles, ","), "menu.llm.api_validated_title,menu.llm.api_test_ok_title",
				"the probe's verdict is shown")
		end)
	end)
end)


helpers.describe("complete API presentation frames", function()
	for _, section in ipairs({ "llm_api_selection_frame", "llm_api_active_boundary", "llm_api_system1_frame" }) do
		helpers.it("refuses an unowned declared API frame and repairs the same genuine entries: " .. section, function()
			helpers.with_fresh_modules(FRESH, function()
				local world = install({ entries = { OPENAI, JEV }, active_id = "chat" })
				local owner = package.loaded["infra.manifest_menu"]
				local frame = assert(owner.get_array(section))
				local original = frame[1]
				local function build()
					if section == "llm_api_selection_frame" then return world.panel.build_model_picker(world.ctx) end
					local _, rows = world.panel.build(world.ctx)
					return rows
				end
				local original_entries, original_active = world.entries, world.active_id
				local ok, err = xpcall(function()
					helpers.assert_true(#build() > 0, "the real original entries produce this complete frame")
					frame[1] = { type = "command", id = "unbound_api_frame", i18n = "button.cancel" }
					helpers.assert_eq(build(), {}, "a declared command without its native owner refuses the whole frame")
					helpers.assert_true(rawequal(world.entries, original_entries))
					helpers.assert_eq(world.active_id, original_active)
					helpers.assert_eq(#world.persisted, 0)
					helpers.assert_eq(#world.tests, 0)
					helpers.assert_eq(world.warmups, 0)
				end, debug.traceback)
				frame[1] = original
				helpers.assert_true(rawequal(package.loaded["infra.manifest_menu"], owner))
				helpers.assert_true(rawequal(frame[1], original))
				if not ok then error(err, 0) end
				helpers.assert_true(#build() > 0, "exact original declaration repair uses the retained entry owner")
			end)
		end)
	end
end)
