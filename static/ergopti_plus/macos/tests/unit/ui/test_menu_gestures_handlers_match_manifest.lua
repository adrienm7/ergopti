--- tests/unit/ui/test_menu_gestures_handlers_match_manifest.lua

--- ==============================================================================
--- MODULE: Regression — a gesture menu row vanished from the menu (F-HIGH-5)
--- DESCRIPTION:
--- A gestures_menu entry carrying an `id` with a real registered handler was
--- declared with `type = "feature"` in manifest.toml — the generic path-based
--- idiom for items rendered elsewhere. ManifestMenu.build's "feature" branch is
--- an INTENTIONAL silent no-op reserved for legitimate path-only entries, so the
--- misclassified id-bearing entry produced identical silence: the row never
--- appeared in the rendered menu, with no error or log.
---
--- The row that was lost (the circular Spaces checkbox) is retired since the
--- wrap became its own pair of actions; the class of defect is not. This test
--- therefore holds every id-bearing gestures_menu entry to a rendered type, and
--- drives ManifestMenu.build against the REAL manifest data to prove a
--- declared, command-backed row is built, ticked from its checked_when getter
--- and wired to the command the driver registers.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds a dyn_handlers table shaped like menu_gestures.lua's real one.
--- @return table dyn_handlers id -> function(items, ctx)
local function make_dyn_handlers()
	local function noop_handler(items, _ctx)
		table.insert(items, { title = "noop" })
	end

	return {
		gesture_slots_2 = noop_handler,
		gesture_slots_3 = noop_handler,
		gesture_slots_4 = noop_handler,
		gesture_slots_5 = noop_handler,
	}
end

