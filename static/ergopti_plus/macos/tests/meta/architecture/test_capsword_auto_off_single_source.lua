--- tests/meta/architecture/test_capsword_auto_off_single_source.lua

--- ==============================================================================
--- MODULE: CapsWord Auto-Off Single Source Meta Test
--- DESCRIPTION:
--- macOS keeps no list of its own for what ends CapsWord. The pointer kinds are
--- the manifest's shortcuts.caps_word.pointer entries (infra/capsword_auto_off),
--- the delimiters the hotstring catalogue's keys (the shared policy), and the
--- watcher only maps native events onto those kinds. This guard fails when the
--- watcher names a kind the manifest does not declare or misses one it does,
--- when a settings owner spells a pointer kind, or when a CapsWord source
--- spells a delimiter key of the catalogue instead of asking the policy.
--- ==============================================================================

local helpers = require("tests.helpers")

local function strip_comments(src)
	local out = {}
	for line in src:gmatch("[^\n]*") do
		if not line:match("^%s*%-%-") then out[#out + 1] = line end
	end
	return table.concat(out, "\n")
end

--- The kind ids one source body names as quoted strings.
local function quoted_kinds(body, declared)
	local named = {}
	for literal in body:gmatch('"([%w_]+)"') do
		if declared[literal] ~= nil then named[literal] = true end
	end
	return named
end

helpers.describe("CapsWord auto-off lists live in the manifest and the catalogue", function()
	helpers.it("the watcher maps exactly the declared macOS pointer kinds", function()
		local Owner = require("infra.capsword_auto_off")
		local declared = {}
		for _, kind in ipairs(Owner.pointer_kinds()) do declared[kind] = false end
		local src = strip_comments(helpers.read_driver_source("local function capsword_pointer_kind"))
		helpers.assert_true(src ~= "", "the watcher source must be readable")
		local start = src:find("local function capsword_pointer_kind", 1, true)
		local stop = src:find("\nend\n", start, true)
		helpers.assert_true(start ~= nil and stop ~= nil, "the pointer mapping must be locatable")
		local named = quoted_kinds(src:sub(start, stop), declared)
		local touch = src:find("local function touch_current_capsword", 1, true)
		helpers.assert_true(touch ~= nil, "the bare-touch hook must be locatable")
		for kind in pairs(quoted_kinds(src:sub(touch, src:find("\n\tend\n", touch, true)), declared)) do
			named[kind] = true
		end
		local checked = 0
		for kind in pairs(declared) do
			helpers.assert_true(named[kind], "the watcher must map the declared kind " .. kind)
			checked = checked + 1
		end
		helpers.assert_eq(checked, #Owner.pointer_kinds(), "every declared kind must be checked")
		helpers.assert_true(checked >= 6, "the manifest declares at least the six macOS pointer kinds")
		local returned = 0
		for literal in src:sub(start, stop):gmatch('return "([%w_]+)"') do
			helpers.assert_true(declared[literal] ~= nil, "the watcher names an undeclared kind " .. literal)
			returned = returned + 1
		end
		helpers.assert_true(returned >= 4, "the scan must see the mapping's returned kinds")
	end)

	helpers.it("the settings owners spell no pointer kind and no source a catalogue delimiter", function()
		local Owner = require("infra.capsword_auto_off")
		local catalogue = require("keymap.terminators_catalogue")
		local owner_checks = 0
		for _, selector in ipairs({ "local KEY_MAP = {", "function M.current_values()" }) do
			local src = strip_comments(helpers.read_driver_source(selector))
			helpers.assert_true(src ~= "", selector .. " must be readable")
			for _, kind in ipairs(Owner.pointer_kinds()) do
				helpers.assert_true(src:find('"' .. kind .. '"', 1, true) == nil,
					selector .. " spells the pointer kind " .. kind .. ": read the manifest section")
				owner_checks = owner_checks + 1
			end
		end
		helpers.assert_true(owner_checks >= 2 * 6, "both settings owners must be checked for every kind")
		local scanned, keys = 0, 0
		for _, selector in ipairs({ "local function capsword_pointer_kind", "local KEY_MAP = {",
			"function M.current_values()" }) do
			local src = strip_comments(helpers.read_driver_source(selector))
			helpers.assert_true(src ~= "", selector .. " must be readable")
			scanned = scanned + 1
			for _, def in ipairs(catalogue) do
				if def.key and def.key ~= "star" then
					helpers.assert_true(src:find('"' .. def.key .. '"', 1, true) == nil,
						selector .. " spells the delimiter " .. def.key .. ": ask the shared policy")
					keys = keys + 1
				end
			end
		end
		helpers.assert_eq(scanned, 3, "all three CapsWord sources must be scanned")
		helpers.assert_true(keys >= 3 * 20, "the scan must cover the catalogue's delimiter keys")
	end)
end)
