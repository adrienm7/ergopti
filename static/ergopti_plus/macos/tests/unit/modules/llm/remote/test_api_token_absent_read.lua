--- tests/unit/modules/llm/remote/test_api_token_absent_read.lua

--- ==============================================================================
--- MODULE: An API Entry Restored Without Its Keychain Key Asks For It
--- DESCRIPTION:
--- Decided by the maintainer on 2026-11-11: deleting an API entry keeps
--- deleting its Keychain item, so an entry restored from a backup taken before
--- that comes back with a `keychain:<account>` reference the Keychain no longer
--- holds. The launcher reports that read with its own exit
--- (KeychainTokenWorkerExit.itemNotFound, 69), the resolver records the entry
--- as needing its key, and the model selector page greys it with the
--- « re-enter its key » hint and an « API key… » action. Before, the read
--- failed like any Keychain error and the row read as a working entry
--- (macos-api-key-restored-missing).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Reads a driver file.
--- @param relative string Path under the macOS driver.
--- @return string
local function read(relative)
	local fh = assert(io.open(helpers.driver_root() .. "/" .. relative, "rb"))
	local text = fh:read("*a")
	fh:close()
	return text
end

helpers.describe("macos API entry restored without its key (macos-api-key-restored-missing)", function()
	helpers.it("the launcher and the driver name the absent read with one exit code", function()
		local swift = read("launcher/Sources/ErgoptiPlus/KeychainTokenWorker.swift")
		helpers.assert_true(swift:find("case itemNotFound = 69", 1, true) ~= nil, "the Swift exit")
		helpers.assert_true(swift:find("if status == errSecItemNotFound { return KeychainTokenWorkerExit.itemNotFound.rawValue }",
			1, true) ~= nil, "a read of an absent item returns it")
		local crypto = helpers.load_with_stubs("modules.llm.api_token_crypto")
		helpers.assert_eq(crypto.ABSENT_EXIT_CODE, 69)
		local lua = read("modules/llm/api_token_crypto.lua")
		helpers.assert_true(lua:find('exit_code == M.ABSENT_EXIT_CODE then', 1, true) ~= nil
			and lua:find('callback, false, nil, "absent")', 1, true) ~= nil, "the read reports reason absent")
	end)

	helpers.it("an absent read marks the entry as needing its key until a new key replaces it", function()
		package.loaded["modules.llm.api_remote"] = nil
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local crypto = require("modules.llm.api_token_crypto")
		local original = crypto.decrypt_async
		local ok, err = pcall(function()
			crypto.decrypt_async = function(_, callback)
				callback(false, nil, "absent")
				return { cancel = function() return true end }
			end
			api.PROVIDERS.fixture = { label = "Fixture", base_url = "https://fixture.invalid",
				default_model = "m", format = "openai" }
			local entry = { id = "restored", provider = "fixture", base_url = "", token = "keychain:restored", model = "m" }
			api.set_entries({ entry })
			api.set_active_entry_id("restored")
			helpers.assert_eq(api.entry_key_absent(entry), false, "nothing is known before a read")
			helpers.assert_eq(api.entry_key_missing(entry), false)
			local result
			api.resolve_active_entry(function(resolved, _, reason) result = { resolved, reason } end)
			helpers.assert_eq(result ~= nil and result[1], false, "the read refused")
			helpers.assert_eq(api.entry_key_absent(entry), true, "the Keychain holds no key for it")
			helpers.assert_eq(api.entry_key_missing(entry), true, "the page greys it")
			local other = { id = "other", provider = "fixture", base_url = "", token = "keychain:other", model = "m" }
			helpers.assert_eq(api.entry_key_absent(other), false, "another entry is not affected")
			local replaced = { id = "restored", provider = "fixture", base_url = "", token = "sk-new", model = "m" }
			api.set_entries({ replaced })
			api.set_entries({ entry })
			helpers.assert_eq(api.entry_key_absent(entry), false, "a new key forgets the absent reference")
		end)
		crypto.decrypt_async = original
		if not ok then error(err, 0) end
	end)

	helpers.it("the page row of such an entry asks for its key and its action sets it", function()
		local page = read("ui/menu/menu_llm/model_selector_page.lua")
		helpers.assert_true(page:find('hint_key = e.key_absent and "model_browser.hint_api_key_reenter"', 1, true) ~= nil,
			"the row says the key must be entered again")
		helpers.assert_true(page:find('actions = { { id = "set_key", text = i18n.get("menu.llm.local_servers.api_key") } }', 1, true) ~= nil,
			"its one action is « API key… »")
		helpers.assert_true(page:find('if body.id == "set_key" and row.entry_id and row.key_absent then', 1, true) ~= nil,
			"the action is dispatched before the greyed-row refusal")
		local panel = helpers.load_with_stubs("ui.menu.menu_llm.api_panel")
		helpers.assert_eq(type(panel.set_entry_token), "function", "the key goes through the panel's persistence")
		helpers.assert_eq(panel.set_entry_token({ is_paused = function() return false end }, "restored", ""), false,
			"an empty key is refused")
	end)
end)
