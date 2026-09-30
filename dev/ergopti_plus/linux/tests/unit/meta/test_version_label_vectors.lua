--- linux/tests/unit/meta/test_version_label_vectors.lua

--- ==============================================================================
--- MODULE: About Version Row Vectors (Linux)
--- DESCRIPTION:
--- Replays _shared/modules/updater/version_label_vectors.json through the
--- shared Lua formatter (updater.version_label), decoded by the decoder this
--- driver uses in production. The macOS suite replays it through the same
--- module and the AHK suite through Updater_VersionRowLabel, so the three
--- drivers cannot word the version row differently, and every locale is held
--- to the placeholders the formatter fills.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local SHARED = helpers.driver_root() .. "/../_shared/"

local function read_json(relative)
	local handle = assert(io.open(SHARED .. relative, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return assert(Json.decode(raw), relative .. " must decode")
end

local VECTORS = read_json("modules/updater/version_label_vectors.json")

--- The vectors' fake templates, so the replay pins the formatter, not a wording.
local function translate(key)
	return assert(VECTORS.templates[key], "no vector template for " .. tostring(key))
end

--- Every `{…}` token of a string, sorted.
local function placeholders(text)
	local found = {}
	for token in text:gmatch("{[%w_]+}") do found[#found + 1] = token end
	table.sort(found)
	return found
end

helpers.describe("updater.version_label — shared vectors (Linux)", function()
	package.loaded["updater.version_label"] = nil
	local VersionLabel = require("updater.version_label")

	helpers.it("uses the locale keys the contract names", function()
		for kind, key in pairs(VersionLabel.KEYS) do
			helpers.assert_eq(key, VECTORS.keys[kind], "the key of the " .. kind .. " row")
		end
		helpers.assert_eq(VersionLabel.UNKNOWN_COMMIT_KEY, VECTORS.keys.unknown_commit)
		local count = 0
		for _ in pairs(VECTORS.keys) do count = count + 1 end
		helpers.assert_eq(count, 4, "three kinds and the unknown commit")
	end)

	helpers.it("formats every vector", function()
		helpers.assert_true(#VECTORS.vectors >= 8, "the vectors must be present")
		for _, v in ipairs(VECTORS.vectors) do
			helpers.assert_eq(VersionLabel.format(v.kind, v.version, v.commit, translate), v.expected,
				"vector " .. v.id)
		end
	end)

	helpers.it("refuses an unknown kind and a release without a version", function()
		helpers.assert_true(not pcall(VersionLabel.format, "nightly", "1.0.0", "abc", translate),
			"an unknown kind is a programming error")
		helpers.assert_true(not pcall(VersionLabel.format, VersionLabel.KIND_RELEASE, "", "abc", translate),
			"a release row without its version is a programming error")
	end)

	helpers.it("every locale carries exactly the placeholders each key is filled with", function()
		-- The shared order lists every shipped locale (its own gate holds that).
		local order = read_json("data/locale_order.json").order
		helpers.assert_eq(#order, 21, "all 21 locales must be checked")
		for _, code in ipairs(order) do
			local catalogue = read_json("data/locales/" .. code .. ".json")
			for key, expected in pairs(VECTORS.placeholders) do
				local value = catalogue[key]
				helpers.assert_true(type(value) == "string" and value ~= "", code .. " must translate " .. key)
				local wanted = {}
				for index, token in ipairs(expected) do wanted[index] = token end
				table.sort(wanted)
				helpers.assert_eq(placeholders(value), wanted, code .. " " .. key .. " placeholders")
			end
		end
	end)
end)