helpers.describe("menu_gestures: every id-bearing row is rendered by the manifest (F-HIGH-5)", function()
	helpers.it("menu_manifest.json declares no id-bearing gestures_menu entry as type=feature", function()
		-- Goes through ManifestMenu.get_array (not a bare hs.json.decode call) so this
		-- test is immune to an earlier test file's load_with_stubs({json = {...}})
		-- override permanently clobbering the shared _G.hs.json stub (test isolation
		-- footgun unrelated to this finding) — load_with_stubs always hands back a
		-- freshly `__reset()` stub regardless of what a previous test left behind.
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		local gestures_menu = ManifestMenu.get_array("gestures_menu")
		helpers.assert_true(type(gestures_menu) == "table" and #gestures_menu > 0,
			"menu_manifest.json must have a non-empty gestures_menu array")

		local with_id, misclassified = 0, {}
		for _, e in ipairs(gestures_menu) do
			if type(e) == "table" and type(e.id) == "string" then
				with_id = with_id + 1
				if e.type == "feature" then misclassified[#misclassified + 1] = e.id end
			end
		end
		helpers.assert_true(with_id >= 5, "the gestures menu must declare its id-bearing rows")
		helpers.assert_eq(#misclassified, 0,
			"type=feature is silently skipped by ManifestMenu.build (F-HIGH-5), so these rows "
				.. "would vanish with nothing said: " .. table.concat(misclassified, ", "))
	end)

	helpers.it("ManifestMenu.build renders the category switch from its declaration", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")

		-- The row is built by the RENDERER, so what the driver supplies is the
		-- behaviour and the state — which is exactly what is stubbed here.
		local fired = false
		local built = ManifestMenu.build("gestures_menu", "Gestures", make_dyn_handlers(), nil, {
			commands = { gestures_toggle = function() fired = true end },
			state_getters = {
				gestures_enabled = function() return true end,
			},
		})

		local row = nil
		for _, item in ipairs(built) do
			if type(item.fn) == "function" and item.checked == true then row = item end
		end
		helpers.assert_true(row ~= nil,
			"the gestures switch must be present, ticked from its checked_when getter — " ..
			"a type=feature misclassification makes ManifestMenu.build skip it silently (F-HIGH-5)")

		row.fn()
		helpers.assert_true(fired,
			"and clicking it must run the command the driver registered, not a no-op: a row " ..
			"rendered with no behaviour looks identical to one that works")
	end)

	-- The maintainer's first group (2026-09-30): the switch, « Restaurer les
	-- valeurs conseillées », « Tout effacer », then a separator. The two scope
	-- rows stood below the system rows until then.
	helpers.it("ManifestMenu.build opens the menu with the switch, the restore and the clear", function()
		local ManifestMenu = helpers.load_with_stubs("infra.manifest_menu")
		local i18n = require("infra.i18n")
		local fired = {}
		local function record(name) return function() fired[#fired + 1] = name end end
		local built = ManifestMenu.build("gestures_menu", "Gestures", make_dyn_handlers(), nil, {
			commands = { gestures_toggle = record("toggle"), scope_restore = record("restore"),
				scope_clear = record("clear"), system_gesture_settings = record("settings") },
			state_getters = { gestures_enabled = function() return true end },
		})
		helpers.assert_eq(built[1].title, i18n.get("menu.gestures.enable"))
		helpers.assert_eq(built[2].title, i18n.get("common.restore_recommended"))
		helpers.assert_eq(built[3].title, i18n.get("common.clear_to_system"))
		helpers.assert_eq(built[4].title, "-")
		for index = 5, #built do
			helpers.assert_true(built[index].title ~= built[2].title and built[index].title ~= built[3].title,
				"no scope row may follow the first group")
		end
		built[2].fn()
		built[3].fn()
		helpers.assert_eq(fired, { "restore", "clear" }, "each row runs the command registered under its id")
	end)
end)

-- Independent mode expectations predate this presentation migration. Drive the
-- actual native menu owner and renderer; only the host/runtime ports are controlled.
local mode_fixture_modules = {
	"json", "menu.renderer", "infra.manifest_menu", "infra.i18n", "infra.logger",
	"modules.gestures", "ui.menu.menu_utils", "infra.dialog_util", "ui.action_picker",
	"ui.menu.shortcut_utils", "infra.deferred_work", "ui.menu.menu_gestures",
}
local function mode_json(path)
	local file = assert(io.open(path, "rb"))
	local bytes = file:read("*a")
	file:close()
	return require("json").decode(bytes)
end
local function with_mode_fixture(options, callback)
	return helpers.with_fresh_modules(mode_fixture_modules, function()
		options = options or {}
		local corpus = mode_json(helpers.shared("tests/corpus/menus/gesture_slot_modes.json"))
		local locale = options.locale or "en"
		local strings = mode_json(helpers.shared("data/locales/" .. locale .. ".json"))
		local i18n = {
			get = function(key) return strings[key] or key end,
			section = function(key) return strings[key] or key end,
		}
		local logger = helpers.make_logger_stub()
		local renderer = assert(require("menu.renderer").new({
			platform = options.platform or "hs",
			manifest_path = function() return helpers.shared("modules/menu/menu_manifest.json") end,
			json_decode = require("json").decode, i18n = i18n, logger = logger,
		}))
		local root = renderer.get_root()
		root.gesture_slots = { ["2"] = { "swipe_2_left" }, ["3"] = {}, ["4"] = {}, ["5"] = {} }
		local fixture = { mode = options.mode or "x1", writes = {}, saves = 0, updates = 0,
			renderer = renderer, root = root, corpus = corpus, strings = strings, locale = locale }
		fixture.gestures = {
			get_action = function() return "none" end,
			get_action_label = function() return "None" end,
			get_action_parameter = function() return "" end,
			get_mode = function() return fixture.mode end,
			get_sensitivity = function() return 3.5 end,
			get_sg_names = function() return {} end,
			system_gesture_conflicts = function() return {} end,
			system_pinch_enabled = function() return nil end,
			open_system_gestures = function() return true end,
			refresh_system_gestures = function() return true end,
			set_mode = function(slot, value)
				fixture.writes[#fixture.writes + 1] = { slot, value }
				fixture.mode = value
				if options.setter and #fixture.writes == 1 then return options.setter() end
				return true
			end,
		}
		package.loaded["infra.manifest_menu"] = renderer
		package.loaded["infra.i18n"] = i18n
		package.loaded["infra.logger"] = logger
		package.loaded["modules.gestures"] = { DEFAULT_STATE = { gestures = true } }
		for _, name in ipairs({ "ui.menu.menu_utils", "infra.dialog_util", "ui.action_picker",
			"ui.menu.shortcut_utils", "infra.deferred_work" }) do package.loaded[name] = {} end
		local owner = require("ui.menu.menu_gestures")
		function fixture.build()
			return owner.build({
				gestures = fixture.gestures, state = { gestures = true }, paused = false,
				save_prefs = function()
					fixture.saves = fixture.saves + 1
					if options.save then return options.save() end
					return true
				end,
				updateMenu = function() fixture.updates = fixture.updates + 1 end,
			})
		end
		function fixture.rows()
			local item = fixture.build()
			for _, row in ipairs(item.submenu) do
				if row.title == i18n.get("gesture.slots.swipe_2_left") .. " : None" then
					return assert(row.menu[3].menu)
				end
			end
			error("actual rendered swipe slot missing")
		end
		return callback(fixture)
	end)
end

helpers.describe("Gestures: shared swipe mode declaration and actual native mutation owner", function()
	helpers.it("pins independent mode declarations without inventing other-platform capabilities", function()
		with_mode_fixture({}, function(f)
			local actual = f.root[f.corpus.section]
			helpers.assert_eq(#actual, #f.corpus.rows)
			for index, expected in ipairs(f.corpus.rows) do
				for key, value in pairs(expected) do
					if key ~= "value" then helpers.assert_eq(actual[index][key], value, key) end
				end
			end
		end)
	end)
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("renders both existing locale captions through the actual owner: " .. locale, function()
			with_mode_fixture({ locale = locale }, function(f)
				local rows = f.rows()
				helpers.assert_eq(#rows, 2)
				for index, expected in ipairs(f.corpus.captions[locale]) do
					helpers.assert_eq(rows[index].title, expected)
					helpers.assert_type(rows[index].fn, "function")
				end
			end)
		end)
	end
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("projects only existing mode capability: " .. platform, function()
			with_mode_fixture({ platform = platform }, function(f)
				local fired = {}
				local rows = f.renderer.template_rows(f.corpus.section, {
					gesture_mode_single = function() fired[#fired + 1] = "x1"; return true end,
					gesture_mode_incremental = function() fired[#fired + 1] = "incremental"; return true end,
				}, { gesture_mode_is_single = function() return true end,
					gesture_mode_is_incremental = function() return false end })
				helpers.assert_eq(#rows, #f.corpus.platform_rows[platform])
				if platform == "hs" then
					helpers.assert_true(rows[1].action())
					helpers.assert_eq(fired, { "x1" })
				end
			end)
		end)
	end
	for _, state in ipairs({ { "x1", true, false }, { "incremental", false, true }, { "future_mode", false, false } }) do
		helpers.it("checks only the actual native mode: " .. state[1], function()
			with_mode_fixture({ mode = state[1] }, function(f)
				local rows = f.rows()
				helpers.assert_eq(rows[1].checked == true, state[2])
				helpers.assert_eq(rows[2].checked == true, state[3])
			end)
		end)
	end
	helpers.it("follows shared order while retaining each value's actual callback", function()
		with_mode_fixture({}, function(f)
			local definition = f.root[f.corpus.section]
			definition[1], definition[2] = definition[2], definition[1]
			local rows = f.rows()
			helpers.assert_eq(rows[1].title, f.corpus.captions.en[2])
			helpers.assert_true(rows[1].fn())
			helpers.assert_eq(f.writes, { { "swipe_2_left", "incremental" } })
			helpers.assert_eq(f.saves, 1)
			helpers.assert_eq(f.updates, 1)
		end)
	end)
	helpers.it("reads caption, check predicate and platform mutations from the declaration", function()
		with_mode_fixture({}, function(f)
			local row = f.root[f.corpus.section][1]
			row.i18n = "menu.gestures.mode_incremental"
			row.checked_when = { "gesture_mode_is_incremental" }
			local rows = f.rows()
			helpers.assert_eq(rows[1].title, f.corpus.captions.en[2])
			helpers.assert_eq(false, rows[1].checked == true)
			row.platforms = { "linux" }
			rows = f.rows()
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1].title, f.corpus.captions.en[2])
		end)
	end)
	helpers.it("actual swipe provider independently honors platform hiding", function()
		with_mode_fixture({}, function(f)
			f.root[f.corpus.section][1].platforms = { "linux" }
			local rows = f.rows()
			helpers.assert_eq(#rows, 1)
			helpers.assert_eq(rows[1].title, f.corpus.captions.en[2])
			helpers.assert_true(rows[1].fn())
			helpers.assert_eq(f.mode, f.corpus.rows[2].value)
		end)
	end)
	helpers.it("actual swipe provider independently honors the declared checked reader", function()
		with_mode_fixture({}, function(f)
			f.root[f.corpus.section][1].checked_when = { "gesture_mode_is_incremental" }
			helpers.assert_eq(false, f.rows()[1].checked == true)
		end)
	end)
	helpers.it("a held callback rereads current native mode before compensating refused publication", function()
		with_mode_fixture({ save = function() return false end }, function(f)
			local held = f.rows()[2].fn
			f.mode = "future_mode"
			helpers.assert_eq(false, held())
			helpers.assert_eq(f.mode, "future_mode")
			helpers.assert_eq(f.writes, { { "swipe_2_left", "incremental" }, { "swipe_2_left", "future_mode" } })
			helpers.assert_eq(f.updates, 0)
		end)
	end)
	for _, refusal in ipairs({
		{ "false", function() return false end }, { "nil", function() return nil end },
		{ "truthy", function() return "accepted" end }, { "throw", function() error("native refusal") end },
	}) do
		for _, edge in ipairs({ "setter", "save" }) do
			helpers.it("preserves exact mutation/publication acknowledgement: " .. edge .. " " .. refusal[1], function()
				local options = {}; options[edge] = refusal[2]
				with_mode_fixture(options, function(f)
					helpers.assert_eq(false, f.rows()[2].fn())
					helpers.assert_eq(f.mode, "x1")
					helpers.assert_eq(f.writes, { { "swipe_2_left", "incremental" }, { "swipe_2_left", "x1" } })
					helpers.assert_eq(f.saves, edge == "save" and 1 or 0)
					helpers.assert_eq(f.updates, 0)
				end)
			end)
		end
	end
	for _, edge in ipairs({ "get_mode", "set_mode" }) do
		helpers.it("held callback refuses a withdrawn native owner: " .. edge, function()
			with_mode_fixture({}, function(f)
				local held = f.rows()[2].fn
				f.gestures[edge] = nil
				helpers.assert_eq(false, held())
				helpers.assert_eq(f.writes, {})
				helpers.assert_eq(f.saves, 0)
			end)
		end)
	end
	for _, transition in ipairs({ { "incremental", "x1", 1 }, { "x1", "incremental", 2 } }) do
		helpers.it("publishes both existing native mode directions: " .. transition[2], function()
			with_mode_fixture({ mode = transition[1] }, function(f)
				helpers.assert_true(f.rows()[transition[3]].fn())
				helpers.assert_eq(f.mode, transition[2])
				helpers.assert_eq(f.writes, { { "swipe_2_left", transition[2] } })
				helpers.assert_eq(f.saves, 1)
				helpers.assert_eq(f.updates, 1)
			end)
		end)
	end
	for _, refusal in ipairs({ { "nil", function() return nil end },
		{ "throw", function() error("mode unavailable") end } }) do
		helpers.it("held mode callback refuses unreadable current state: " .. refusal[1], function()
			with_mode_fixture({}, function(f)
				local held = f.rows()[2].fn
				f.gestures.get_mode = refusal[2]
				helpers.assert_eq(false, held())
				helpers.assert_eq(f.writes, {})
				helpers.assert_eq(f.saves, 0)
			end)
		end)
	end
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("check template delegates retained readiness and strict callback receipt: " .. platform, function()
			with_mode_fixture({ platform = platform }, function(f)
				f.root.mode_template_probe = { {
					type = "check", id = "mode_probe", i18n = "menu.gestures.mode_single",
					checked_when = { "mode_probe_checked" }, disabled_when = { "mode_probe_blocked" },
				} }
				local blocked, calls = false, 0
				local commands = { mode_probe = function() calls = calls + 1; return false end }
				local getters = { mode_probe_checked = function() return true end,
					mode_probe_blocked = function() return not blocked end }
				local rows = f.renderer.template_rows("mode_template_probe", commands, getters)
				helpers.assert_true(rows[1].checked)
				blocked = true
				helpers.assert_eq(false, rows[1].action())
				helpers.assert_eq(calls, 0)
				blocked = false
				helpers.assert_eq(false, rows[1].action())
				helpers.assert_eq(calls, 1)
				helpers.assert_nil(f.renderer.template_rows("mode_template_probe", {}, getters))
			end)
		end)
	end
end)

-- Reuse the actual-owner fixture; only replace host runtime ports and the
-- locale section port with the unchanged shared decoration owner.
local function with_gesture_controls(options, callback)
	options = options or {}
	return with_mode_fixture({ locale = options.locale, platform = options.platform, mode = "incremental" }, function(f)
		local controls = mode_json(helpers.shared("tests/corpus/menus/gesture_slot_controls.json"))
		local labels = require("menu.labels")
		package.loaded["infra.i18n"].section = function(key)
			return labels.decorate_section(f.strings[key] or key)
		end
		f.control_state = { gestures = true }
		f.control_paused, f.sensitivity, f.action = false, 3.5, "none"
		f.control_writes, f.queue, f.picker_specs, f.conflicts = {}, {}, {}, 0
		f.gestures.get_sensitivity = function() return f.sensitivity end
		f.gestures.set_sensitivity = function(slot, value)
			f.control_writes[#f.control_writes + 1] = { slot, value }
			f.sensitivity = value
			if options.setter and #f.control_writes == 1 then return options.setter() end
			return true
		end
		f.gestures.get_action = function() return f.action end
		f.gestures.get_sg_names = function() return { "none", "copy", "paste" } end
		f.gestures.get_action_label = function(action) return f.strings["sg_labels." .. action] or action end
		f.gestures.set_action = function(slot, value)
			f.control_writes[#f.control_writes + 1] = { slot, value }
			f.action = value
			if options.setter and #f.control_writes == 1 then return options.setter() end
			return true
		end
		f.gestures.on_action_changed = function() f.conflicts = f.conflicts + 1 end
		package.loaded["infra.deferred_work"].after = function(delay, work, tag)
			f.queue[#f.queue + 1] = { delay = delay, work = work, tag = tag }
			return true
		end
		package.loaded["ui.action_picker"].open = function(spec, picked)
			f.picker_specs[#f.picker_specs + 1] = spec
			if not options.cancel then picked("copy") end
		end
		package.loaded["ui.menu.shortcut_utils"].picker_parameter_fields = function() return {} end
		local owner = require("ui.menu.menu_gestures")
		function f.control_build()
			return owner.build({ gestures = f.gestures, state = f.control_state, paused = f.control_paused,
				save_prefs = function()
					f.saves = f.saves + 1
					if options.save then return options.save() end
					return true
				end,
				updateMenu = function() f.updates = f.updates + 1 end })
		end
		function f.control_slot()
			local item = f.control_build()
			local slot = f.root.gesture_slots["2"][1]
			local prefix = (f.strings["gesture.slots." .. slot] or "gesture.slots." .. slot) .. " : "
			for _, row in ipairs(item.submenu) do
				if type(row.title) == "string" and row.title:sub(1, #prefix) == prefix then return row end
			end
			return nil
		end
		function f.drain()
			while #f.queue > 0 do table.remove(f.queue, 1).work() end
		end
		f.controls = controls
		return callback(f)
	end)
end

helpers.describe("Gestures: declared sensitivity head and real action-choice owner", function()
	helpers.it("pins the independently authored ordered fixed sections", function()
		with_gesture_controls({}, function(f)
			for section, expected in pairs(f.controls.sections) do
				helpers.assert_eq(f.root[section], expected)
			end
		end)
	end)
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("hides Mac-only sensitivity/choice declarations on other actual projections: " .. platform, function()
			with_gesture_controls({ platform = platform }, function(f)
				local head = f.renderer.template_rows("gesture_sensitivity_head")
				local choice = f.renderer.template_rows("gesture_change_action", {
					gesture_slot_change_action = function() error("projection must not click a choice") end,
				}, { gesture_slot_choice_ready = function() return true end })
				helpers.assert_eq(#head, f.controls.platform_rows[platform].sensitivity_head)
				helpers.assert_eq(#choice, f.controls.platform_rows[platform].change_action)
			end)
		end)
	end
	helpers.it("the actual tap child reaches the same picker without a sensitivity submenu", function()
		with_gesture_controls({}, function(f)
			f.root.gesture_slots["2"] = { "tap_2" }
			local slot = assert(f.control_slot())
			helpers.assert_eq(#slot.menu, 1)
			slot.menu[1].fn(); f.drain()
			helpers.assert_eq(f.control_writes, { { "tap_2", "copy" } })
		end)
	end)
	helpers.it("picker cancellation creates no runtime or publication effect", function()
		with_gesture_controls({ cancel = true }, function(f)
			assert(f.control_slot()).menu[1].fn(); f.drain()
			helpers.assert_eq(f.control_writes, {})
			helpers.assert_eq(f.saves, 0)
			helpers.assert_eq(f.conflicts, 0)
		end)
	end)
	for _, refusal in ipairs({ "paused", "disabled" }) do
		helpers.it("initial choice preserves the native disabled UI: " .. refusal, function()
			with_gesture_controls({}, function(f)
				if refusal == "paused" then f.control_paused = true else f.control_state.gestures = false end
				local slot = assert(f.control_slot())
				helpers.assert_true(slot.disabled)
				helpers.assert_true(slot.menu[1].disabled)
				helpers.assert_eq(false, slot.menu[1].fn())
				helpers.assert_eq(f.queue, {})
			end)
		end)
	end
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		helpers.it("retains decorated heading, inert hint, numeric choices and action caption: " .. locale, function()
			with_gesture_controls({ locale = locale }, function(f)
				local slot = assert(f.control_slot())
				local rows = slot.menu[4].menu
				local captions = f.controls.caption_snapshots[locale]
				helpers.assert_eq(rows[1].title, "— " .. captions["menu.gestures.sensitivity_label"] .. " —")
				helpers.assert_eq(rows[2].title, captions["menu.gestures.sensitivity_hint"])
				for _, index in ipairs({ 1, 2 }) do
					helpers.assert_true(rows[index].disabled)
					helpers.assert_nil(rows[index].fn)
					helpers.assert_nil(rows[index].checked)
				end
				helpers.assert_eq(rows[3].title, "-")
				helpers.assert_eq(#rows, 21)
				for index, value in ipairs(f.controls.sensitivity_values) do
					local expected = string.format("%.1f", value)
					if value == 3.5 then expected = expected .. " " .. captions["menu.gestures.default_sensitivity"] end
					helpers.assert_eq(rows[index + 3].title, expected)
					helpers.assert_eq(rows[index + 3].checked == true, value == 3.5)
				end
				helpers.assert_eq(slot.menu[1].title, captions["menu.gestures.change_action"])
			end)
		end)
	end
	helpers.it("actual prefix and action child metadata independently drive rendered order/captions/platform", function()
		with_gesture_controls({}, function(f)
			local head = f.root.gesture_sensitivity_head
			head[1], head[2] = head[2], head[1]
			local rows = assert(f.control_slot()).menu[4].menu
			helpers.assert_eq(rows[1].title, f.strings["menu.gestures.sensitivity_hint"])
			head[2].i18n = "menu.gestures.sensitivity_hint"
			rows = assert(f.control_slot()).menu[4].menu
			helpers.assert_eq(rows[2].title, "— " .. f.strings["menu.gestures.sensitivity_hint"] .. " —")
			head[2].platforms = { "linux" }
			rows = assert(f.control_slot()).menu[4].menu
			helpers.assert_eq(#rows, 20)
			f.root.gesture_change_action[1].i18n = "ui_apps.btn_refresh"
			helpers.assert_eq(assert(f.control_slot()).menu[1].title, f.strings["ui_apps.btn_refresh"])
		end)
	end)
	helpers.it("real change-action callback defers the original picker and publishes through its owner", function()
		with_gesture_controls({}, function(f)
			local choose = assert(f.control_slot()).menu[1].fn
			helpers.assert_nil(choose(), "opening a deferred picker is not a publication receipt")
			helpers.assert_eq(#f.queue, 1)
			helpers.assert_eq(f.queue[1].delay, 0.05)
			helpers.assert_eq(f.queue[1].tag, "menu_gestures.action_chooser")
			f.drain()
			helpers.assert_eq(#f.picker_specs, 1)
			helpers.assert_eq(f.picker_specs[1].items[1].id, "copy", "actual source catalogue offers the selected action")
			helpers.assert_eq(f.control_writes, { { "swipe_2_left", "copy" } })
			helpers.assert_eq(f.action, "copy")
			helpers.assert_eq(f.saves, 1)
			helpers.assert_eq(f.conflicts, 1)
			helpers.assert_eq(f.updates, 2, "original commit plus action-owner refresh are retained")
		end)
	end)
	for _, edge in ipairs({ "get_action", "set_action", "get_sensitivity", "set_sensitivity" }) do
		helpers.it("retains actual native capability withdrawal refusal: " .. edge, function()
			with_gesture_controls({}, function(f)
				local slot = assert(f.control_slot())
				local sensitivity = edge:find("sensitivity", 1, true) ~= nil
				local held = sensitivity and slot.menu[4].menu[4].fn or slot.menu[1].fn
				f.gestures[edge] = nil
				if sensitivity then helpers.assert_eq(false, held()) else held(); f.drain() end
				helpers.assert_eq(f.control_writes, {})
				helpers.assert_eq(f.saves, 0)
				helpers.assert_eq(f.updates, 0)
				helpers.assert_eq(f.conflicts, 0)
			end)
		end)
	end
	helpers.it("shared choice readiness refuses retained delivery after category withdrawal", function()
		with_gesture_controls({}, function(f)
			local held = assert(f.control_slot()).menu[1].fn
			f.control_state.gestures = false
			helpers.assert_eq(false, held())
			helpers.assert_eq(f.queue, {})
		end)
	end)
	for _, refusal in ipairs({ { "false", function() return false end }, { "nil", function() return nil end },
		{ "truthy", function() return "accepted" end }, { "throw", function() error("refused") end } }) do
		for _, edge in ipairs({ "setter", "save" }) do
			for _, setting in ipairs({ "sensitivity", "action" }) do
				helpers.it("retains actual " .. setting .. " refusal compensation: " .. edge .. " " .. refusal[1], function()
					local options = {}; options[edge] = refusal[2]
					with_gesture_controls(options, function(f)
						local slot = assert(f.control_slot())
						if setting == "sensitivity" then
							f.sensitivity = 6.0
							helpers.assert_eq(false, slot.menu[4].menu[4].fn())
							helpers.assert_eq(f.sensitivity, 6.0)
							helpers.assert_eq(f.control_writes, { { "swipe_2_left", 1.0 }, { "swipe_2_left", 6.0 } })
						else
							slot.menu[1].fn(); f.action = "paste"; f.drain()
							helpers.assert_eq(f.action, "paste")
							helpers.assert_eq(f.control_writes, { { "swipe_2_left", "copy" }, { "swipe_2_left", "paste" } })
							helpers.assert_eq(f.conflicts, 0)
						end
						helpers.assert_eq(f.saves, edge == "save" and 1 or 0)
							helpers.assert_eq(f.updates, 0)
					end)
				end)
			end
		end
	end
end)


-- Whole swipe ordering imports the unchanged action declaration and carries
-- actual native mode/sensitivity child data through a shared template.
local function with_swipe_template(options, callback)
	return with_gesture_controls(options or {}, function(f)
		f.swipe = mode_json(helpers.shared("tests/corpus/menus/gesture_swipe_template.json"))
		return callback(f)
	end)
end
helpers.describe("Gestures: shared swipe-child template and real native payloads", function()
	helpers.it("pins the independently handwritten complete child template", function()
		with_swipe_template({}, function(f)
			helpers.assert_eq(f.root[f.swipe.section], f.swipe.rows)
		end)
	end)
	for _, locale in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja",
		"ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
		for _, mode in ipairs({ "x1", "incremental" }) do
			helpers.it("retains complete current-value captions and native posture: " .. locale .. " " .. mode, function()
				with_swipe_template({ locale = locale }, function(f)
					f.mode = mode
					local rows = assert(f.control_slot()).menu
					helpers.assert_eq(#rows, 4)
					helpers.assert_eq(rows[1].title, f.controls.caption_snapshots[locale]["menu.gestures.change_action"])
					helpers.assert_eq(rows[2], { title = "-" })
					helpers.assert_eq(rows[3].title, f.swipe.captions[locale][mode == "x1" and "mode_x1" or "mode_incremental"])
					helpers.assert_eq(rows[4].title, f.swipe.captions[locale].sensitivity_3_5)
					helpers.assert_eq(rows[4].disabled == true, mode ~= "incremental")
					helpers.assert_eq(#rows[3].menu, 2)
					helpers.assert_eq(#rows[4].menu, 21, "existing heading/hint/separator and eighteen native values")
					helpers.assert_eq(f.queue, {}, "building cannot queue native action selection")
					helpers.assert_eq(f.saves, 0)
				end)
			end)
		end
	end
	for _, platform in ipairs({ "ahk", "hs", "linux" }) do
		helpers.it("projects only the existing whole swipe capability: " .. platform, function()
			with_swipe_template({ platform = platform }, function(f)
				local ready, deliveries = true, 0
				local rows = assert(f.renderer.template_rows(f.swipe.section, {
					gesture_slot_change_action = function() deliveries = deliveries + 1; return false end,
				}, { gesture_slot_choice_ready = function() return ready end,
					gesture_mode_current_label = function() return "Existing mode" end,
					gesture_sensitivity_current_label = function() return "3.5" end,
					gesture_mode_incremental_ready = function() return false end,
				}, { gesture_mode_options = {}, gesture_sensitivity_options = {} }))
				helpers.assert_eq(#rows, #f.swipe.platform_rows[platform])
				if platform == "hs" then
					helpers.assert_eq(rows[1].action(), false)
					helpers.assert_eq(deliveries, 1)
					ready = false
					helpers.assert_eq(rows[1].action(), false)
					helpers.assert_eq(deliveries, 1, "included command retains current shared readiness refusal")
				end
			end)
		end)
	end
	helpers.it("follows declared whole-child order with each actual mutation owner intact", function()
		with_swipe_template({}, function(f)
			local definition = f.root[f.swipe.section]
			definition[3], definition[4] = definition[4], definition[3]
			f.mode = "x1"
			local rows = assert(f.control_slot()).menu
			helpers.assert_eq(rows[3].title, f.swipe.captions.en.sensitivity_3_5)
			helpers.assert_true(rows[3].disabled)
			helpers.assert_eq(rows[4].title, f.swipe.captions.en.mode_x1)
			helpers.assert_true(rows[4].menu[2].fn())
			helpers.assert_eq(f.writes, { { "swipe_2_left", "incremental" } })
			helpers.assert_eq(f.saves, 1)
			helpers.assert_eq(f.updates, 1)
		end)
	end)
	helpers.it("reads group caption metadata rather than a native prefix", function()
		with_swipe_template({}, function(f)
			f.root[f.swipe.section][3].i18n = "menu.gestures.sensitivity_current"
			helpers.assert_eq(assert(f.control_slot()).menu[3].title,
				f.strings["menu.gestures.sensitivity_prefix"] .. f.corpus.captions.en[2])
		end)
	end)
	helpers.it("the actual provider follows group platform hiding without losing native siblings", function()
		with_swipe_template({}, function(f)
			f.root[f.swipe.section][4].platforms = { "linux" }
			local rows = assert(f.control_slot()).menu
			helpers.assert_eq(#rows, 3)
			helpers.assert_eq(rows[3].title, f.swipe.captions.en.mode_incremental)
			helpers.assert_true(rows[3].menu[1].fn())
			helpers.assert_eq(f.mode, "x1")
		end)
	end)
	helpers.it("the actual sensitivity parent delegates its declared readiness predicate", function()
		with_swipe_template({}, function(f)
			f.mode = "x1"
			f.root[f.swipe.section][4].disabled_when = { "gesture_slot_choice_ready" }
			helpers.assert_nil(assert(f.control_slot()).menu[4].disabled)
		end)
	end)
	for _, field in ipairs({ "caption_getter", "id" }) do
		helpers.it("refuses a missing actual group payload owner: " .. field, function()
			with_swipe_template({}, function(f)
				f.root[f.swipe.section][3][field] = "unknown_native_group_owner"
				helpers.assert_nil(f.control_slot())
				helpers.assert_eq(f.queue, {})
				helpers.assert_eq(f.saves, 0)
			end)
		end)
	end
	helpers.it("refuses a wrong declaration import rather than publishing a decorative child template", function()
		with_swipe_template({}, function(f)
			f.root[f.swipe.section][1].section = "gesture_slot_mode_commands"
			helpers.assert_nil(f.control_slot())
			helpers.assert_eq(f.queue, {})
			helpers.assert_eq(f.saves, 0)
		end)
	end)
	helpers.it("retains the old unknown native-mode posture and computed current-value label", function()
		with_swipe_template({}, function(f)
			for _, posture in ipairs(f.swipe.mode_postures) do
				f.mode = posture.mode
				local rows = assert(f.control_slot()).menu
				helpers.assert_eq(rows[3].title, f.strings["menu.gestures.mode_prefix"] .. f.strings[posture.mode_label_key])
				helpers.assert_eq(rows[4].disabled == true, posture.sensitivity_disabled)
				helpers.assert_eq(rows[3].menu[1].checked == true, posture.mode == "x1")
				helpers.assert_eq(rows[3].menu[2].checked == true, posture.mode == "incremental")
			end
		end)
	end)
	helpers.it("retains included command delay tag and native picker publication", function()
		with_swipe_template({}, function(f)
			local rows = assert(f.control_slot()).menu
			rows[1].fn()
			helpers.assert_eq(#f.queue, 1)
			helpers.assert_eq(f.queue[1].delay, 0.05)
			helpers.assert_eq(f.queue[1].tag, "menu_gestures.action_chooser")
			f.drain()
			helpers.assert_eq(f.control_writes, { { "swipe_2_left", "copy" } })
			helpers.assert_eq(f.saves, 1)
			helpers.assert_eq(f.conflicts, 1)
			helpers.assert_eq(f.updates, 2)
		end)
	end)
end)
