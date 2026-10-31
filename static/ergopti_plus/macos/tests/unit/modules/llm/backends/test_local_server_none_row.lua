--- tests/unit/modules/llm/backends/test_local_server_none_row.lua

--- ==============================================================================
--- MODULE: Local Server "None" Row
--- DESCRIPTION:
--- A finished sweep that found no local server says one sentence in the menu;
--- the server names stay in the panel and the "other address" submenu.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

--- Reads one shared JSON file.
--- @param relative string Path under _shared/.
--- @return table
local function read_json(relative)
	local handle = assert(io.open(helpers.shared(relative), "rb"))
	local text = handle:read("*a")
	handle:close()
	return json.decode(text)
end

--- Builds the rows of a catalogue where no server answered.
--- @param sweeping boolean
--- @return table rows, table catalogue
local function rows_for(sweeping)
	local catalogue = read_json("modules/llm/local_servers.json")
	local Menu = require("llm.local_server_menu")
	local rows = Menu.rows({
		order = catalogue.server_order, servers = catalogue.servers, detected = {},
		result = function() return { status = "down" } end, sweeping = sweeping, paused = false,
		backend = "ollama", active = nil,
		tr = function(key) return key end,
		format = function(key, value) return key .. "|" .. tostring(value) end,
		actions = { select = function() end, address = function() end, key = function() end,
			rescan = function() end },
	})
	return rows, catalogue
end

helpers.describe("local server none row", function()
	helpers.it("says one sentence without the server names (local-servers-none-one-sentence)", function()
		local rows, catalogue = rows_for(false)
		local none
		for _, row in ipairs(rows) do
			if row.label == "menu.llm.local_servers.none_detected" then none = row end
			helpers.assert_true(not tostring(row.label):find("menu.llm.local_servers.none|", 1, true),
				"the old row listing every server is gone")
		end
		helpers.assert_true(none ~= nil and none.disabled == true, "the finished sweep shows one greyed sentence")
		local submenu = {}
		for _, row in ipairs(rows) do
			for _, item in ipairs(row.items or {}) do submenu[item.label] = true end
		end
		for _, id in ipairs(catalogue.server_order) do
			helpers.assert_true(submenu[catalogue.servers[id].label], id .. " stays in the other-address submenu")
		end
		for _, locale in ipairs({ "en", "fr", "de", "nl", "ja" }) do
			local text = read_json("data/locales/" .. locale .. ".json")["menu.llm.local_servers.none_detected"]
			helpers.assert_true(type(text) == "string" and text ~= "", locale .. " translates the sentence")
			helpers.assert_true(not text:find("{1}", 1, true), locale .. " takes no server list")
		end
	end)

	helpers.it("keeps the server list while the sweep runs (local-servers-searching-row)", function()
		local rows = rows_for(true)
		local searching
		for _, row in ipairs(rows) do
			if tostring(row.label):find("^menu%.llm%.local_servers%.searching|") then searching = row end
		end
		helpers.assert_true(searching ~= nil, "a running sweep still names what it looks for")
	end)
end)
