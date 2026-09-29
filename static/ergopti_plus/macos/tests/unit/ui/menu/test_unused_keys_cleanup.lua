--- tests/unit/ui/menu/test_unused_keys_cleanup.lua

--- ==============================================================================
--- MODULE: Unused Configuration Key Cleanup (macOS)
--- DESCRIPTION:
--- The "Clean up unused settings…" row was Windows-only: macOS read the keys it
--- used and never listed the rest, so stale keys stayed in config.toml. These
--- tests run the shared contract with the macOS readers, then prove the rule is
--- exactly the readers': the cleaned file loads to the same driver state, and
--- every key left behind changes that state when removed alone. They also pin
--- the menu row, the dialogs, and the preference save that follows a cleanup.
--- ==============================================================================

local helpers    = require("tests.helpers")
local Contract   = require("test.config_unused_keys_contract")
local Engine     = require("config_unused_keys")
local TomlCodec  = require("toml_codec")
local TomlWriter = require("toml_codec.writer")

local Sandbox = Contract.sandbox

-- One key of each shape the macOS readers take, and seven they never read: an
-- unknown leaf in three known sections, two outdated children of a known
-- table, and an unknown section holding a multiline string whose text looks
-- like a header.
local FIXTURE = table.concat({
	"# ErgoptiPlus configuration",
	"[script]",
	"log_level = \"debug\"",
	"",
	"[features]",
	"preview_star_enabled = true",
	"",
	"[hotstrings]",
	"enabled = true",
	"trigger_char = \"★\"",
	"stale_toggle = false",
	"",
	"[hotstrings.dynamic]",
	"date = true",
	"obsolete_rule = \"x\"",
	"",
	"[metrics]",
	"enabled = true",
	"metrics_encrypt = 0",
	"",
	"[gestures]",
	"enabled = false",
	"tap_3 = \"open_url\"",
	"",
	"[gestures.modes]",
	"swipe_2_left = \"incremental\"",
	"tap_3 = \"x1\"",
	"swipe_2_up = \"x9\"",
	"",
	"[llm.trigger]",
	"debounce_ms = 300",
	"disabled_apps = [",
	"  \"com.apple.Terminal\",",
	"]",
	"",
	"[stale.section]",
	"label = \"old\"",
	"note = \"\"\"",
	"[not.a.header]",
	"\"\"\"",
	"",
}, "\n")

local EXPECTED = {
	"hotstrings.stale_toggle=leaf",
	"hotstrings.dynamic.obsolete_rule=leaf",
	"metrics.metrics_encrypt=leaf",
	-- Outdated children of a known table (config-outdated-entries): a slot
	-- with no mode and a retired mode value.
	"gestures.modes.tap_3=leaf",
	"gestures.modes.swipe_2_up=leaf",
	"stale.section.label=section",
	"stale.section.note=section",
}

local SURVIVORS = {
	{ { "script", "log_level" }, "debug" },
	{ { "features", "preview_star_enabled" }, true },
	{ { "hotstrings", "trigger_char" }, "★" },
	{ { "hotstrings", "dynamic", "date" }, true },
	{ { "metrics", "enabled" }, true },
	{ { "gestures", "tap_3" }, "open_url" },
	{ { "gestures", "modes", "swipe_2_left" }, "incremental" },
	{ { "llm", "trigger", "debounce_ms" }, 300 },
}

-- A plain io adapter with the macOS FileSystem contract the cleanup needs.
local IoAdapter = {
	read_with_status = function(path) return TomlWriter.read_classified(path, nil) end,
	-- Shipped data: the setup wizard's catalogue names the keys it reads.
	read = function(path)
		local content, status = TomlWriter.read_classified(path, nil)
		return status == "ok" and content or nil
	end,
	write_if_unchanged = function(path, content, expected_source)
		return TomlWriter.publish_if_unchanged(path, content, nil, expected_source)
	end,
	write = function() error("the cleanup must never publish without a source precondition") end,
}

