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

-- One key of each shape the macOS readers take, and five they never read: an
-- unknown leaf in three known sections and an unknown section holding a
-- multiline string whose text looks like a header.
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
	"[llm.trigger]",
	"debounce = 0.3",
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
	{ { "llm", "trigger", "debounce" }, 0.3 },
}

-- A plain io adapter with the macOS FileSystem contract the cleanup needs.
local IoAdapter = {
	read_with_status = function(path) return TomlWriter.read_classified(path, nil) end,
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
			answers = Onboarding._answers_from_config(decoded),
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

		helpers.it("unused keys: a non-scalar [script] value is ignored by the loader and offered", function()
			local source = "[script]\nlocale = \"fr\"\nbroken = [1, 2]\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "broken")
		end)

		helpers.it("unused keys: the Windows import keys the wizard reads are kept", function()
			local source = "[Layout]\nErgoptiBase = true\nStale = 1\n"
			local scan = Engine.find_in_source(source, Cleanup.collect)
			helpers.assert_eq(#scan.keys, 1)
			helpers.assert_eq(scan.keys[1].key, "Stale")
		end)
	end)





	-- =======================================
	-- =======================================
	-- ======= 2/ Menu Row And Dialogs =======
	-- =======================================
	-- =======================================

	helpers.describe("unused keys (macos): tray wiring", function()
		helpers.it("unused keys: the Global actions submenu offers and dispatches the row", function()
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
				enable_all = noop, disable_all = noop, reset_defaults = noop,
				clean_unused_keys = function() fired = fired + 1 end,
			})
			helpers.assert_true(ok, "the menu must build: " .. tostring(menu))
			local row
			for _, item in ipairs(menu) do
				if item.title == "menu.global.title" then
					for _, child in ipairs(item.menu or {}) do
						if child.title == "menu.global.clean_unused_keys" then row = child end
					end
				end
			end
			helpers.assert_true(row ~= nil, "the cleanup row must be in Global actions on macOS")
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

		helpers.it("unused keys: a confirmed cleanup asks, removes, reports and moves the save baseline", function()
			Sandbox.with_config(FIXTURE, function(path)
				local calls, dialog = recorder("<button.remove>")
				local adopted
				local completed = Cleanup.run_from_menu({
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
				helpers.assert_true(Cleanup.run_from_menu({
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
				helpers.assert_true(Cleanup.run_from_menu({
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
