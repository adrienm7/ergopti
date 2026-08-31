--- tests/unit/modules/shortcuts/test_chatgpt.lua

--- ==============================================================================
--- MODULE: ChatGPT Shortcut Preference Tests
--- DESCRIPTION:
--- Proves that Linux reads, validates, persists, and opens the canonical
--- `shortcuts.chatgpt_url` value instead of carrying an unused parity claim.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = helpers.load_module("tests.fakes")

local displaced = {}

--- Loads the subject over isolated storage and shell seams.
--- @param initial table|nil
--- @param writes_fail boolean|nil
--- @return table subject, table storage, table commands
local function load_subject(initial, writes_fail)
	displaced.storage = package.loaded["adapters.storage"]
	displaced.shell = package.loaded["adapters.shell_runner"]
	displaced.subject = package.loaded["modules.shortcuts.chatgpt"]

	local storage = Fakes.storage({ initial = initial, writes_fail = writes_fail })
	local commands = {}
	local shell = {
		has_command = function(binary) return binary == "xdg-open" end,
		quote = function(value)
			return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
		end,
		run = function(command)
			commands[#commands + 1] = command
			return true
		end,
	}
	package.loaded["adapters.storage"] = storage
	package.loaded["adapters.shell_runner"] = shell
	package.loaded["modules.shortcuts.chatgpt"] = nil
	return require("modules.shortcuts.chatgpt"), storage, commands
end

local function restore()
	package.loaded["adapters.storage"] = displaced.storage
	package.loaded["adapters.shell_runner"] = displaced.shell
	package.loaded["modules.shortcuts.chatgpt"] = displaced.subject
end

helpers.describe("ChatGPT shortcut preference", function()

	helpers.it("uses the shared manifest default when nothing was stored", function()
		local subject = load_subject()
		local actual = subject.get_url()
		local expected = require("infra.manifest_reader").default_for("shortcuts.chatgpt_url")
		restore()
		helpers.assert_eq(actual, expected)
	end)

	helpers.it("restores a valid persisted URL", function()
		local subject = load_subject({ ["shortcuts.chatgpt_url"] = "https://example.invalid/chat" })
		local actual = subject.get_url()
		restore()
		helpers.assert_eq(actual, "https://example.invalid/chat")
	end)

	helpers.it("rejects unsafe schemes and falls back from corrupt storage", function()
		local subject = load_subject({ ["shortcuts.chatgpt_url"] = "file:///etc/passwd" })
		local actual = subject.get_url()
		local accepted = subject.set_url("javascript:alert(1)")
		restore()
		helpers.assert_eq(actual, subject.DEFAULT_URL)
		helpers.assert_true(not accepted)
	end)

	helpers.it("publishes a new value only after durable storage succeeds", function()
		local subject, storage = load_subject({
			["shortcuts.chatgpt_url"] = "https://old.example",
		}, true)
		local changed = subject.set_url("https://new.example")
		local active = subject.get_url()
		local durable = storage.get("shortcuts.chatgpt_url")
		restore()
		helpers.assert_true(not changed)
		helpers.assert_eq(active, "https://old.example")
		helpers.assert_eq(durable, "https://old.example")
	end)

	helpers.it("opens the persisted URL as one quoted shell argument", function()
		local subject, _, commands = load_subject({
			["shortcuts.chatgpt_url"] = "https://example.invalid/a?value=$(touch%20no)",
		})
		local opened = subject.open()
		restore()
		helpers.assert_true(opened)
		helpers.assert_eq(#commands, 1)
		helpers.assert_contains(commands[1],
			"'https://example.invalid/a?value=$(touch%20no)'",
			"the URL must be one inert shell word; command substitutions in query data must never execute")
	end)

end)
