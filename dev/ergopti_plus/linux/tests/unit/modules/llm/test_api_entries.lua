--- tests/unit/modules/llm/test_api_entries.lua

--- ==============================================================================
--- MODULE: Where The API Keys Live
--- DESCRIPTION:
--- The keys a user adds are stored in one file only its owner can read, kept
--- apart from the configuration folder (which may be synced), and a crash or
--- a malformed file never silently loses or exposes them.
--- ==============================================================================

local helpers = require("tests.helpers")

local DIR = os.tmpname()
os.remove(DIR)
local PATH = DIR .. "/api_keys.json"

--- A fresh store on the test file.
--- @param keep boolean|nil Keep the file from the previous load.
--- @return table
local function fresh(keep)
	if not keep then os.execute("rm -rf '" .. DIR .. "'") end
	local entries = helpers.load_module("modules.llm.api_entries")
	entries._set_path_for_test(PATH)
	return entries
end

--- The octal permission bits of a file.
--- @param path string
--- @return string
local function mode_of(path)
	local pipe = io.popen("stat -c %a '" .. path .. "'")
	local mode = pipe:read("*l")
	pipe:close()
	return mode
end

helpers.describe("api_entries: a private, durable store", function()

	helpers.it("creates the file readable by its owner only", function()
		local entries = fresh()
		helpers.assert_true(entries.add({ provider = "cerebras", token = "csk-secret", label = "Cerebras" }) ~= nil)
		helpers.assert_eq(mode_of(PATH), "600")
	end)

	helpers.it("keeps the entries and the selection across a restart", function()
		local entries = fresh()
		entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		local second = entries.add({ provider = "mistral", token = "b", label = "Mistral", model = "m" })
		local reloaded = fresh(true)
		helpers.assert_eq(#reloaded.list(), 2)
		helpers.assert_eq(reloaded.active().id, second.id, "the last added entry is selected")
		helpers.assert_eq(reloaded.active().model, "m")
	end)

	helpers.it("names a second entry of the same label apart", function()
		local entries = fresh()
		entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		local second = entries.add({ provider = "cerebras", token = "b", label = "Cerebras" })
		helpers.assert_eq(second.label, "Cerebras (2)")
	end)

	helpers.it("removing the selected entry leaves none selected", function()
		local entries = fresh()
		local entry = entries.add({ provider = "cerebras", token = "a", label = "Cerebras" })
		helpers.assert_true(entries.remove(entry.id))
		helpers.assert_nil(fresh(true).active())
		local fh = io.open(PATH, "r")
		local text = fh:read("*a")
		fh:close()
		helpers.assert_eq(text:find('"a"', 1, true), nil, "the removed key is gone from the file")
	end)

	helpers.it("refuses an entry without a key", function()
		local entries = fresh()
		helpers.assert_nil(entries.add({ provider = "cerebras", token = "", label = "Cerebras" }))
		helpers.assert_eq(#entries.list(), 0)
	end)

	helpers.it("keeps a malformed file aside instead of overwriting it", function()
		fresh()
		os.execute("mkdir -p '" .. DIR .. "' && printf 'not json' > '" .. PATH .. "'")
		local entries = fresh(true)
		helpers.assert_eq(#entries.list(), 0)
		local aside = io.open(PATH .. ".corrupt", "r")
		helpers.assert_true(aside ~= nil, "the unreadable file is preserved for the user")
		if aside then aside:close() end
		os.execute("rm -rf '" .. DIR .. "'")
	end)

end)
