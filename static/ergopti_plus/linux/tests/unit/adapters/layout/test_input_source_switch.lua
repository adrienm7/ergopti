--- tests/unit/adapters/layout/test_input_source_switch.lua

--- ==============================================================================
--- MODULE: Input Source Switch Tests
--- DESCRIPTION:
--- Replays the GNOME, KDE and X11 backends of adapters/input_source_switch.lua
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
local KDE_CALL = "gdbus call --session --dest org.kde.keyboard --object-path /Layouts --method org.kde.KeyboardLayouts."
-- The reply's middle field is the user's display label, never the variant
-- (Plasma 6.6.4, checked on Wayland and X11): the variants are kxkbrc's.
local KDE_LIST = "([('fr', '', 'French (Ergopti)'), ('us', 'us', \"English (US, int'l)\"), ('de', 'DE', 'German (Neo 2)')],)\n"
local KXKBRC = "[Layout]\nDisplayNames=,,DE\nLayoutList=fr,us,de\nUse=true\nVariantList=ergopti,,neo\n"
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
		kde_config = function() return answers.kxkbrc end,
		run = function(program, args, on_done)
			local line = program .. " " .. table.concat(args, " ")
			calls[#calls + 1] = line
			local answer = answers[line]
			if answer == nil and program ~= "gsettings" and program ~= "setxkbmap" and program ~= "sleep" then
				return false
			end
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

	helpers.it("reads the KDE daemon's layouts and index, and refuses what it cannot read", function()
		local layouts = Switch.parse_kde_layouts(KDE_LIST)
		helpers.assert_eq(#layouts, 3)
		helpers.assert_eq(layouts[1].label, "")
		helpers.assert_eq(layouts[3].label, "DE", "the middle field is the display label")
		helpers.assert_eq(layouts[2].name, "English (US, int'l)", "a double-quoted name keeps its apostrophe")
		helpers.assert_eq(#Switch.parse_kde_layouts("([],)"), 0)
		helpers.assert_eq(Switch.parse_kde_layouts("([('fr;rm', '', 'x')],)"), nil, "a name outside XKB's alphabet")
		helpers.assert_eq(Switch.parse_kde_layouts("([('fr', '')],)"), nil, "a tuple of two strings")
		helpers.assert_eq(Switch.parse_kde_layouts("Error: GDBus.Error:org.freedesktop.DBus.Error.ServiceUnknown"), nil)
		helpers.assert_eq(Switch.parse_kde_index("(uint32 1,)\n"), 1)
		helpers.assert_eq(Switch.parse_kde_index("(int32 -1,)"), nil)
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
	-- GNOME Shell 46 ignores runtime writes of mru-sources and current and keeps
	-- its in-memory recent list on a sources change (container proof, 2026-11-10).
	helpers.it("switches a running GNOME Shell through the target alone, then the list (gnome-runtime-switch)", function()
		local listing = {
			backend = Switch.GNOME,
			sources = Switch.parse_gnome_sources(GNOME_SOURCES),
			mru = Switch.parse_gnome_sources(GNOME_MRU),
		}
		local function lines(steps)
			local out = {}
			for index, step in ipairs(steps) do out[index] = step.program .. " " .. table.concat(step.args, " ") end
			return out
		end
		local settle = string.format("%.3f", require("infra.timings").ms("ui", "gnome_input_source_settle_ms") / 1000)
		helpers.assert_eq(lines(Switch.plan(listing, "xkb:fr+ergopti")), {
			"gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr+ergopti')]",
			"sleep " .. settle,
			"gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr+ergopti'), ('xkb', 'fr'), ('ibus', 'mozc-jp')]",
			"gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr+ergopti'), ('xkb', 'fr')]",
		})
		for _, step in ipairs(Switch.plan(listing, "xkb:fr")) do
			helpers.assert_true(not table.concat(step.args, " "):find(" current ", 1, true), "current is never written")
		end
		local ibus = Switch.plan(listing, "ibus:mozc-jp")
		helpers.assert_eq(ibus[4].args[4], "[('ibus', 'mozc-jp'), ('xkb', 'fr+ergopti'), ('xkb', 'fr')]",
			"a source absent from the recent list joins it at the head")
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
	helpers.it("linux-x11-active-group: waits for owned group acknowledgement and retirement", function()
		local names = { "core.process.adapters.owned_process", "luv", "core.fs.engine.paths", "_generated.native_runtime" }
		local old = {}; for _, name in ipairs(names) do old[name] = package.loaded[name] end
		local calls = {}
		package.loaded["core.process.adapters.owned_process"] = { start = function(program, args, options, callback)
			calls[#calls + 1] = { program = program, args = args, options = options, done = callback }
			return { started = false, error = "dispatch refused until retired" }
		end }
		package.loaded["luv"] = { os_getpid = function() return 123 end, exepath = function() return "/runtime/luajit" end }
		package.loaded["core.fs.engine.paths"] = { driver_root = function() return "/literal?root" end }
		package.loaded["_generated.native_runtime"] = { x11 = "libX11-test.so.9" }
		local port = Switch.native_port()
		local received = {}
		helpers.assert_true(port.run("setxkbmap", { "-layout", "fr,us" }, function(result)
			received[#received + 1] = result
		end))
		helpers.assert_eq(#calls, 1)
		calls[1].done({ ok = true })
		helpers.assert_eq(#calls, 2)
		calls[1].done({ ok = true })
		helpers.assert_eq(#calls, 2, "a duplicate layout completion cannot start a second worker")
		helpers.assert_eq(calls[2].program, "/runtime/luajit")
		helpers.assert_eq(calls[2].args, { "/literal?root/adapters/input_source_group_worker.lua", "123", "libX11-test.so.9" })
		helpers.assert_eq(#received, 0, "the refused child still owns retirement")
		calls[2].done({ ok = false, error = "not active" })
		calls[2].done({ ok = true })
		helpers.assert_eq(#received, 1)
		helpers.assert_eq(received[1].error, "not active")
		for _, name in ipairs(names) do package.loaded[name] = old[name] end
	end)

	helpers.it("linux-x11-active-group: query and rejected layout never start the group worker", function()
		local previous = package.loaded["core.process.adapters.owned_process"]
		local calls = {}
		package.loaded["core.process.adapters.owned_process"] = { start = function(program, args, _, callback)
			calls[#calls + 1] = { program = program, args = args, done = callback }; return {}
		end }
		local port = Switch.native_port()
		package.loaded["core.process.adapters.owned_process"] = previous
		local query, rejected
		port.run("setxkbmap", { "-query" }, function(result) query = result end)
		calls[1].done({ ok = true, stdout = "layout: us" })
		port.run("setxkbmap", { "-layout", "us" }, function(result) rejected = result end)
		calls[2].done({ ok = false, error = "refused" })
		helpers.assert_eq(#calls, 2)
		helpers.assert_eq(query.stdout, "layout: us")
		helpers.assert_eq(rejected.error, "refused")
	end)

	helpers.it("linux-x11-active-group: worker setup errors complete as refusals", function()
		local old_process, old_luv, old_paths = package.loaded["core.process.adapters.owned_process"], package.loaded["luv"], package.loaded["core.fs.engine.paths"]
		local done
		package.loaded["core.process.adapters.owned_process"] = { start = function(_, _, _, callback) done = callback; return {} end }
		package.loaded["luv"] = { os_getpid = function() return 123 end, exepath = function() return "/runtime/luajit" end }
		package.loaded["core.fs.engine.paths"] = { driver_root = function() error("unavailable") end }
		local port = Switch.native_port()
		local result
		port.run("setxkbmap", { "-layout", "fr" }, function(value) result = value end)
		done({ ok = true })
		helpers.assert_eq(result.ok, false)
		helpers.assert_eq(result.error, "X11 group worker could not start")
		package.loaded["core.process.adapters.owned_process"], package.loaded["luv"], package.loaded["core.fs.engine.paths"] = old_process, old_luv, old_paths
	end)

	helpers.it("linux-x11-active-group: invalid declared soname never reaches a worker", function()
		local names = { "core.process.adapters.owned_process", "luv", "core.fs.engine.paths", "_generated.native_runtime" }
		local old = {}; for _, name in ipairs(names) do old[name] = package.loaded[name] end
		local calls, done = 0, nil
		package.loaded["core.process.adapters.owned_process"] = { start = function(_, _, _, callback)
			calls = calls + 1; done = callback; return {}
		end }
		package.loaded["luv"] = { os_getpid = function() return 123 end, exepath = function() return "/runtime/luajit" end }
		package.loaded["core.fs.engine.paths"] = { driver_root = function() return "/driver" end }
		package.loaded["_generated.native_runtime"] = { x11 = "../unexpected.so" }
		local port, result = Switch.native_port(), nil
		port.run("setxkbmap", { "-layout", "fr" }, function(value) result = value end)
		done({ ok = true })
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(result.ok, false)
		for _, name in ipairs(names) do package.loaded[name] = old[name] end
	end)

	helpers.it("linux-layout-start-debt: native refused start waits for settlement callback", function()
		local previous = package.loaded["core.process.adapters.owned_process"]
		local pending
		package.loaded["core.process.adapters.owned_process"] = { start = function(_, _, _, callback)
			pending = callback
			return { started = false, error = "native allocation refused" }
		end }
		local port = Switch.native_port()
		package.loaded["core.process.adapters.owned_process"] = previous
		local delivered = false
		local accepted = port.run("setxkbmap", { "-query" }, function() delivered = true end)
		helpers.assert_eq(accepted, true, "the returned owner still has physical retirement to acknowledge")
		helpers.assert_eq(delivered, false)
		pending({ ok = false, error = "native allocation refused" })
		helpers.assert_eq(delivered, true)
	end)
	helpers.it("linux-layout-refresh-settlement: waits for an outstanding listing", function()
		local pending, settled, changed = nil, false, nil
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback) pending = callback; return true end })
		switcher.refresh(function(value) changed = value end)
		helpers.assert_eq(switcher.is_settled(), false)
		switcher.when_settled(function() settled = true end)
		helpers.assert_eq(settled, false)
		pending({ ok = true, stdout = "layout: us\n" })
		helpers.assert_eq(changed, true)
		helpers.assert_eq(settled, true)
		helpers.assert_eq(switcher.is_settled(), true)
	end)
	helpers.it("linux-layout-refresh-order: an older completion cannot replace newer choices", function()
		local pending, completed = {}, {}
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback) pending[#pending + 1] = callback; return true end })
		switcher.refresh(function(changed) completed[#completed + 1] = changed end)
		switcher.refresh(function(changed) completed[#completed + 1] = changed end)
		pending[2]({ ok = true, stdout = "layout: us\n" })
		pending[1]({ ok = true, stdout = "layout: fr\n" })
		helpers.assert_eq(switcher.choices()[1].id, "us")
		helpers.assert_eq(completed, { true, false }, "the stale completion must still settle its caller")
	end)
	helpers.it("linux-layout-refresh-order: an old refresh cannot replace a switcher's newer listing", function()
		local pending = {}
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback) pending[#pending + 1] = callback; return true end })
		switcher.refresh()
		local switched
		switcher.select("us", function(ok) switched = ok end)
		pending[2]({ ok = true, stdout = "layout: us\n" })
		pending[1]({ ok = true, stdout = "layout: fr\n" })
		helpers.assert_eq(switcher.choices()[1].id, "us")
		pending[3]({ ok = true, stdout = "" })
		helpers.assert_eq(switched, true)
	end)
	helpers.it("linux-layout-refresh-order: a refresh waits for an active switch", function()
		local pending = {}
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback) pending[#pending + 1] = callback; return true end })
		local switched
		switcher.select("fr", function(ok) switched = ok end)
		switcher.refresh()
		helpers.assert_nil(pending[2], "menu refresh must wait for the active switch")
		pending[1]({ ok = true, stdout = "layout: fr\n" })
		pending[2]({ ok = true, stdout = "" })
		helpers.assert_eq(switched, true)
		helpers.assert_eq(switcher.is_settled(), false, "the deferred refresh still owns a native read")
		pending[3]({ ok = true, stdout = "layout: us\n" })
		helpers.assert_eq(switcher.choices()[1].id, "us")
		helpers.assert_eq(switcher.is_settled(), true)
	end)
	helpers.it("linux-layout-refresh-order: reentrant completion refreshes before settlement", function()
		local pending, settled, refresh_done = {}, false, false
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback) pending[#pending + 1] = callback; return true end })
		switcher.select("fr", function(ok)
			helpers.assert_true(ok)
			switcher.refresh(function() refresh_done = true end)
			switcher.when_settled(function() settled = true end)
		end)
		pending[1]({ ok = true, stdout = "layout: fr\n" })
		pending[2]({ ok = true, stdout = "" })
		helpers.assert_eq(settled, false)
		helpers.assert_eq(refresh_done, false)
		pending[3]({ ok = true, stdout = "layout: fr\n" })
		helpers.assert_eq(refresh_done, true)
		helpers.assert_eq(settled, true)
	end)
	helpers.it("linux-layout-refresh-order: synchronous deferred refreshes all retire before settlement", function()
		local calls, pending, events = 0, {}, {}
		local switcher = Switch.new({ kde_config = function() return nil end, backend = function() return Switch.X11 end,
			run = function(_, _, callback)
				calls = calls + 1
				if calls <= 2 then pending[calls] = callback else callback({ ok = true, stdout = "layout: fr\n" }) end
				return true
			end })
		switcher.select("fr", function() end)
		switcher.refresh(function() events[#events + 1] = "refresh1" end)
		switcher.refresh(function() events[#events + 1] = "refresh2" end)
		switcher.when_settled(function() events[#events + 1] = "settled" end)
		pending[1]({ ok = true, stdout = "layout: fr\n" })
		pending[2]({ ok = true, stdout = "" })
		helpers.assert_eq(events, { "refresh1", "refresh2", "settled" })
	end)
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
		helpers.assert_eq(choices[2].active, true, "GNOME's first recent source is the active one")
		helpers.assert_eq(choices[1].active, false)
	end)

	helpers.it("lists a KDE session's layouts from the keyboard daemon with the active one", function()
		local port, calls = fake_port(Switch.KDE, {
			[KDE_CALL .. "getLayoutsList"] = KDE_LIST, [KDE_CALL .. "getLayout"] = "(uint32 2,)\n", kxkbrc = KXKBRC,
		})
		local switcher = Switch.new(port)
		local changed
		switcher.refresh(function(value) changed = value end)
		helpers.assert_eq(changed, true)
		local choices = switcher.choices()
		helpers.assert_eq(#choices, 3)
		helpers.assert_eq(choices[1].id, "fr(ergopti)")
		helpers.assert_eq(choices[2].label, "English (US, int'l)")
		helpers.assert_eq(choices[3].active, true)
		helpers.assert_eq(choices[1].active, false)
		helpers.assert_eq(#calls, 2)
	end)

	helpers.it("switches a KDE session by the daemon's index and fails when it refuses", function()
		local answers = { [KDE_CALL .. "getLayoutsList"] = KDE_LIST, [KDE_CALL .. "getLayout"] = "(uint32 0,)", kxkbrc = KXKBRC,
			[KDE_CALL .. "setLayout 2"] = "(true,)\n", [KDE_CALL .. "setLayout 1"] = "(false,)\n" }
		local port, calls = fake_port(Switch.KDE, answers)
		local switcher = Switch.new(port)
		local result
		switcher.select("de(neo)", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], true, tostring(result[2]))
		helpers.assert_eq(calls[3], KDE_CALL .. "setLayout 2")
		switcher.select("us", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false, "a daemon answering false did not switch")
		helpers.assert_true(tostring(result[2]):find("refused the switch", 1, true) ~= nil, tostring(result[2]))
		switcher.select("it", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_true(tostring(result[2]):find("not configured in this KDE session", 1, true) ~= nil)
	end)

	helpers.it("names a KDE layout the same on Wayland and X11, from kxkbrc (kde-layout-id-session-types)", function()
		local wayland = "([('us', '', 'English (US)'), ('fr', '', 'French (BEPO)'), ('fr', 'FR', 'French')],)"
		local x11 = "([('us', 'us', 'English (US)'), ('fr', 'fr', 'French (BEPO)'), ('fr', 'FR', 'French')],)"
		local config = "[Layout]\nLayoutList=us,fr,fr\nVariantList=,bepo,\nDisplayNames=,,FR\n"
		local ids = {}
		for _, list in ipairs({ wayland, x11 }) do
			local port = fake_port(Switch.KDE, { [KDE_CALL .. "getLayoutsList"] = list,
				[KDE_CALL .. "getLayout"] = "(uint32 0,)", kxkbrc = config })
			local switcher = Switch.new(port)
			switcher.refresh()
			local names = {}
			for _, choice in ipairs(switcher.choices()) do names[#names + 1] = choice.id end
			ids[#ids + 1] = table.concat(names, " ")
		end
		helpers.assert_eq(ids[1], "us fr(bepo) fr", "Wayland")
		helpers.assert_eq(ids[2], ids[1], "X11 names the same layouts the same")
		local function listed(answers)
			local port = fake_port(Switch.KDE, answers)
			local switcher = Switch.new(port)
			switcher.refresh()
			return #switcher.choices()
		end
		helpers.assert_eq(listed({ [KDE_CALL .. "getLayoutsList"] = wayland, [KDE_CALL .. "getLayout"] = "(uint32 0,)",
			kxkbrc = "[Layout]\nLayoutList=us,de\n" }), 0, "kxkbrc and the daemon disagree: nothing is listed")
		helpers.assert_eq(listed({ [KDE_CALL .. "getLayoutsList"] = wayland, [KDE_CALL .. "getLayout"] = "(uint32 0,)",
			kxkbrc = false }), 0, "an unreadable kxkbrc lists nothing")
		local plain = fake_port(Switch.KDE, { [KDE_CALL .. "getLayoutsList"] = "([('us', 'us', 'English (US)')],)",
			[KDE_CALL .. "getLayout"] = "(uint32 0,)" })
		local switcher = Switch.new(plain)
		switcher.refresh()
		helpers.assert_eq(switcher.choices()[1].id, "us", "no configured layout list: the session default, no variant")
	end)

	helpers.it("reads the current sources before every switch and runs the plan in order", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr'), ('xkb', 'fr+ergopti')]"] = ""
		local port, calls = fake_port(Switch.GNOME, answers)
		local switcher = Switch.new(port)
		local result
		switcher.select("xkb:fr", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], true, tostring(result[2]))
		helpers.assert_eq(#calls, 6)
		helpers.assert_eq(calls[1], "gsettings get org.gnome.desktop.input-sources sources")
		helpers.assert_eq(calls[3], "gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr')]")
		helpers.assert_eq(calls[6], "gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr'), ('xkb', 'fr+ergopti')]")
		helpers.assert_true(switcher.is_settled())
	end)

	helpers.it("stops at the first failed command and reports it", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr')]"] = false
		local port, calls = fake_port(Switch.GNOME, answers)
		local result
		Switch.new(port).select("xkb:fr", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_true(tostring(result[2]):find("gsettings failed", 1, true) ~= nil, tostring(result[2]))
		helpers.assert_eq(#calls, 3, "nothing is written after a refused source list")
	end)

	helpers.it("puts the GNOME list back when a write after the target alone fails (gnome-runtime-switch)", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr+ergopti'), ('xkb', 'fr'), ('ibus', 'mozc-jp')]"] = false
		local port, calls = fake_port(Switch.GNOME, answers)
		local result
		Switch.new(port).select("xkb:fr+ergopti", function(ok, detail) result = { ok, detail } end)
		helpers.assert_eq(result[1], false)
		helpers.assert_true(tostring(result[2]):find("put back", 1, true) ~= nil, tostring(result[2]))
		helpers.assert_eq(calls[#calls],
			"gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr'), ('xkb', 'fr+ergopti'), ('ibus', 'mozc-jp')]",
			"the undo writes the user's list back")
	end)

	helpers.it("runs a queued resume after a GNOME write fails", function()
		local answers = gnome_answers()
		answers["gsettings set org.gnome.desktop.input-sources sources [('xkb', 'fr'), ('xkb', 'fr+ergopti'), ('ibus', 'mozc-jp')]"] = false
		local port, calls, flush = fake_port(Switch.GNOME, answers, true)
		local switcher, results, settled = Switch.new(port), {}, false
		switcher.select("xkb:fr", function(ok) results[#results + 1] = { "pause", ok } end)
		switcher.select("xkb:fr+ergopti", function(ok) results[#results + 1] = { "resume", ok } end)
		switcher.when_settled(function() settled = true end)
		flush()
		helpers.assert_eq(results, { { "pause", false }, { "resume", true } })
		helpers.assert_eq(calls[#calls], "gsettings set org.gnome.desktop.input-sources mru-sources [('xkb', 'fr+ergopti'), ('xkb', 'fr')]")
		helpers.assert_true(settled)
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
		helpers.assert_eq(calls[#calls], "gsettings set org.gnome.desktop.input-sources mru-sources [('ibus', 'mozc-jp'), ('xkb', 'fr+ergopti'), ('xkb', 'fr')]")
	end)

	helpers.it("waits for a switch started by an earlier settlement listener", function()
		local port, _, flush = fake_port(Switch.GNOME, gnome_answers(), true)
		local switcher = Switch.new(port)
		local second_saw_idle, second_calls = nil, 0
		switcher.select("xkb:fr", function() end)
		switcher.when_settled(function()
			switcher.select("ibus:mozc-jp", function() end)
		end)
		switcher.when_settled(function()
			second_calls = second_calls + 1
			second_saw_idle = switcher.is_settled()
		end)
		flush()
		helpers.assert_eq(second_calls, 1)
		helpers.assert_true(second_saw_idle, "settlement must not be reported while another switch runs")
	end)

	helpers.it("serializes a selection made by a completion callback and supersedes the older queue", function()
		local port, calls, flush = fake_port(Switch.GNOME, gnome_answers(), true)
		local switcher = Switch.new(port)
		local results = {}
		local function record(name)
			return function(ok, detail) results[#results + 1] = name .. "=" .. tostring(ok) .. ":" .. tostring(detail) end
		end
		switcher.select("xkb:fr", function(ok, detail)
			record("first")(ok, detail)
			switcher.select("ibus:mozc-jp", record("newest"))
		end)
		switcher.select("xkb:fr+ergopti", record("older"))
		flush()
		helpers.assert_eq(table.concat(results, ","),
			"first=true:nil,older=false:superseded by a later switch,newest=true:nil")
		helpers.assert_eq(calls[#calls], "gsettings set org.gnome.desktop.input-sources mru-sources [('ibus', 'mozc-jp'), ('xkb', 'fr+ergopti'), ('xkb', 'fr')]")
		helpers.assert_eq(#calls, 12, "the superseded switch must issue no native commands (two reads and four writes per switch)")
		helpers.assert_true(switcher.is_settled())
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
		assert_refused("needs a port with backend, run and kde_config", Switch.new, { backend = function() end })
		local switcher = Switch.new(fake_port(Switch.GNOME, gnome_answers()))
		assert_refused("a layout id is required", switcher.select, "", function() end)
		assert_refused("a completion callback is required", switcher.select, "xkb:fr")
	end)
end)

helpers.describe("input source switch: native port", function()
	helpers.it("reads kxkbrc from the XDG config root config_paths resolves", function()
		local uv = require("luv")
		local root = os.tmpname()
		os.remove(root)
		assert(uv.fs_mkdir(root, 448))
		local handle = assert(io.open(root .. "/kxkbrc", "wb"))
		handle:write(KXKBRC)
		handle:close()
		local previous = os.getenv("XDG_CONFIG_HOME")
		assert(uv.os_setenv("XDG_CONFIG_HOME", root))
		local ok, text = pcall(function() return Switch.native_port().kde_config() end)
		if previous then uv.os_setenv("XDG_CONFIG_HOME", previous) else uv.os_unsetenv("XDG_CONFIG_HOME") end
		os.remove(root .. "/kxkbrc")
		uv.fs_rmdir(root)
		helpers.assert_true(ok, tostring(text))
		helpers.assert_eq(text, KXKBRC, "the KDE configuration comes from config_paths.config_home()")
	end)
end)

return true
