--- tests/unit/ui/menu/test_hotstring_bulk_checkboxes.lua

--- ==============================================================================
--- MODULE: Regression — explicit categories and independent bulk selection
--- DESCRIPTION:
--- Category commands set their requested posture through one atomic owner, keep
--- the root engine stopped, and withhold UI publication after refused saves.
--- Language and whole-tree section controls retain their existing
--- independent checkbox contracts until their own scoped migration.
--- ==============================================================================

local helpers = require("tests.helpers")
local CaptionFixture = require("tests.support.personal_menu_caption_fixture")

local RETIRED = {
	"menu.hotstrings.category_on", "menu.hotstrings.category_off",
	"menu.hotstrings.enable_all", "menu.hotstrings.disable_all",
}

--- A context whose groups each carry two real sections, a separator and a
--- module placeholder.
--- @param sections_on boolean Whether every section is on.
--- @param group_on boolean Whether every group gate is on.
--- @param files table|nil Hotstring files, default { "alpha.toml" }.
--- @return table ctx, table batches
local function context(sections_on, group_on, files)
	local batches = {}
	local function sections_of()
		return {
			{ name = "one" },
			{ name = "-" },
			{ name = "module", is_module_placeholder = true },
			{ name = "two" },
		}
	end
	local ctx = {
		paused = false,
		hotfiles = files or { "alpha.toml" },
		get_group_name = function(path) return (path:gsub("%.toml$", "")) end,
		state = { hotstrings = {}, keymap = true, sections_order_overrides = {} },
		applyTriggerChar = function(value) return value end,
		keymap = {
			is_group_enabled = function() return group_on end,
			get_sections = function() return sections_of() end,
			is_section_enabled = function() return sections_on end,
			set_category_scope_enabled = function(names, enabled, publish)
				batches[#batches + 1] = { names = names, enabled = enabled }
				return publish()
			end,
			set_groups_sections_enabled = function(changes, enabled)
				batches[#batches + 1] = { changes = changes, enabled = enabled }
				return true
			end,
			start = function() return true end,
			is_started = function() return true end,
		},
		save_prefs = function() return true end,
		updateMenu = function() end,
		notify_feature = function() end,
	}
	return ctx, batches
end

--- Asserts that no row of `rows`, at any depth, still draws a retired label.
--- @param rows table
--- @param where string
local function assert_no_retired(rows, where)
	local seen = 0
	local function walk(list)
		for _, row in ipairs(list or {}) do
			local label = row.label or row.title
			if type(label) == "string" then
				seen = seen + 1
				for _, retired in ipairs(RETIRED) do
					helpers.assert_true(label ~= retired, where .. " still draws the retired '" .. retired .. "' row")
				end
			end
			walk(row.items or row.menu)
		end
	end
	walk(rows)
	helpers.assert_true(seen > 0, where .. " drew no labelled row, so the absence proves nothing")
end

helpers.describe("hotstring scope commands and independent bulk checkboxes", function()
	for _, posture in ipairs({ true, false }) do
		for _, enabled in ipairs({ true, false }) do
			helpers.it("a category offers the explicit scope command " .. tostring(enabled)
				.. " behind group gate " .. tostring(posture), function()
				local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
				local ctx, batches = context(not posture, posture)
				ctx.state.keymap = false
				local starts, saves, updates = 0, 0, 0
				ctx.keymap.start = function() starts = starts + 1; return true end
				ctx.save_prefs = function() saves = saves + 1; return true end
				ctx.updateMenu = function() updates = updates + 1 end
				local rows = hotstrings.build_groups(ctx, nil, { group_counts = {} })
				local sub = rows[1] and rows[1].submenu
				helpers.assert_true(type(sub) == "table", "the rendered category child must survive intact")
				helpers.assert_eq(sub[1].title, "menu.hotstrings.scope_enable_all")
				helpers.assert_eq(sub[2].title, "menu.hotstrings.scope_disable_all")
				helpers.assert_nil(sub[1].checked, "an explicit command is not a state switch")
				helpers.assert_nil(sub[2].checked, "both commands remain available in either posture")
				sub[enabled and 1 or 2].fn()
				helpers.assert_eq(#batches, 1, "one click is one category-owner transaction")
				helpers.assert_eq(batches[1], { names = { "alpha" }, enabled = enabled })
				helpers.assert_eq(ctx.state.hotstrings.alpha, enabled, "persist the selected category gate")
				helpers.assert_eq({ saves, updates, starts }, { 1, 1, 0 })
				helpers.assert_eq(ctx.state.keymap, false, "editing a category never starts the root engine")
			end)
		end

		helpers.it("a language submenu opens with one checkbox, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx, batches = context(posture, posture)
			local rows = hotstrings.build_language_bulk_actions(ctx, { "alpha" })
			helpers.assert_eq(#rows, 1, "the pair is one row")
			helpers.assert_eq(rows[1].label, "menu.hotstrings.enable_all_sections")
			helpers.assert_eq(rows[1].checked, posture, "ticked exactly when every category and section is on")
			rows[1].action()
			helpers.assert_eq(#batches, 1, "one click is one batch")
			helpers.assert_eq(batches[1].enabled, not posture, "the click switches the whole language")
		end)

		helpers.it("the top of the menu has one switch for every section, ticked " .. tostring(posture), function()
			local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
			local ctx, batches = context(posture, posture, { "alpha.toml", "beta.toml" })
			local switch = hotstrings.all_sections_switch(ctx)
			helpers.assert_eq(switch.checked, posture, "ticked exactly when every group and section is on")
			helpers.assert_eq(type(switch.action), "function", "the switch must act")
			switch.action()
			helpers.assert_eq(#batches, 1, "one click is one batch")
			helpers.assert_eq(batches[1].enabled, not posture, "the click switches the whole tree")
			helpers.assert_eq(#batches[1].changes, 2, "every group is in the batch")
		end)
	end

	helpers.it("one group with a section off leaves every « all » checkbox unticked", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx = context(true, true, { "alpha.toml", "beta.toml" })
		ctx.keymap.is_section_enabled = function(group, section)
			return not (group == "beta" and section == "two")
		end
		helpers.assert_eq(hotstrings.all_sections_switch(ctx).checked, false,
			"« all on » means all of them: one section off is not all")
		local rows = hotstrings.build_language_bulk_actions(ctx, { "alpha", "beta" })
		helpers.assert_eq(rows[1].checked, false, "the language checkbox reads every one of its groups")
		helpers.assert_eq(hotstrings.build_language_bulk_actions(ctx, { "alpha" })[1].checked, true,
			"and only its own groups")
	end)

	helpers.it("a paused script can choose its next category without starting capture", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx, batches = context(true, true)
		ctx.paused = true
		ctx.state.keymap = false
		local starts = 0
		ctx.keymap.start = function() starts = starts + 1; return true end
		local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
		helpers.assert_eq(type(sub[2].fn), "function", "selection is separate from input capture")
		sub[2].fn()
		helpers.assert_eq(batches[1].enabled, false)
		helpers.assert_eq(starts, 0)
		helpers.assert_eq(ctx.paused, true)
		helpers.assert_eq(ctx.state.keymap, false)
	end)

	for _, enabled in ipairs({ true, false }) do
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.it("a refused category save " .. refusal .. " restores posture " .. tostring(enabled), function()
				local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
				local ctx, batches = context(not enabled, not enabled)
				ctx.state.hotstrings.alpha = not enabled
				ctx.state.hotstrings.beta = true
				ctx.state.keymap = false
				local saves, updates = 0, 0
				ctx.save_prefs = function()
					saves = saves + 1
					if refusal == "throw" then error("category save fixture refused") end
					if refusal == "false" then return false end
					return nil
				end
				ctx.updateMenu = function() updates = updates + 1 end
				local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
				sub[enabled and 1 or 2].fn()
				helpers.assert_eq(#batches, 1, "the category owner received one requested mutation")
				helpers.assert_eq(saves, 1)
				helpers.assert_eq(updates, 0, "a refused save is never acknowledged by rebuilding the tray")
				helpers.assert_eq(ctx.state.hotstrings, { alpha = not enabled, beta = true })
				helpers.assert_eq(ctx.state.keymap, false)
			end)
		end
	end

	helpers.it("a refused tray refresh cannot undo an acknowledged category save", function()
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		local ctx, batches = context(false, false)
		ctx.state.hotstrings.alpha = false
		local saved_choice, refreshes
		ctx.save_prefs = function() saved_choice = ctx.state.hotstrings.alpha; return true end
		ctx.updateMenu = function() refreshes = (refreshes or 0) + 1; error("tray refresh fixture refused") end
		local sub = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu
		sub[1].fn()
		helpers.assert_eq(#batches, 1)
		helpers.assert_eq(saved_choice, true)
		helpers.assert_eq(refreshes, 1)
		helpers.assert_eq(ctx.state.hotstrings.alpha, true,
			"a UI failure cannot make the public choice disagree with the committed file and registry")
	end)

	for _, enabled in ipairs({ true, false }) do
		for _, posture in ipairs({ true, false }) do
			helpers.it("personal scope command " .. tostring(enabled) .. " behind gate " .. tostring(posture), function()
				local custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
				local ctx, batches = context(not posture, posture, { "personal.toml" })
				ctx.state.trigger_char = "★"
				ctx.state.keymap = false
				ctx.paused = true
				ctx.hotstring_editor = { open = function() end }
				local starts, saves, updates = 0, 0, 0
				ctx.keymap.start = function() starts = starts + 1; return true end
				ctx.save_prefs = function() saves = saves + 1; return true end
				ctx.updateMenu = function() updates = updates + 1 end
				local built = CaptionFixture.build_custom(custom, ctx, { group_counts = {} })
				local rows = built.submenu
				helpers.assert_true(type(rows) == "table", "the personal menu must use the shared declaration")
				helpers.assert_eq(rows[1].title, "menu.hotstrings.scope_enable_all")
				helpers.assert_eq(rows[2].title, "menu.hotstrings.scope_disable_all")
				helpers.assert_nil(rows[enabled and 1 or 2].checked)
				assert_no_retired(rows, "the personal submenu")
				helpers.assert_true(rows[enabled and 1 or 2].fn())
				helpers.assert_eq(batches, { { names = { "personal", "custom" }, enabled = enabled } })
				helpers.assert_eq({ saves, updates, starts }, { 1, 1, 0 })
				helpers.assert_eq(ctx.state.hotstrings, { personal = enabled, custom = enabled })
				helpers.assert_eq(ctx.state.keymap, false)
				helpers.assert_eq(ctx.paused, true)
			end)
		end
		for _, refusal in ipairs({ "false", "nil", "throw" }) do
			helpers.it("personal scope restores every prior gate after " .. refusal .. " save for " .. tostring(enabled), function()
				local custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
				local ctx, batches = context(not enabled, not enabled, { "personal.toml", "personal_ext_work.toml" })
				ctx.state.trigger_char = "★"
				ctx.state.hotstrings = { personal = not enabled, custom = not enabled, unrelated = true }
				ctx.hotstring_editor = { open = function() end }
				local updates, saved = 0, nil
				ctx.save_prefs = function()
					saved = { ctx.state.hotstrings.personal, ctx.state.hotstrings.personal_ext_work, ctx.state.hotstrings.custom }
					if refusal == "throw" then error("personal save fixture refused") end
					if refusal == "false" then return false end
				end
				ctx.updateMenu = function() updates = updates + 1 end
				local rows = CaptionFixture.build_custom(custom, ctx, { group_counts = {} }).submenu
				helpers.assert_true(type(rows) == "table", "personal scope commands must render")
				helpers.assert_eq(rows[enabled and 1 or 2].fn(), false)
				helpers.assert_eq(batches, { { names = { "personal", "personal_ext_work", "custom" }, enabled = enabled } })
				helpers.assert_eq(saved, { enabled, enabled, enabled }, "one candidate reaches the canonical save")
				helpers.assert_eq(updates, 0)
				helpers.assert_eq(ctx.state.hotstrings, { personal = not enabled, custom = not enabled, unrelated = true },
					"restore existing and absent gates after refusal")
			end)
		end
	end
	helpers.it("a personal file submenu owns only its group and keeps shared command order", function()
		helpers.with_stub_scope({ "infra.personal_file_scope", "ui.menu.menu_hotstrings_custom" }, function()
			-- This projection fixture owns a synthetic acknowledged group. Actual
			-- provenance, native route and refusal behavior have their own owner test.
			local bindings = 0
			package.loaded["infra.personal_file_scope"] = { bind = function()
				bindings = bindings + 1
				return function() return true end
			end }
			local custom = helpers.load_with_stubs("ui.menu.menu_hotstrings_custom")
			local ctx, batches = context(false, false, { "personal.toml", "personal_ext_work.toml" })
			ctx.state.trigger_char = "★"
			ctx.hotfile_paths = { personal_ext_work = "/user/work.toml" }
			ctx.hotstring_editor = { open = function() end }
			local rows = CaptionFixture.build_custom(custom, ctx, { group_counts = {} }).submenu
			local file
			for _, row in ipairs(rows) do if row.title == "work" then file = row end end
			helpers.assert_true(file ~= nil, "the personal file must survive native subtree rendering")
			helpers.assert_eq(file.menu[1].title, "menu.hotstrings.scope_enable_all")
			helpers.assert_eq(file.menu[2].title, "menu.hotstrings.scope_disable_all")
			helpers.assert_eq(file.menu[3].title, "menu.hotstrings.open_file")
			helpers.assert_eq(file.menu[4].title, "-")
			helpers.assert_eq(file.menu[5].title, "one")
			helpers.assert_eq(file.menu[1].fn(), true)
			helpers.assert_eq(batches, { { names = { "personal_ext_work" }, enabled = true } })
			helpers.assert_eq(ctx.state.hotstrings, { personal_ext_work = true }, "sibling choices remain absent")
			helpers.assert_eq(bindings, 1, "one native admission binding per rendered file")
		end)
	end)

end)


--- Exercises real command rendering and DeferredWork; only the native timer is injected.
--- @param committed boolean Native scheduling acknowledgement.
--- @param body function Real category callback observations.
local function with_category_file(committed, body, change_label)
	helpers.with_stub_scope({ "infra.manifest_menu", "infra.deferred_work",
		"adapters.timer_scheduler", "modules.keymap", "modules.dynamic_hotstrings",
		"ui.menu.menu_hotstrings" }, function()
		-- Category file opening neither starts nor inspects these unrelated engines.
		package.loaded["modules.keymap"] = { DEFAULT_STATE = {} }
		package.loaded["modules.dynamic_hotstrings"] = { DEFAULT_STATE = {} }
		local callbacks, launches = {}, {}
		package.loaded["adapters.timer_scheduler"] = { after = function(_, callback)
			callbacks[#callbacks + 1] = callback
			return {}, committed
		end }
		local hotstrings = helpers.load_with_stubs("ui.menu.menu_hotstrings")
		hs.execute = function(command) launches[#launches + 1] = command; return "", true end
		package.loaded["infra.manifest_menu"] = assert(require("menu.renderer").new({
			platform = "hs", manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
			json_decode = function(bytes)
				local document = hs.json.decode(bytes)
				if change_label then document.hotstring_file_commands[1].i18n = "fixture.category.file.command" end
				return document
			end,
			i18n = { get = function(key) return key end, section = function(key) return key end },
			logger = require("infra.logger"),
		}))
		package.loaded["ui.menu.menu_hotstrings"] = nil
		hotstrings = require("ui.menu.menu_hotstrings")
		body(hotstrings, callbacks, launches)
	end)
end

helpers.describe("shared category file command", function()
	helpers.it("shared category file: consumes the actual declared label", function()
		with_category_file(true, function(hotstrings)
			local ctx = context(true, true)
			ctx.hotfile_paths = { alpha = "/user/a.toml" }
			helpers.assert_eq(hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu[3].title,
				"fixture.category.file.command")
		end, true)
	end)
	for _, committed in ipairs({ true, false }) do
		helpers.it("shared category file: returns the native deferred scheduling acknowledgement " .. tostring(committed), function()
			with_category_file(committed, function(hotstrings, callbacks, launches)
				local ctx = context(false, false)
				ctx.paused = true
				ctx.hotfile_paths = { alpha = "/user/category file.toml" }
				local saves = 0
				ctx.save_prefs = function() saves = saves + 1; return true end
				local command = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu[3]
				helpers.assert_eq(command.title, "menu.hotstrings.open_file")
				helpers.assert_true(command.disabled ~= true, "configuration remains available under pause")
				ctx.hotfile_paths.alpha = "/foreign/replaced.toml"
				helpers.assert_eq(command.fn(), committed)
				helpers.assert_eq(#callbacks, 1)
				helpers.assert_eq(#launches, 0, "the deferred native owner has not delivered yet")
				if committed then callbacks[1]() end
				helpers.assert_eq(#launches, committed and 1 or 0)
				if committed then
					helpers.assert_eq(launches[1], "open " .. require("infra.text_utils").shell_quote("/user/category file.toml"))
				end
				helpers.assert_eq(saves, 0)
			end)
		end)
	end
	helpers.it("shared category file: refuses a held callback after the native execute port is withdrawn", function()
		with_category_file(true, function(hotstrings, callbacks, launches)
			local ctx = context(true, true)
			ctx.hotfile_paths = { alpha = "/user/a.toml" }
			local command = hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu[3]
			hs.execute = nil
			helpers.assert_eq(command.fn(), false)
			helpers.assert_eq(#callbacks, 0)
			helpers.assert_eq(#launches, 0)
			helpers.assert_eq(hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu[3].disabled, true)
		end)
	end)
end)


--- The actual common-category owner consumes a fresh genuine manifest renderer.
local function with_common_section_frame(body)
	return helpers.with_stub_scope({ "infra.logger", "infra.manifest_menu", "ui.menu.menu_hotstrings",
		"ui.menu.menu_hotstrings_custom", "ui.menu.menu_hotstrings_management" }, function()
		local translator = require("infra.i18n")
		local renderer = assert(require("menu.renderer").new({ platform = "hs",
			manifest_path = function() return require("infra.paths").shared("modules/menu/menu_manifest.json") end,
			json_decode = require("adapters.json_codec").decode, i18n = translator, logger = require("infra.logger"),
		}))
		package.loaded["infra.manifest_menu"] = renderer
		local hotstrings = require("ui.menu.menu_hotstrings")
		local ctx = context(true, true)
		ctx.keymap.get_sections = function() return {
			{ name = "-" }, { name = "one", count = 1, description = "Independent One" },
			{ name = "-" }, { name = "-" }, { name = "two", count = 2, description = "Independent Two" },
		} end
		local root = renderer.get_root()
		assert(type(root) == "table" and type(root.hotstrings_parameter_boundary) == "table")
		return body({ root = root, context = ctx,
			build = function() return hotstrings.build_groups(ctx, nil, { group_counts = { alpha = 3 } }) end })
	end)
end

helpers.describe("common hotstring sections consume the genuine shared boundary", function()
	helpers.it("retains source order and suppresses old leading and duplicate separators", function()
		with_common_section_frame(function(f)
			local rows = f.build()
			helpers.assert_eq(#rows, 1)
			local children = assert(rows[1].submenu)
			helpers.assert_eq(#children, 6)
			helpers.assert_eq(children[4].title, "Independent One (1)")
			helpers.assert_eq(children[5].title, "-")
			helpers.assert_eq(children[6].title, "Independent Two (2)")
			helpers.assert_nil(children[5].fn); helpers.assert_nil(children[5].menu)
			helpers.assert_type(children[4].fn, "function"); helpers.assert_type(children[6].fn, "function")
		end)
	end)
	for _, damage in ipairs({ "absent", "empty", "duplicate", "label" }) do
		helpers.it("refuses " .. damage .. " boundary before common-category publication and recovers", function()
			with_common_section_frame(function(f)
				helpers.assert_eq(#f.build(), 1, "the genuine category exists before withdrawal")
				local saved = f.root.hotstrings_parameter_boundary
				local called, detail = xpcall(function()
					if damage == "absent" then f.root.hotstrings_parameter_boundary = nil
					elseif damage == "empty" then f.root.hotstrings_parameter_boundary = {}
					elseif damage == "duplicate" then f.root.hotstrings_parameter_boundary = { { type = "---" }, { type = "---" } }
					else f.root.hotstrings_parameter_boundary = { { type = "label", i18n = "common.cancel" } } end
					helpers.assert_eq(f.build(), {}, "the old native separator cannot bypass declaration refusal")
				end, debug.traceback)
				f.root.hotstrings_parameter_boundary = saved
				if not called then error(detail, 0) end
				helpers.assert_eq(#f.build(), 1, "restoring the genuine shared declaration recovers construction")
			end)
		end)
	end
end)


--- Keeps actual native binding, TimerScheduler, DeferredWork and original opener.
--- Only ordinary hs.timer primitives are controlled; adapter receipts are genuine.
local function with_personal_info_leaf(body)
	with_category_file(true, function()
		local callbacks, native_timers = {}, {}
		local previous_new = hs.timer.new
		hs.timer.new = function(seconds, callback)
			local running = false
			local native = {
				seconds = seconds,
				start = function(self) running = true; return self end,
				stop = function(self) running = false; return self end,
				running = function() return running end,
			}
			callbacks[#callbacks + 1], native_timers[#native_timers + 1] = callback, native
			return native
		end
		package.loaded["adapters.timer_scheduler"] = nil
		package.loaded["infra.deferred_work"] = nil
		package.loaded["infra.manifest_menu"] = nil
		package.loaded["ui.menu.menu_hotstrings"] = nil
		local timer
		local called, detail = xpcall(function()
			timer = require("adapters.timer_scheduler")
			local renderer = assert(require("infra.manifest_menu"))
			local hotstrings = require("ui.menu.menu_hotstrings")
			local ctx = context(true, true)
			local opened, saves, updates, notifications = 0, 0, 0, 0
			ctx.applyTriggerChar = function(value) return "@ " .. value end
			ctx.state.personal_info = false
			ctx.personal_info = { open_editor = function() opened = opened + 1 end }
			ctx.module_sections = { alpha = { personal_info = { mod_id = "personal_info",
				description = "Independent personal info" } } }
			ctx.keymap.get_sections = function() return { { name = "personal_info", is_module_placeholder = true } } end
			ctx.save_prefs = function() saves = saves + 1; return true end
			ctx.updateMenu = function() updates = updates + 1 end
			ctx.notify_feature = function() notifications = notifications + 1 end
			body({ renderer = renderer, root = renderer.get_root(), context = ctx, callbacks = callbacks,
				timer = timer, native_timers = native_timers,
				counts = function() return opened, saves, updates, notifications end,
				build = function() return hotstrings.build_groups(ctx, nil, { group_counts = {} })[1].submenu end })
		end, debug.traceback)
		local settled = timer == nil or timer.cancelAll()
		hs.timer.new = previous_new
		if not called then error(detail, 0) end
		assert(settled and timer.activeCount() == 0, "owned genuine timer registry must settle")
	end)
end

local function personal_info_native(rows)
	local title = require("infra.i18n").get("menu.shortcuts.edit_personal_info")
	for _, row in ipairs(rows or {}) do if row.title == title then return row end end
end

helpers.describe("personal-info editor original declared leaf (Mac)", function()
	helpers.it("personal-info Mac leaf: retains original checkbox, exact native callback and deferred protected opener", function()
		with_personal_info_leaf(function(f)
			local template, supplied = f.renderer.template_rows, nil
			local timer = require("adapters.timer_scheduler")
			local schedule, delay = timer.after, nil
			local called, detail = xpcall(function()
				f.renderer.template_rows = function(key, ...)
					local rows = template(key, ...)
					if key == "personal_info_editor_frame" then supplied = rows end
					return rows
				end
				timer.after = function(seconds, ...) delay = seconds; return schedule(seconds, ...) end
				local rows = f.build()
				helpers.assert_eq(rows[3].title, "-", "original declared category boundary precedes the personal provider")
				helpers.assert_nil(rows[3].fn); helpers.assert_nil(rows[3].menu)
				helpers.assert_eq(rows[4].title, "@ Independent personal info")
				helpers.assert_nil(rows[4].checked)
				local command = assert(personal_info_native(rows))
				helpers.assert_true(rawequal(command, rows[5]), "original checkbox/editor order remains")
				helpers.assert_true(rawequal(command.fn, supplied[1].action), "actual provider callback reaches native delivery")
				helpers.assert_nil(command.checked); helpers.assert_nil(command.disabled); helpers.assert_nil(command.menu)
				helpers.assert_eq(f.counts(), 0); helpers.assert_eq(#f.callbacks, 0)
				helpers.assert_eq(command.fn(), true)
				helpers.assert_eq(delay, 0.1); helpers.assert_eq(#f.callbacks, 1)
				helpers.assert_eq(f.counts(), 0, "opening waits for the retained native timer")
				f.callbacks[1]()
				local opened, saves, updates, notices = f.counts()
				helpers.assert_eq({ opened, saves, updates, notices }, { 1, 0, 0, 0 })
				f.context.personal_info.open_editor = function() error("original protected opener refuses") end
				helpers.assert_eq(command.fn(), true)
				local ok = pcall(f.callbacks[2]); helpers.assert_eq(ok, true, "original pcall still contains native opener throws")
			end, debug.traceback)
			f.renderer.template_rows, timer.after = template, schedule
			if not called then error(detail, 0) end
		end)
	end)

	helpers.it("personal-info Mac leaf: refuses a held callback after source withdrawal and accepts exact repair", function()
		with_personal_info_leaf(function(f)
			local command = assert(personal_info_native(f.build()))
			local source = assert(f.root.personal_info_editor_frame)
			local called, detail = xpcall(function()
				f.root.personal_info_editor_frame = nil
				helpers.assert_eq(command.fn(), false)
				local rows = f.build()
				helpers.assert_nil(personal_info_native(rows))
				helpers.assert_eq(rows[4].title, "@ Independent personal info", "independent original checkbox survives leaf refusal")
				helpers.assert_eq(#f.callbacks, 0); helpers.assert_eq(f.counts(), 0)
			end, debug.traceback)
			f.root.personal_info_editor_frame = source
			if not called then error(detail, 0) end
			helpers.assert_eq(command.fn(), true)
			helpers.assert_eq(#f.callbacks, 1)
		end)
	end)

	helpers.it("personal-info Mac leaf: retires queued native delivery after withdrawal and repairs through a fresh timer", function()
		with_personal_info_leaf(function(f)
			local command = assert(personal_info_native(f.build()))
			local source = assert(f.root.personal_info_editor_frame)
			local called, detail = xpcall(function()
				helpers.assert_eq(command.fn(), true)
				helpers.assert_eq(#f.callbacks, 1); helpers.assert_eq(f.timer.activeCount(), 1)
				helpers.assert_eq(f.native_timers[1].seconds, 0.1)
				f.root.personal_info_editor_frame = nil
				f.callbacks[1]()
				helpers.assert_eq(f.counts(), 0, "withdrawal before real queued delivery keeps the opener inert")
				helpers.assert_eq(f.timer.activeCount(), 0)
				helpers.assert_eq(f.native_timers[1]:running(), false, "real one-shot retirement stops its exact native timer")
				f.root.personal_info_editor_frame = source
				helpers.assert_eq(command.fn(), true)
				helpers.assert_eq(#f.callbacks, 2); helpers.assert_eq(f.timer.activeCount(), 1)
				f.callbacks[2]()
				helpers.assert_eq(f.counts(), 1, "exact source repair admits a new genuine one-shot")
				helpers.assert_eq(f.timer.activeCount(), 0)
			end, debug.traceback)
			f.root.personal_info_editor_frame = source
			if not called then error(detail, 0) end
		end)
	end)

	for _, damage in ipairs({ "array", "record", "platform", "template" }) do
		helpers.it("personal-info Mac leaf: refuses actual-template withdrawal " .. damage .. " and repairs", function()
			with_personal_info_leaf(function(f)
				local template, source = f.renderer.template_rows, assert(f.root.personal_info_editor_frame)
				local declaration, platforms = source[1], source[1].platforms
				local caption, platform = declaration.i18n, platforms[1]
				local called, detail = xpcall(function()
					f.renderer.template_rows = function(key, ...)
						local rows = template(key, ...)
						if key == "personal_info_editor_frame" then
							if damage == "array" then f.root.personal_info_editor_frame = nil
							elseif damage == "record" then declaration.i18n = "common.cancel"
							elseif damage == "platform" then platforms[1] = "ahk"
							else f.renderer.template_rows = nil end
						end
						return rows
					end
					local rows = f.build()
					helpers.assert_nil(personal_info_native(rows))
					helpers.assert_eq(rows[4].title, "@ Independent personal info")
					helpers.assert_eq(#f.callbacks, 0); helpers.assert_eq(f.counts(), 0)
				end, debug.traceback)
				f.renderer.template_rows, f.root.personal_info_editor_frame = template, source
				declaration.i18n, platforms[1] = caption, platform
				if not called then error(detail, 0) end
				helpers.assert_type(personal_info_native(f.build()).fn, "function", "actual descriptor repair restores genuine projection")
			end)
		end)
	end
end)
