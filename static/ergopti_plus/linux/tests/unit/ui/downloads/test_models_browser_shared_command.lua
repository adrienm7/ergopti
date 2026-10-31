--- tests/unit/ui/downloads/test_models_browser_shared_command.lua

--- ==============================================================================
--- MODULE: The Model Selector Button
--- DESCRIPTION:
--- Regression model-selector-page (maintainer, 2026-10-27). The tray builds one
--- button, "<emoji> <model>", that opens the model selector page; it lists no
--- model, so a tray build reads no inventory. The page's model removal runs the
--- tray's own confirmed transaction, which these cases drive through the
--- binding the build hands the page.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Exercises the browser provider with its unrelated tray surfaces isolated.
--- @param callback function Receives native rows and observable browser ports.
local function with_browser(callback)
	local names = { "ui.menu.builder", "ui.menu.llm_backend_rows", "infra.manifest_menu", "infra.paths", "infra.i18n",
		"window_titles", "action_parameter_label", "hotstrings.extensions", "hotstrings.languages",
		"_generated.locale_table", "keymap.magic_key_source", "modules.hotstrings.magic_key",
		"modules.hotstrings.preview_settings", "modules.hotstrings.repeat_key", "ui.modal",
		"ui.text_prompt", "llm.trigger_policy", "infra.version", "infra.installation",
		"updater.version_label", "updater.schedule", "ui.model_browser.bridge" }
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = package.loaded[name]
		if name == "ui.menu.llm_backend_rows" then package.loaded[name] = nil
		else package.loaded[name] = {} end
	end
	local ok, err = xpcall(function()
		local controls = { shows = 0, result = true }
		package.loaded["ui.model_browser.bridge"] = { bind = function(options) controls.bound = options end }
		local source = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver = assert(source:match("^(.*)/tests/unit/ui/"))
		package.loaded["infra.paths"] = { shared = function(relative)
			return driver .. "/../_shared/" .. relative
		end }
		-- Supply only the unrelated header prerequisite from the shipped English catalogue.
		local header_file = assert(io.open(driver .. "/../_shared/data/locales/en.json", "rb"))
		local header_raw = header_file:read("*a")
		assert(header_file:close())
		local header_labels = assert(require("json").decode(assert(header_raw)))
		local header_brand = assert(header_labels["menu.builder.active_brand"])
		assert(type(header_brand) == "string" and header_brand ~= "" and header_brand ~= "menu.builder.active_brand")
		package.loaded["infra.i18n"] = {
			get = function(key)
				if key == "menu.builder.active_brand" then return header_brand end
				-- The button's caption is its getter alone ("%s" in every locale).
				if key == "menu.llm.model_selector_caption" then return "%s" end
				return key
			end,
			section = function(key) return key end,
		}
		package.loaded["infra.manifest_menu"] = nil
		local native = require("infra.manifest_menu")
		local root, selected = native.get_root(), {}
		for _, row in ipairs(native.get_array("top_level")) do
			if row.id == "llm" then selected[#selected + 1] = row end
		end
		root.top_level = selected
		local facade = {}; for key, value in pairs(native) do facade[key] = value end
		facade.build = function(_, _, _, _, _, providers)
			-- The model row is list DATA: the shared renderer materialises it.
			return native.render_rows(providers.llm_model(), "llm_model")
		end
		package.loaded["infra.manifest_menu"] = facade
		package.loaded["ui.menu.builder"] = nil
		local Builder = require("ui.menu.builder")
		local ctx = {
			llm = {
				is_enabled = function() return false end,
				get_models = function() return {} end,
				get_backend = function() return "ollama" end,
				get_current_model = function() return "qwen3:4b" end,
			},
			webview = { show = function(kind)
				controls.kind = kind
				controls.shows = controls.shows + 1
				return controls.result
			end },
			on_quit = function() end,
		}
		callback({ ctx = ctx, controls = controls, builder = Builder, renderer = native })
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- The model selector button among native-rendered rows, at any depth: the
--- one whose title starts with the Ollama emoji of the shared brand table.
--- @param rows table Native rows.
--- @return table|nil row, table|nil siblings The rows that hold it.
local function selector_row(rows)
	local emoji = require("modules.llm.backend_brands").emoji("ollama")
	for _, row in ipairs(rows or {}) do
		if type(row.title) == "string" and row.title:sub(1, #emoji) == emoji then return row, rows end
		local nested, siblings = selector_row(row.menu)
		if nested then return nested, siblings end
	end
	return nil
end

helpers.describe("the model selector button (model-selector-page)", function()
	helpers.it("names the model after the backend emoji and opens the page with its exact acknowledgement", function()
		with_browser(function(fixture)
			local row, siblings = selector_row(fixture.builder.build(fixture.ctx))
			helpers.assert_type(row, "table")
			helpers.assert_eq(#siblings, 1, "the AI menu draws one button, no model list")
			helpers.assert_eq(row.title, require("modules.llm.backend_brands").emoji("ollama") .. " qwen3:4b")
			helpers.assert_eq(row.menu, nil, "the button opens the page, never a submenu")
			helpers.assert_true(row.disabled ~= true)
			helpers.assert_eq(row.fn(), true)
			helpers.assert_eq(fixture.controls.kind, "model_browser")
			for _, result in ipairs({ false, 1, "true" }) do
				fixture.controls.result = result
				helpers.assert_eq(row.fn(), false)
			end
			helpers.assert_eq(fixture.controls.shows, 4)
		end)
	end)

	helpers.it("disables the button without a page host and refuses a held callback after its loss", function()
		with_browser(function(fixture)
			local row = selector_row(fixture.builder.build(fixture.ctx))
			helpers.assert_type(row.fn, "function")
			fixture.ctx.webview = nil
			helpers.assert_eq(row.fn(), false)
			helpers.assert_eq(fixture.controls.shows, 0)
			row = selector_row(fixture.builder.build(fixture.ctx))
			helpers.assert_eq(row.disabled, true)
		end)
	end)
end)

helpers.describe("AI off: the tray asks Ollama for no model (ai-off-inert-linux-2026-10-22)", function()
	helpers.it("builds the button without an inventory read, AI off or on", function()
		with_browser(function(f)
			local enabled = false
			local reads = 0
			f.ctx.llm.is_enabled = function() return enabled end
			f.ctx.llm.get_models = function()
				reads = reads + 1
				return { "installed-one" }
			end
			helpers.assert_type(selector_row(f.builder.build(f.ctx)), "table",
				"the model selector stays reachable with the AI off")
			enabled = true
			helpers.assert_type(selector_row(f.builder.build(f.ctx)), "table")
			helpers.assert_eq(reads, 0, "the tray lists no model, so no build probes the Ollama inventory")
		end)
	end)
end)


--- Captures the notices the removal sends instead of showing desktop notifications.
--- @return table notices, function restore
local function scripted_notices()
	local previous = package.loaded["adapters.application_notifier"]
	local notices = {}
	package.loaded["adapters.application_notifier"] = { send = function(body, opts)
		notices[#notices + 1] = { body = body, title = opts.title, level = opts.level }
		return true
	end }
	return notices, function() package.loaded["adapters.application_notifier"] = previous end
end

--- Answers zenity's question with the given exit, recording the commands it ran.
--- @param answer boolean True presses Delete, false presses Cancel.
--- @return table commands, function restore
local function scripted_question(answer)
	local previous = os.execute
	local commands = {}
	os.execute = function(command)
		commands[#commands + 1] = command
		if command:find("command -v zenity", 1, true) then return true end
		return answer
	end
	return commands, function() os.execute = previous end
end

helpers.describe("the page removes an installed model as on Windows and macOS", function()
	--- Prepares an AI-on context listing two installed models.
	--- @param f table with_browser fixture.
	--- @return table deletes
	local function installed(f)
		-- The fixture's blank dialog owners: the question runs inline, titled as given.
		package.loaded["ui.modal"].run = function(fn) return fn() end
		package.loaded["window_titles"].compose = function(title) return title end
		local deletes = {}
		f.ctx.llm.is_enabled = function() return true end
		f.ctx.llm.get_models = function() return { "qwen:2b", "gemma:1b" } end
		f.ctx.llm.get_current_model = function() return "gemma:1b" end
		f.ctx.llm.delete_model = function(model, on_done)
			deletes[#deletes + 1] = { model = model, on_done = on_done }
			return true
		end
		f.ctx.on_menu_changed = function() deletes.refreshes = (deletes.refreshes or 0) + 1 end
		return deletes
	end

	helpers.it("linux-model-delete: Delete asks first, removes the model, then says so and redraws", function()
		with_browser(function(f)
			local deletes = installed(f)
			local notices, restore_notices = scripted_notices()
			local commands, restore_question = scripted_question(true)
			local ok, err = pcall(function()
				f.builder.build(f.ctx)
				helpers.assert_eq(f.controls.bound.delete_model("qwen:2b"), true)
				helpers.assert_true(commands[#commands]:find("menu.llm.delete_model_title", 1, true) ~= nil,
					"the removal is confirmed with the dialog the other drivers show")
				helpers.assert_eq(#deletes, 1)
				helpers.assert_eq(deletes[1].model, "qwen:2b")
				deletes[1].on_done(true, "qwen:2b")
				helpers.assert_eq(notices[1].level, "success")
				helpers.assert_eq(notices[1].title, "ollama.deleted_title")
				deletes[1].on_done(false, "qwen:2b", "model busy")
				helpers.assert_eq(notices[2].level, "error")
				helpers.assert_eq(notices[2].title, "ollama.delete_fail_title")
				helpers.assert_eq(deletes.refreshes, 2)
			end)
			restore_question(); restore_notices()
			if not ok then error(err, 0) end
		end)
	end)

	helpers.it("linux-model-delete: a declined question or a paused script removes nothing", function()
		with_browser(function(f)
			local deletes = installed(f)
			local commands, restore_question = scripted_question(false)
			local ok, err = pcall(function()
				f.builder.build(f.ctx)
				local delete_model = f.controls.bound.delete_model
				helpers.assert_eq(delete_model("qwen:2b"), false)
				helpers.assert_eq(#deletes, 0)
				-- A page still open when the script is paused asks nothing.
				local asked = #commands
				f.ctx.paused = true
				helpers.assert_eq(delete_model("qwen:2b"), false)
				helpers.assert_eq(#commands, asked)
				helpers.assert_eq(#deletes, 0)
			end)
			restore_question()
			if not ok then error(err, 0) end
		end)
	end)
end)
