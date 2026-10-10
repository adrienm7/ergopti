--- _shared/lua/test/menu_top_level_separator_contract.lua

--- Existing top-level separators project only their actual source-owned inert rows.
local M = {}
local Json = require("json")
local Renderer = require("menu.renderer")
local function read_json(path)
	local file = assert(io.open(path, "rb")); local data = assert(file:read("*a")); assert(file:close())
	return assert(Json.decode(data))
end
local function scenario(platform, body)
	local Paths = require("infra.paths")
	local strings = read_json(Paths.shared("data/locales/en.json"))
	local renderer = assert(Renderer.new({platform = platform,
		manifest_path = function() return Paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = Json.decode, i18n = {get = function(key) return strings[key] or key end,
			section = function(key) return strings[key] or key end},
		logger = {error = function() end, warn = function() end}}))
	body(renderer)
end
local function plain_boundary(helpers, row)
	helpers.assert_type(row, "table"); helpers.assert_eq(row.separator, true); helpers.assert_nil(getmetatable(row))
	local count = 0; for key in next, row do count = count + 1; helpers.assert_eq(key, "separator") end
	helpers.assert_eq(count, 1)
end
function M.register(helpers, driver)
	local platform = driver == "macos" and "hs" or "linux"
	local oracle = read_json(require("infra.paths").shared("tests/corpus/menus/top_level_separators_original.json"))
	helpers.describe("actual declared top-level boundaries (declared-top-level-separator)", function()
		helpers.it("keeps every original source position and platform owner (declared-top-level-separator)", function()
			scenario(platform, function(renderer)
				helpers.assert_eq(oracle.original_sha, "98572fe1a57dde86c6e8591e79112fc5400ec819")
				local receive, rows = renderer.top_level_separator_receiver()
				helpers.assert_type(receive, "function"); helpers.assert_true(rawequal(rows, renderer.get_root().top_level))
				local expected = {}; for _, index in ipairs(oracle.visible_positions[platform]) do expected[index] = true end
				local found = {}; for index, row in ipairs(rows) do
					if row.id == "---" then
						found[#found + 1] = index
						if expected[index] then plain_boundary(helpers, receive(row)) else helpers.assert_nil(receive(row)) end
					end
				end
				helpers.assert_eq(found, oracle.separator_positions)
				for _, index in ipairs(oracle.separator_positions) do
					local copy = {}; for key, value in pairs(rows[index]) do copy[key] = value end
					helpers.assert_nil(receive(copy), "an equal-looking copy does not own a registered boundary")
				end
				helpers.assert_nil(receive(rows[1])); helpers.assert_nil(receive(4)); helpers.assert_nil(receive(nil))
				helpers.assert_true(receive("current"))
			end)
		end)
		helpers.it("retains the original normalization and callback contract (declared-top-level-separator)", function()
			scenario(platform, function(renderer)
				local receive, rows = renderer.top_level_separator_receiver(); assert(receive)
				local boundaries = {}; for _, index in ipairs(oracle.visible_positions[platform]) do boundaries[#boundaries + 1] = assert(receive(rows[index])) end
				local calls = 0;
				local first = function() calls = calls + 1 end;
				local second = function() calls = calls + 1 end
				local actual = renderer.render_rows({boundaries[1], {label = "First", action = first}, boundaries[1], boundaries[2],
					{label = "Second", action = second}, boundaries[3], boundaries[3], {label = "Third"}, boundaries[1]}, "top_level")
				local titles = {}; for _, row in ipairs(actual) do titles[#titles + 1] = row.title end
				helpers.assert_eq(titles, oracle.normalization_titles)
				helpers.assert_true(rawequal(actual[1].fn, first)); helpers.assert_true(rawequal(actual[3].fn, second)); helpers.assert_eq(calls, 0)
				helpers.assert_nil(actual[2].fn); helpers.assert_nil(actual[4].fn); helpers.assert_nil(actual[2].menu)
				helpers.assert_eq(#renderer.render_rows({boundaries[1], boundaries[2]}, "top_level"), 0)
			end)
		end)
		helpers.it("projects Linux's Quit-last boundary from its original declaration only (declared-top-level-separator)", function()
			scenario(platform, function(renderer)
				local receive, rows = renderer.top_level_separator_receiver(); assert(receive)
				if platform == "linux" then
					plain_boundary(helpers, receive("linux_quit_last"))
					plain_boundary(helpers, receive(rows[oracle.linux_quit_boundary_position]))
				else helpers.assert_nil(receive("linux_quit_last")) end
			end)
		end)
		local withdrawals = {
			["source identity"] = function(renderer, rows) renderer.get_root().top_level = {rows[1]} end,
			["source withdrawn"] = function(renderer) renderer.get_root().top_level = nil end,
			["record identity"] = function(_, rows) local copy = {}; for key, value in pairs(rows[4]) do copy[key] = value end; rows[4] = copy end,
			["record role"] = function(_, rows) rows[4].id = "not_a_boundary" end,
			["record platform"] = function(_, rows) rows[4].platforms = {"ahk"} end,
			["source metatable"] = function(_, rows) setmetatable(rows, {}) end,
			["receiver ownership"] = function(renderer, _, hits) renderer.top_level_separator_receiver = function() hits[1] = hits[1] + 1; return {} end end,
			["normalizer ownership"] = function(renderer, _, hits) renderer.render_rows = function() hits[1] = hits[1] + 1; return {} end end,
		}
		for name, withdraw in pairs(withdrawals) do
			local subject, mutate = name, withdraw
			helpers.it("held actual boundary receipt refuses " .. subject .. " without foreign dispatch (declared-top-level-separator)", function()
				scenario(platform, function(renderer)
					local receive, rows = renderer.top_level_separator_receiver(); local root, original = renderer.get_root(), {}
					assert(receive); for key, value in pairs(rows[4]) do original[key] = value end
					local row, owner, render = rows[4], renderer.top_level_separator_receiver, renderer.render_rows
					local hits = {0}
					local ok, detail = xpcall(function()
						mutate(renderer, rows, hits); helpers.assert_nil(receive(row)); helpers.assert_nil(receive("current"))
						helpers.assert_eq(hits[1], 0)
					end, debug.traceback)
					root.top_level, rows[4], renderer.top_level_separator_receiver, renderer.render_rows = rows, row, owner, render
					setmetatable(rows, nil); for key in pairs(row) do row[key] = nil end; for key, value in pairs(original) do row[key] = value end
					if not ok then error(detail, 0) end
					plain_boundary(helpers, receive(row)); helpers.assert_true(receive("current")); helpers.assert_eq(hits[1], 0)
				end)
			end)
		end
		local malformed = {
			["unknown caption"] = function(rows) rows[4].i18n = "menu.about.title" end,
			["action"] = function(rows, hits) rows[4].action = function() hits[1] = hits[1] + 1 end end,
			["wrong kind"] = function(rows) rows[4].type = "group" end,
			["record metatable"] = function(rows, hits) setmetatable(rows[4], {__index = function() hits[1] = hits[1] + 1 end}) end,
			["platform metatable"] = function(rows, hits) rows[4].platforms = setmetatable({"hs", "linux"}, {__index = function() hits[1] = hits[1] + 1 end}) end,
			["duplicate platform"] = function(rows) rows[4].platforms = {"linux", "linux"} end,
			["sparse platform"] = function(rows) rows[4].platforms = {[1] = "linux", [3] = "hs"} end,
			["unknown platform"] = function(rows) rows[4].platforms = {"other"} end,
			["sparse declaration"] = function(rows) rows[#rows + 2] = {id = "---"} end,
			["aliased declared record"] = function(rows) rows[8] = rows[4] end,
		}
		malformed["Quit platform observer"] = function(rows, hits)
			for _, row in ipairs(rows) do
				if row.id == "quit" then
					row.platforms = setmetatable({platform}, {__index = function() hits[1] = hits[1] + 1; return platform end})
					return
				end
			end
			error("the original source must contain the actual Quit record")
		end
		for name, mutate in pairs(malformed) do
			local subject, change = name, mutate
			helpers.it("refuses malformed actual separator source before observer credit: " .. subject .. " (declared-top-level-separator)", function()
				scenario(platform, function(renderer)
					local hits = {0}; change(renderer.get_root().top_level, hits)
					helpers.assert_nil(renderer.top_level_separator_receiver()); helpers.assert_eq(hits[1], 0)
				end)
			end)
		end
	end)
end
return M