local MODULES = {
	"adapters.storage", "adapters.file_system", "infra.config_overrides",
	"infra.preferences", "ui.onboarding", "ui.menu.unused_keys_cleanup", "ui.menu.builder",
}

helpers.with_stub_scope(MODULES, function()
	local stored = {}
	package.loaded["adapters.storage"] = {
		set = function(key, value) stored[key] = value; return true end,
		get = function(key) return stored[key] end,
		delete = function(key) stored[key] = nil; return true end,
		keys = function() return {} end,
	}
	package.loaded["adapters.file_system"] = IoAdapter
	local Overrides   = helpers.load_with_stubs("infra.config_overrides")
	local Preferences = helpers.load_with_stubs("infra.preferences")
	local Onboarding  = helpers.load_with_stubs("ui.onboarding")
	local Cleanup     = helpers.load_with_stubs("ui.menu.unused_keys_cleanup")

	Contract.register(helpers, {
		driver = "macos",
		collect = Cleanup.collect,
		fixture = FIXTURE,
		expected = EXPECTED,
		survivors = SURVIVORS,
	})





	-- ===========================================
	-- ===========================================
	-- ======= 1/ The Readers' Own Verdict =======
	-- ===========================================
	-- ===========================================

	--- Everything the macOS readers derive from a config file.
	--- @param path string
	--- @return table
	local function driver_state(path)
		for key in pairs(stored) do stored[key] = nil end
		Overrides.apply(path)
		local overrides = {}
		for key, value in pairs(stored) do overrides[key] = value end
		local flat, status = Preferences.load(path)
		local decoded = TomlCodec.decode(Sandbox.read_bytes(path))
		return {
			overrides = overrides,
			flat = flat,
			status = status,
			answers = Onboarding.config_values(decoded),
		}
	end

	helpers.describe("unused keys (macos): the rule is exactly the readers'", function()
		helpers.it("unused keys: the cleaned file loads to the same driver state", function()
			Sandbox.with_config(FIXTURE, function(path)
				local before = driver_state(path)
				local keys = Cleanup.find(path, IoAdapter).keys
				helpers.assert_eq(#keys, #EXPECTED)
				local result = Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP,
					file_adapter = IoAdapter })
				helpers.assert_eq(result.status, "removed")
				helpers.assert_eq(driver_state(path), before,
					"a removed key must be one no macOS reader takes")
			end)
		end)

		helpers.it("unused keys: every key left behind changes the driver state when removed", function()
			local scan = Engine.scan_records(FIXTURE)
			local offered = {}
			for _, id in ipairs(EXPECTED) do offered[id:match("^(.-)=")] = true end
			local checked = 0
			for _, record in ipairs(scan.records) do
				if record.addressable and not offered[record.section .. "." .. record.key] then
					Sandbox.with_config(FIXTURE, function(path)
						local before = driver_state(path)
						local without = Engine.remove_from_source(FIXTURE, {
							{ section = record.section, key = record.key, kind = "leaf" },
						})
						Sandbox.write_bytes(path, without)
						helpers.assert_true(not helpers.deep_equal(driver_state(path), before),
							"[" .. record.section .. "] " .. record.key
								.. " is kept by the cleanup, so a reader must take it")
					end)
					checked = checked + 1
				end
			end
			helpers.assert_eq(checked, #SURVIVORS + 3,
				"every used record of the fixture must be exercised")
		end)

		helpers.it("unused keys: a removed [shortcuts.keys] hotkey is offered alone (config-outdated-at-hash)", function()
			local source = "[shortcuts.keys]\nctrl_s = true\nat_hash = true\n"
			Sandbox.with_config(source, function(path)
				local before = driver_state(path)
				local keys = Cleanup.find(path, IoAdapter).keys
				helpers.assert_eq(#keys, 1)
				helpers.assert_eq({ keys[1].section, keys[1].key, keys[1].kind },
					{ "shortcuts.keys", "at_hash", "leaf" })
				helpers.assert_eq(before.flat.shortcut_keys, { ctrl_s = true })
				local result = Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP,
					file_adapter = IoAdapter })
				helpers.assert_eq(result.status, "removed")
				helpers.assert_eq(driver_state(path), before,
					"the removed hotkey must be one no macOS reader applies")
			end)
		end)

		helpers.it("unused keys: an empty [shortcuts.keys] key never discards the file (config-outdated-empty-key)", function()
			-- Reporting "" raised inside the loader's pcall: the whole config.toml
			-- was declared corrupt and the session ran on defaults.
			local source = "[shortcuts.keys]\n\"\" = true\nctrl_s = true\n"
			Sandbox.with_config(source, function(path)
				local flat, status = Preferences.load(path)
				helpers.assert_eq(status, "ok")
				helpers.assert_eq(flat.shortcut_keys, { ctrl_s = true })
				local scan = Cleanup.find(path, IoAdapter)
				helpers.assert_eq(scan.status, "ok", "the preview must not fail on the entry it reports")
				helpers.assert_eq(#scan.keys, 0, "a quoted key has no line the cleanup can cut")
			end)
		end)

		helpers.it("unused keys: a numeric-string sensitivity is the owner's value, not outdated (config-outdated-owner-rule)", function()
			-- set_sensitivity coerces "4.5" with tonumber; a strict Lua type check
			-- dropped it, reset the swipe to the default and offered to delete it.
			local source = "[gestures.sensitivities]\nswipe_3_left = \"4.5\"\nswipe_3_right = \"fast\"\n"
			local flat = Preferences.flatten_document(TomlCodec.decode(source))
			helpers.assert_eq(flat.gesture_sensitivities, { swipe_3_left = "4.5" })
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key },
				{ "gestures.sensitivities", "swipe_3_right" })
		end)

		helpers.it("unused keys: an old-shape hotstring choice never reaches the projection (config-outdated-hotstrings)", function()
			-- The projection asserts booleans, so one `magickey = "on"` failed the
			-- boot hotstrings sync with an ERROR at every start; the cleanup never
			-- listed it because the loader took both tables whole.
			local source = table.concat({
				"[hotstrings.groups]",
				"magickey = \"on\"",
				"rolls = false",
				"",
				"[hotstrings.modules]",
				"magickey = true",
				"",
				"[hotstrings.modules.rolls]",
				"hc = \"yes\"",
				"sfb = true",
				"",
			}, "\n")
			local flat = Preferences.flatten_document(TomlCodec.decode(source))
			helpers.assert_eq(flat.hotstrings, { rolls = false })
			helpers.assert_eq(flat.section_states, { rolls = { sfb = true } })
			local desired = Preferences.project_hotstring_preferences(flat, { magickey = true, rolls = true },
				function(name) return name == "rolls" and { { name = "hc" }, { name = "sfb" } } or {} end)
			helpers.assert_eq(desired.hotstrings.rolls, false)
			helpers.assert_eq(desired.section_states.rolls.sfb, true)
			local offered = {}
			for _, key in ipairs(Engine.find_in_source(source, Cleanup.collect).keys) do
				offered[#offered + 1] = key.section .. "." .. key.key
			end
			table.sort(offered)
			helpers.assert_eq(offered, { "hotstrings.groups.magickey", "hotstrings.modules.magickey",
				"hotstrings.modules.rolls.hc" })
		end)

		helpers.it("unused keys: an invalid duration is offered alone, its neighbours kept (config-outdated-units)", function()
			local source = "[llm.trigger]\ndebounce_ms = \"fast\"\ninstant_on_word_end = true\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(scan.status, "ok")
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "llm.trigger", "debounce_ms" })
		end)

		helpers.it("unused keys: plain keyboard and tap_keys values are offered (config-outdated-shortcut-shape)", function()
			local source = "[shortcuts]\nkeyboard = \"x\"\ntap_keys = \"y\"\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(scan.status, "ok")
			local offered = {}
			for _, key in ipairs(scan.keys) do offered[#offered + 1] = key.section .. "." .. key.key end
			table.sort(offered)
			helpers.assert_eq(offered, { "shortcuts.keyboard", "shortcuts.tap_keys" })
		end)

		helpers.it("unused keys: an outdated inline-table member is offered and cut alone (config-outdated-inline)", function()
			-- The inline table was one record kept by its live member, so the
			-- warned at_hash was never offered: warned and offered differed.
			local source = "[shortcuts]\nkeys = { at_hash = true, layer_scroll = true }\n"
			Sandbox.with_config(source, function(path)
				local before = driver_state(path)
				local keys = Cleanup.find(path, IoAdapter).keys
				helpers.assert_eq(#keys, 1)
				helpers.assert_eq({ keys[1].section, keys[1].key, keys[1].value }, { "shortcuts.keys", "at_hash", "true" })
				local result = Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP,
					file_adapter = IoAdapter })
				helpers.assert_eq(result.status, "removed")
				helpers.assert_eq(result.removed, 1)
				helpers.assert_eq(Sandbox.read_bytes(path), "[shortcuts]\nkeys = { layer_scroll = true }\n")
				helpers.assert_eq(driver_state(path), before, "the live member keeps its value")
				helpers.assert_eq(#Cleanup.find(path, IoAdapter).keys, 0)
			end)
		end)

		helpers.it("unused keys: retired actions are never replayed and are offered (config-outdated-actions)", function()
			-- A retired action id was kept silently in [shortcuts.script_control],
			-- and warned about at every load but never offered in gesture,
			-- keyboard and tap-key slots.
			local source = table.concat({
				"[gestures]",
				"tap_3 = \"retired_action_xyz\"",
				"tap_4 = \"open_url\"",
				"",
				"[shortcuts.script_control]",
				"backspace = \"retired_action_xyz\"",
				"escape = \"script_quit\"",
				"",
				"[shortcuts.keyboard]",
				"cmd_k = \"retired_action_xyz\"",
				"",
				"[shortcuts.tap_keys]",
				"number_row_left = \"retired_action_xyz\"",
				"",
			}, "\n")
			-- The catalogue itself has its own parity test; here it only has to
			-- refuse the retired id.
			local saved = package.loaded["modules.gestures.actions"]
			package.loaded["modules.gestures.actions"] = {
				is_assignable = function(action) return action ~= "retired_action_xyz" end,
			}
			local ok, err = pcall(function()
				local flat = Preferences.flatten_document(TomlCodec.decode(source))
				helpers.assert_eq(flat.gesture_actions, { tap_4 = "open_url" })
				helpers.assert_eq(flat.script_control_shortcuts, { escape = "script_quit" })
				local offered = {}
				for _, key in ipairs(Engine.find_in_source(source, Cleanup.collect).keys) do
					offered[#offered + 1] = key.section .. "." .. key.key
				end
				table.sort(offered)
				helpers.assert_eq(offered, { "gestures.tap_3", "shortcuts.keyboard.cmd_k",
					"shortcuts.script_control.backspace", "shortcuts.tap_keys.number_row_left" })
			end)
			package.loaded["modules.gestures.actions"] = saved
			if not ok then error(err, 0) end
		end)

		helpers.it("unused keys: an outdated value is offered even when the wizard reads the key (config-outdated-contract)", function()
			-- The setup wizard marks shortcuts.keys.layer_scroll; the owner's report
			-- must still win, or the warned entry could never be removed.
			local source = "[shortcuts.keys]\nlayer_scroll = \"yes\"\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq({ scan.keys[1].section, scan.keys[1].key }, { "shortcuts.keys", "layer_scroll" })
		end)

		helpers.it("unused keys: a non-scalar [script] value is ignored by the loader and offered", function()
			local source = "[script]\nlocale = \"fr\"\nbroken = [1, 2]\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "broken")
		end)

		helpers.it("unused keys: the wizard keeps its manifest paths and no Windows import key", function()
			-- The wizard reads the manifest paths of its pages, never the former
			-- Windows PascalCase import keys, so those are offered like any stale key.
			local source = "[Layout]\nErgoptiBase = true\n[gestures]\nenabled = true\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "ErgoptiBase")
		end)
	end)





	-- =======================================
	-- =======================================
	-- ======= 2/ Menu Row And Dialogs =======
	-- =======================================
	-- =======================================

	--- Keeps the existing cleanup transaction proofs independent of presentation.
	local function run_engine_cleanup(deps)
		local get_text = function(key) return deps.i18n.get(key) end
		return Engine.run({
			path = deps.path, collect = Cleanup.collect, file_adapter = deps.file_adapter, stamp = deps.stamp,
			get_text = get_text,
			confirm = function(title, text)
				return deps.dialog.block_alert(title, text, get_text("button.remove"), get_text("button.cancel"),
					"warning") == get_text("button.remove")
			end,
			inform = function(title, text) deps.dialog.block_alert(title, text, get_text("button.ok")) end,
			fail = function() error("unexpected cleanup transaction refusal") end,
			on_removed = function(result) deps.preferences.adopt_cleanup(deps.path, result.previous, result.content) end,
		})
	end

	helpers.describe("unused keys (macos): tray wiring", function()
		helpers.it("unused keys: the menu opens a WebView and preserves the exact adoption callback", function()
			local captured, adopted
			local opened = Cleanup.run_from_menu({
				path = "/trusted/config.toml", file_adapter = IoAdapter,
				host = { open = function(options) captured = options; return true end },
				preferences = { adopt_cleanup = function(...) adopted = { ... }; return true end },
			})
			helpers.assert_eq(opened, true)
			helpers.assert_eq(captured.path, "/trusted/config.toml")
			helpers.assert_eq(captured.collect, Cleanup.collect)
			helpers.assert_eq(captured.file_adapter, IoAdapter)
			helpers.assert_eq(captured.on_removed({ previous = "before", content = "after" }), true)
			helpers.assert_eq(adopted, { "/trusted/config.toml", "before", "after" })
		end)
		helpers.it("unused keys: the Configuration submenu offers and dispatches the row", function()
			local fired = 0
			local builder = helpers.load_with_stubs("ui.menu.builder")
			local i18n = require("infra.i18n")
			i18n.get = function(key) return key end
			i18n.build_language_menu_items = function() return {} end
			local noop = function() end
			local ok, menu = pcall(builder.generate, { config = { log_level = 2 } }, {}, {
				set_log_level = noop, open_logs = noop, open_today_log = noop,
				open_error_log = noop, open_console = noop, show_setup_wizard = noop,
				open_paths = noop, reload = noop, quit = noop,
				reset_defaults = noop,
				clean_unused_keys = function() fired = fired + 1 end,
			})
			helpers.assert_true(ok, "the menu must build: " .. tostring(menu))
			local row
			for _, item in ipairs(menu) do
				if item.title == "menu.configuration.title" then
					for _, child in ipairs(item.menu or {}) do
						if child.title == "menu.global.clean_unused_keys" then row = child end
					end
				end
			end
			helpers.assert_true(row ~= nil, "the cleanup row must be in Configuration on macOS")
			helpers.assert_eq(type(row.fn), "function")
			row.fn()
			helpers.assert_eq(fired, 1)
		end)

		helpers.it("unused keys: the menu init registers the action with the cleanup module", function()
			-- ui/menu/init.lua needs a live Hammerspoon, so its actions table is
			-- read, not run: the builder case above proves the row reaches it.
			local source, err = helpers.read_driver_unit("reset_all_defaults() end,")
			helpers.assert_true(source ~= nil, tostring(err))
			local at = source:find("clean_unused_keys%s*=%s*function%(%)")
			helpers.assert_true(at ~= nil, "the actions table must define clean_unused_keys")
			helpers.assert_true(source:find("require(\"ui.menu.unused_keys_cleanup\").run_from_menu()",
				at, true) ~= nil, "clean_unused_keys must run the macOS cleanup")
		end)

		--- A dialog recorder answering the confirmation with `answer`.
		local function recorder(answer)
			local calls = {}
			return calls, {
				block_alert = function(...)
					calls[#calls + 1] = { ... }
					if #calls == 1 then return answer end
					return "<button.ok>"
				end,
			}
		end
		local i18n_stub = { get = function(key) return "<" .. key .. ">" end }

		helpers.it("unused keys: a confirmed engine cleanup removes, reports and moves the save baseline", function()
			Sandbox.with_config(FIXTURE, function(path)
				local calls, dialog = recorder("<button.remove>")
				local adopted
				local completed = run_engine_cleanup({
					path = path, dialog = dialog, i18n = i18n_stub, file_adapter = IoAdapter,
					stamp = Sandbox.STAMP,
					preferences = { adopt_cleanup = function(...) adopted = { ... } end },
				})
				helpers.assert_true(completed)
				helpers.assert_eq(calls[1][1], "<dialog.unused_keys.title>")
				helpers.assert_eq(calls[1][2], "<dialog.unused_keys.confirm>")
				helpers.assert_eq({ calls[1][3], calls[1][4], calls[1][5] },
					{ "<button.remove>", "<button.cancel>", "warning" })
				helpers.assert_eq(calls[2][2], "<dialog.unused_keys.done>")
				helpers.assert_eq(adopted, { path, FIXTURE, Sandbox.read_bytes(path) })
				helpers.assert_eq(Sandbox.read_bytes(Engine.backup_path(path, Sandbox.STAMP)), FIXTURE)
			end)
		end)

		helpers.it("unused keys: Cancel leaves the file and writes no backup", function()
			Sandbox.with_config(FIXTURE, function(path)
				local calls, dialog = recorder("<button.cancel>")
				helpers.assert_true(run_engine_cleanup({
					path = path, dialog = dialog, i18n = i18n_stub, file_adapter = IoAdapter,
					stamp = Sandbox.STAMP,
					preferences = { adopt_cleanup = function() error("nothing was cleaned") end },
				}))
				helpers.assert_eq(#calls, 1)
				helpers.assert_eq(Sandbox.read_bytes(path), FIXTURE)
				helpers.assert_nil(Sandbox.read_bytes(Engine.backup_path(path, Sandbox.STAMP)))
			end)
		end)

		helpers.it("unused keys: the next preference save succeeds after a cleanup", function()
			Sandbox.with_config(FIXTURE, function(path)
				helpers.assert_eq(select(2, Preferences.load(path)), "ok")
				local calls, dialog = recorder("<button.remove>")
				helpers.assert_true(run_engine_cleanup({
					path = path, dialog = dialog, i18n = i18n_stub, file_adapter = IoAdapter,
					stamp = Sandbox.STAMP, preferences = Preferences,
				}))
				helpers.assert_eq(#calls, 2)
				helpers.assert_eq(Preferences.save(path, {}, {}, {}), true,
					"a cleanup of keys load() never reads must not make the next save "
						.. "look like an external edit")
			end)
		end)

		helpers.it("unused keys: without the baseline move that save would be refused", function()
			Sandbox.with_config(FIXTURE, function(path)
				Preferences.load(path)
				local keys = Cleanup.find(path, IoAdapter).keys
				Engine.remove({ path = path, keys = keys, stamp = Sandbox.STAMP, file_adapter = IoAdapter })
				helpers.assert_eq(Preferences.save(path, {}, {}, {}), false)
			end)
		end)

		helpers.it("unused keys: the list cap matches the Windows driver", function()
			local fh = assert(io.open(helpers.driver_root() .. "../windows/infra/config_unused_keys.ahk", "rb"))
			local ahk = fh:read("*a")
			fh:close()
			helpers.assert_eq(tonumber(ahk:match("CONFIG_UNUSED_KEYS_DISPLAY_LIMIT := (%d+)")),
				Engine.DISPLAY_LIMIT)
		end)
	end)
end)
