--- tests/unit/adapters/layout/test_input_source_switch.lua

--- ==============================================================================
--- MODULE: Input Source Switch Tests
--- DESCRIPTION:
--- Replays the GNOME and X11 backends of adapters/input_source_switch.lua
--- through a fake port: the parsers, the commands a switch runs, and the
--- switcher's ordering, replacement and refusal contract.
--- ==============================================================================

local helpers = require("tests.helpers")
local Switch = require("adapters.input_source_switch")

--- Asserts fn(...) raises an error whose message names needle.
--- @param needle string Text the refusal must contain.
--- @param fn function
local function assert_refused(needle, fn, ...)
	local ok, err = pcall(fn, ...)
	helpers.assert_eq(ok, false, "expected a refusal naming " .. needle)
	helpers.assert_true(tostring(err):find(needle, 1, true) ~= nil, tostring(err))
end

local GNOME_SOURCES = "[('xkb', 'fr'), ('xkb', 'fr+ergopti'), ('ibus', 'mozc-jp')]\n"
local GNOME_MRU = "[('xkb', 'fr+ergopti'), ('xkb', 'fr')]\n"
local X11_QUERY = "rules:      evdev\nmodel:      pc105\nlayout:     fr,us,de\nvariant:    ergopti,,neo\n"

--- A port whose commands answer from a table and are recorded in order.
--- @param backend string|nil
--- @param answers table "program arg1 arg2…" -> stdout, or false for a failure.
--- @param deferred boolean|nil When true, commands answer only on flush().
--- @return table port, table calls, function flush
local function fake_port(backend, answers, deferred)
	local calls, waiting = {}, {}
	local port = {
		backend = function() return backend end,
		run = function(program, args, on_done)
			local line = program .. " " .. table.concat(args, " ")
			calls[#calls + 1] = line
			local answer = answers[line]
			if answer == nil and program ~= "gsettings" and program ~= "setxkbmap" then return false end
			local function answer_now()
				if answer == false then on_done({ ok = false, error = "exit code 1" })
				else on_done({ ok = true, stdout = answer or "" }) end
			end
			if deferred then waiting[#waiting + 1] = answer_now else answer_now() end
			return true
		end,
	}
	local function flush()
		while #waiting > 0 do table.remove(waiting, 1)() end
	end
	return port, calls, flush
end

local function gnome_answers()
	return {
		["gsettings get org.gnome.desktop.input-sources sources"] = GNOME_SOURCES,
		["gsettings get org.gnome.desktop.input-sources mru-sources"] = GNOME_MRU,
	}
end

helpers.describe("input source switch: parsers", function()
	helpers.it("reads GNOME sources, the empty list, and refuses a list it cannot write back", function()
		local sources = Switch.parse_gnome_sources(GNOME_SOURCES)
		helpers.assert_eq(#sources, 3)
		helpers.assert_eq(Switch.gnome_id(sources[2]), "xkb:fr+ergopti")
		helpers.assert_eq(Switch.gnome_id(sources[3]), "ibus:mozc-jp")
		helpers.assert_eq(#Switch.parse_gnome_sources("@a(ss) []\n"), 0)
		helpers.assert_eq(Switch.parse_gnome_sources("[('xkb', 'fr'), ('xkb', 'it\\'s')]"), nil,
			"an escaped quote is not a tuple this module can reproduce")
		helpers.assert_eq(Switch.parse_gnome_sources("No such schema"), nil)
		helpers.assert_eq(Switch.format_gnome_sources(sources), "[('xkb', 'fr'), ('xkb', 'fr+ergopti'), ('ibus', 'mozc-jp')]")
		helpers.assert_eq(Switch.format_gnome_sources({}), "@a(ss) []")
	end)

	helpers.it("reads setxkbmap groups with their aligned variants", function()
		local query = Switch.parse_setxkbmap_query(X11_QUERY)
		helpers.assert_eq(table.concat(query.layouts, ","), "fr,us,de")
		helpers.assert_eq(table.concat(query.variants, ","), "ergopti,,neo")
		helpers.assert_eq(Switch.x11_id("fr", "ergopti"), "fr(ergopti)")
		helpers.assert_eq(Switch.x11_id("us", ""), "us")
		local single = Switch.parse_setxkbmap_query("layout:     us\n")
		helpers.assert_eq(#single.layouts, 1)
		helpers.assert_eq(single.variants[1], "")
		helpers.assert_eq(Switch.parse_setxkbmap_query("model: pc105\n"), nil, "no layout line")
		helpers.assert_eq(Switch.parse_setxkbmap_query("layout: fr;rm -rf\n"), nil, "a name outside XKB's alphabet")
	end)
end)

helpers.describe("input source switch: plans", function()
	helpers.it("puts the GNOME target first in the recent sources, then sets its index", function()
		local listing = {
			backend = Switch.GNOME,
			sources = Switch.parse_gnome_sources(GNOME_SOURCES),
			mru = Switch.parse_gnome_sources(GNOME_MRU),
		}
		local steps = Switch.plan(listing, "xkb:fr")
		helpers.assert_eq(#steps, 2)
		helpers.assert_eq(steps[1].program .. " " .. table.concat(steps[1].args, " "),
			"gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr'), ('xkb', 'fr+ergopti')]")
		helpers.assert_eq(table.concat(steps[2].args, " "), "set org.gnome.desktop.input-sources current 0")
		local ibus = Switch.plan(listing, "ibus:mozc-jp")
		helpers.assert_eq(ibus[1].args[4], "[('ibus', 'mozc-jp'), ('xkb', 'fr+ergopti'), ('xkb', 'fr')]",
			"a source absent from the recent list joins it at the head")
		helpers.assert_eq(ibus[2].args[4], "2")
		local none, reason = Switch.plan(listing, "xkb:us")
		helpers.assert_eq(none, nil)
		helpers.assert_true(reason:find("not configured", 1, true) ~= nil, reason)
	end)

	helpers.it("moves the X11 target to the first group and keeps the others in order", function()
		local listing = { backend = Switch.X11, query = Switch.parse_setxkbmap_query(X11_QUERY) }
		local steps = Switch.plan(listing, "de(neo)")
		helpers.assert_eq(#steps, 1)
		helpers.assert_eq(steps[1].program .. " " .. table.concat(steps[1].args, " "),
			"setxkbmap -layout de,fr,us -variant neo,ergopti,")
		helpers.assert_eq(Switch.plan(listing, "de"), nil, "a layout id names its variant")
	end)
end)

helpers.describe("input source switch: switcher", function()
	helpers.it("lists the desktop's layouts and reports a change once", function()
		local port = fake_port(Switch.GNOME, gnome_answers())
		local switcher = Switch.new(port)
		helpers.assert_eq(#switcher.choices(), 0, "nothing is listed before the first reading")
		local changes = {}
		switcher.refresh(function(changed) changes[#changes + 1] = changed end)
		switcher.refresh(function(changed) changes[#changes + 1] = changed end)
		helpers.assert_eq(table.concat({ tostring(changes[1]), tostring(changes[2]) }, ","), "true,false")
		local choices = switcher.choices()
		helpers.assert_eq(#choices, 3)
		helpers.assert_eq(choices[2].id, "xkb:fr+ergopti")
		helpers.assert_eq(choices[2].label, "fr+ergopti")
	end)

	helpers.it("reads the current sources before every switch and runs the plan in order", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr'), ('xkb', 'fr+ergopti')]"] = ""
		answers["gsettings set org.gnome.desktop.input-sources current 0"] = ""
		local port, calls = fake_port(Switch.GNOME, answers)
		local switcher = Switch.new(port)
		local result
		switcher.select("xkb:fr", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], true, tostring(result[2]))
		helpers.assert_eq(#calls, 4)
		helpers.assert_eq(calls[1], "gsettings get org.gnome.desktop.input-sources sources")
		helpers.assert_eq(calls[4], "gsettings set org.gnome.desktop.input-sources current 0")
		helpers.assert_true(switcher.is_settled())
	end)

	helpers.it("stops at the first failed command and reports it", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr'), ('xkb', 'fr+ergopti')]"] = false
		local port, calls = fake_port(Switch.GNOME, answers)
		local result
		Switch.new(port).select("xkb:fr", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_true(tostring(result[2]):find("gsettings failed", 1, true) ~= nil, tostring(result[2]))
		helpers.assert_eq(#calls, 3, "the index is not written after a refused source list")
	end)

	helpers.it("replaces a queued switch so a quick pause then resume ends on the resume layout", function()
		local answers = gnome_answers()
		local port, calls, flush = fake_port(Switch.GNOME, answers, true)
		local switcher = Switch.new(port)
		local results = {}
		local function record(name) return function(ok, detail) results[#results + 1] = name .. "=" .. tostring(ok) .. ":" .. tostring(detail) end end
		switcher.select("xkb:fr", record("pause"))
		switcher.select("xkb:fr+ergopti", record("resume"))
		switcher.select("ibus:mozc-jp", record("last"))
		helpers.assert_eq(results[1], "resume=false:superseded by a later switch")
		helpers.assert_eq(switcher.is_settled(), false)
		local settled = false
		switcher.when_settled(function() settled = true end)
		flush()
		helpers.assert_eq(#results, 3)
		helpers.assert_eq(results[2], "pause=true:nil")
		helpers.assert_eq(results[3], "last=true:nil")
		helpers.assert_true(settled, "the listener runs once nothing runs or waits")
		helpers.assert_eq(calls[#calls], "gsettings set org.gnome.desktop.input-sources current 2")
	end)

	helpers.it("refuses on a desktop with no supported backend without running anything", function()
		local port, calls = fake_port(nil, {})
		local switcher = Switch.new(port)
		local result
		switcher.select("xkb:fr", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_true(result[2]:find("no supported way", 1, true) ~= nil, result[2])
		helpers.assert_eq(#calls, 0)
		local changed
		switcher.refresh(function(value) changed = value end)
		helpers.assert_eq(changed, false)
		helpers.assert_eq(#switcher.choices(), 0)
	end)

	helpers.it("switches an X11 session through setxkbmap", function()
		local answers = { ["setxkbmap -query"] = X11_QUERY, ["setxkbmap -layout us,fr,de -variant ,ergopti,neo"] = "" }
		local port, calls = fake_port(Switch.X11, answers)
		local result
		Switch.new(port).select("us", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], true, tostring(result[2]))
		helpers.assert_eq(calls[2], "setxkbmap -layout us,fr,de -variant ,ergopti,neo")
	end)

	helpers.it("rejects a port without its two functions and a switch without an id", function()
		assert_refused("needs a port with backend and run", Switch.new, { backend = function() end })
		local switcher = Switch.new(fake_port(Switch.GNOME, gnome_answers()))
		assert_refused("a layout id is required", switcher.select, "", function() end)
		assert_refused("a completion callback is required", switcher.select, "xkb:fr")
	end)
end)

return true
