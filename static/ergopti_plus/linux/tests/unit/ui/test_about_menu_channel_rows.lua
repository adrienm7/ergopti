--- tests/unit/ui/test_about_menu_channel_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Owns The Updater Rows (Linux tray)
--- DESCRIPTION:
--- Linux had its updater as a separate top-level "Updates" submenu with its own
--- 'stable'/'dev' rows, where the other two drivers keep it under About. The
--- About submenu now carries the same block on all three: the version, one row
--- per channel of the shared registry (ticked on the subscribed one) right
--- before the check row, then the check frequency. Built through the real tray
--- builder and renderer, so a row the renderer drops fails here.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The submenu of the top-level row whose title is the translation of `key`.
local function submenu_of(items, key)
	local label = require("infra.i18n").get(key)
	for _, item in ipairs(items) do
		if item.title == label then return item.menu end
	end
	return nil
end

--- An updater double over the real shared channel registry.
local function fake_updater(subscribed)
	local real = require("modules.updater.manager")
	local calls = { set = {}, checks = 0 }
	local up = {
		CHANNELS = real.CHANNELS,
		INTERVAL_PRESETS = real.INTERVAL_PRESETS,
		TIMING = real.TIMING,
		current_version = function() return "0.0.0-dev.140" end,
		get_channel = function() return subscribed end,
		set_channel = function(id)
			calls.set[#calls.set + 1] = id
			subscribed = id
			return true
		end,
		get_check_interval = function() return real.INTERVAL_PRESETS[1].seconds end,
		get_menu_label = function() return require("infra.i18n").get("menu.about.check_for_updates") end,
		get_state = function() return "idle" end,
		get_cached_release = function() return nil end,
		check_for_updates = function() calls.checks = calls.checks + 1 return true end,
		releases_page_url = function() return real.releases_page_url() end,
	}
	return up, calls
end

-- Where the channel submenu sits: after the version row and its separator.
local CHANNEL_AT = 3

-- The build the version row names, fixed so the row does not depend on the
-- checkout the suite runs from. It is an installed build, as the release it
-- names is: the checkout itself is a source run, whose Update row is greyed.
local IDENTITY = { kind = "release", version = "0.0.0-dev.140", commit = "c3005e0b9" }

--- Keeps an installed-build fixture's native owner live through the later click.
--- The real consent bridge is exercised with an explicitly unavailable progress
--- window; these tray fixtures do not claim a native GUI or real download.
local function bind_action_owners(items, source_run)
	local unpack_results = table.unpack or unpack
	local function packed(...) return { n = select("#", ...), ... } end
	for _, item in ipairs(items) do
		if type(item.fn) == "function" then
			local action = item.fn
			item.fn = function(...)
				local Installation = require("infra.installation")
				local original_owner = Installation.is_source_run
				local original_progress = package.loaded["ui.download_window.bridge"]
				local original_webview = package.loaded["ui.webview_manager"]
				local arguments = packed(...)
				Installation.is_source_run = function() return source_run == true end
				package.loaded["ui.download_window.bridge"] = { show = function() return nil end }
				local result = packed(pcall(function()
					-- Keep the real consent/window path, with this click's native SDK
					-- explicitly unavailable instead of inheriting an earlier GTK owner.
					helpers.load_module_with_dependency("ui.webview_manager", "lgi", false)
					return action(unpack_results(arguments, 1, arguments.n))
				end))
				Installation.is_source_run = original_owner
				package.loaded["ui.download_window.bridge"] = original_progress
				package.loaded["ui.webview_manager"] = original_webview
				if not result[1] then error(result[2], 0) end
				return unpack_results(result, 2, result.n)
			end
		end
		if type(item.menu) == "table" then bind_action_owners(item.menu, source_run) end
	end
	return items
end

--- @param source_run boolean|nil True to build the tray of a local version.
local function build(up, changed, source_run)
	local Version = require("infra.version")
	local Installation = require("infra.installation")
	local real_identity = Version.identity
	local real_is_source_run = Installation.is_source_run
	Version.identity = function() return IDENTITY end
	Installation.is_source_run = function() return source_run == true end
	local mb = helpers.load_module("ui.menu.menu_builder")
	local ok, items = pcall(mb.build, {
		_version = "0.0.0-dev.140",
		updater = up,
		on_quit = function() end,
		on_menu_changed = function() if changed then changed.count = changed.count + 1 end end,
	})
	Version.identity = real_identity
	Installation.is_source_run = real_is_source_run
	if not ok then error(items, 0) end
	return bind_action_owners(items, source_run)
end

helpers.describe("tray (linux): the About submenu owns the updater rows", function()

	helpers.it("restores exact click owners after the controlled action raises", function()
		local Installation = require("infra.installation")
		local original_owner = Installation.is_source_run
		local original_progress = package.loaded["ui.download_window.bridge"]
		local original_webview = package.loaded["ui.webview_manager"]
		local original_lgi = package.loaded["lgi"]
		local original_preload = package.preload["lgi"]
		local rows = bind_action_owners({ { fn = function()
			local Webview = require("ui.webview_manager")
			helpers.assert_true(Webview ~= original_webview, "the click must own a fresh actual page manager")
			helpers.assert_eq(Webview._create_gtk_window("update_check", "unused", nil), false,
				"the click must refuse the exact unavailable native acquisition")
			error("Controlled tray action refusal", 0)
		end } }, false)
		local ok, err = pcall(rows[1].fn)
		helpers.assert_eq(ok, false, "the action refusal must reach its caller")
		helpers.assert_eq(err, "Controlled tray action refusal", "preserve the action failure")
		helpers.assert_eq(Installation.is_source_run, original_owner, "restore the exact installation owner")
		helpers.assert_eq(package.loaded["ui.download_window.bridge"], original_progress, "restore the exact progress owner")
		helpers.assert_eq(package.loaded["ui.webview_manager"], original_webview, "restore the exact page owner")
		helpers.assert_eq(package.loaded["lgi"], original_lgi, "restore the exact native SDK cache")
		helpers.assert_eq(package.preload["lgi"], original_preload, "restore the exact native SDK loader")
	end)
	helpers.it("has no separate top-level Updates submenu", function()
		local up = fake_updater("dev")
		for _, item in ipairs(build(up)) do
			helpers.assert_true(item.title ~= "🔄 Updates" and item.title ~= "🔄 Mises à jour",
				"the Updates submenu folded into About")
		end
	end)

	helpers.it("one channel submenu, titled with the subscribed channel, right before the check row", function()
		local i18n = require("infra.i18n")
		local template = i18n.get("menu.about.channel_menu")
		helpers.assert_true(template:find("{channel}", 1, true) ~= nil,
			"the title template must carry its placeholder, got '" .. template .. "'")
		local ids = fake_updater("dev").CHANNELS.ids()
		helpers.assert_true(#ids >= 2, "the registry must declare the channels")
		for _, subscribed in ipairs(ids) do
			local up = fake_updater(subscribed)
			local rows = submenu_of(build(up), "menu.about.title")
			helpers.assert_true(rows ~= nil, "the About submenu must be drawn")
			helpers.assert_true(rows[1].title:find("0.0.0-dev.140", 1, true) ~= nil
				and rows[1].title:find("c3005e0b9", 1, true) ~= nil, "the version row comes first")
			helpers.assert_eq(rows[2].title, "-", "a separator follows the version")
			local picker = rows[CHANNEL_AT]
			helpers.assert_eq(picker.title,
				(template:gsub("{channel}", i18n.get(up.CHANNELS.channel(subscribed).label_key))),
				"the title names the subscribed channel " .. subscribed)
			helpers.assert_eq(#picker.menu, #ids, "one row per registry channel")
			local ticked = 0
			for index, id in ipairs(ids) do
				helpers.assert_eq(picker.menu[index].title, i18n.get(up.CHANNELS.channel(id).menu_label_key),
					"channel row " .. index .. " reads its registry label, in registry order")
				if picker.menu[index].checked == true then
					ticked = ticked + 1
					helpers.assert_eq(id, subscribed, "only the subscribed channel is ticked")
				end
			end
			helpers.assert_eq(ticked, 1, "exactly one channel is ticked")
			helpers.assert_eq(rows[CHANNEL_AT + 1].title, i18n.get("menu.about.check_for_updates"),
				"the check row comes right after the channel submenu")
			helpers.assert_true(type(rows[CHANNEL_AT + 2].menu) == "table" and #rows[CHANNEL_AT + 2].menu > 0,
				"the check-frequency picker follows the check row")
		end
	end)

	helpers.it("no channel is a flat row of the About submenu any more", function()
		local up = fake_updater("dev")
		local rows = submenu_of(build(up), "menu.about.title")
		local i18n = require("infra.i18n")
		for _, row in ipairs(rows) do
			for _, id in ipairs(up.CHANNELS.ids()) do
				helpers.assert_true(row.title ~= i18n.get(up.CHANNELS.channel(id).menu_label_key),
					"the channel " .. id .. " must be listed inside the channel submenu only")
			end
		end
	end)

	helpers.it("a channel row subscribes to its own channel, redraws the tray and retitles it", function()
		local up, calls = fake_updater("dev")
		local changed = { count = 0 }
		local ids = up.CHANNELS.ids()
		for index = 1, #ids do
			submenu_of(build(up, changed), "menu.about.title")[CHANNEL_AT].menu[index].fn()
		end
		helpers.assert_eq(calls.set, ids, "each row must subscribe to its own channel, in registry order")
		helpers.assert_eq(changed.count, #ids, "the tray is redrawn so the tick follows the channel")
		local i18n = require("infra.i18n")
		local rows = submenu_of(build(up), "menu.about.title")
		helpers.assert_eq(rows[CHANNEL_AT].title, (i18n.get("menu.about.channel_menu"):gsub("{channel}",
			i18n.get(up.CHANNELS.channel(ids[#ids]).label_key))),
			"the redrawn title names the channel chosen last")
	end)

	helpers.it("keeps checking separate from consent to the displayed release", function()
		local up, calls = fake_updater("dev")
		local release = { tag = "v9.9.9", download_url = "https://example.invalid/displayed.tar.gz" }
		local downloads = {}
		up.get_state = function() return "available" end
		up.get_cached_release = function() return release end
		up.download_update = function(url) downloads[#downloads + 1] = url return true end
		local rows = submenu_of(build(up), "menu.about.title")
		local check_index = CHANNEL_AT + 1
		rows[check_index].fn()
		helpers.assert_eq(calls.checks, 1, "checking must still check after a release was found")
		helpers.assert_eq(#downloads, 0, "checking never authorizes a download")
		helpers.assert_true(rows[check_index + 1].title:find(release.tag, 1, true) ~= nil,
			"the separate install row must name the release it offers")
		rows[check_index + 1].fn()
		helpers.assert_eq(downloads, { release.download_url },
			"consent must retain the displayed URL so the manager can reject stale offers")
	end)

	-- The picker lists the shared presets (defaults.json, never last), and its
	-- parent row names the preset in force in words. A value outside the presets
	-- read as raw seconds ("Check frequency: 600") with no ticked row.
	helpers.it("the frequency picker lists the shared presets with translated labels", function()
		local Json = require("json")
		local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/updater/defaults.json", "rb"))
		local presets = Json.decode(handle:read("*a")).timing.check_interval_presets
		handle:close()
		helpers.assert_true(#presets >= 5, "the shared presets must be present")
		local i18n = require("infra.i18n")
		for _, pair in ipairs({ { 86400, "1d" }, { 600, "5m" }, { 0, "never" } }) do
			local up = fake_updater("dev")
			up.get_check_interval = function() return pair[1] end
			local rows = submenu_of(build(up), "menu.about.title")
			local picker = rows[CHANNEL_AT + 2]
			helpers.assert_eq(picker.title,
				i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency." .. pair[2]),
				"the parent row names the preset in force for " .. pair[1] .. " s")
			helpers.assert_eq(#picker.menu, #presets, "one row per shared preset")
			local ticked = 0
			for index, preset in ipairs(presets) do
				helpers.assert_eq(picker.menu[index].title, i18n.get("menu.about.frequency." .. preset.code),
					"preset row " .. index .. " reads its translated label")
				if picker.menu[index].checked == true then
					ticked = ticked + 1
					helpers.assert_eq(preset.code, pair[2], "the preset in force is the ticked row")
				end
			end
			helpers.assert_eq(ticked, 1, "exactly one preset row is ticked for " .. pair[1] .. " s")
		end
	end)

	-- A local version has no installation to update. Its check row and its
	-- frequency row stay in the menu, greyed with the reason, and run nothing:
	-- left live, they offered a check whose result could not be installed, and
	-- left out (as on Windows and macOS) nobody could tell the feature existed.
	helpers.it("(update-rows-greyed-on-local-2026-10-01) a local version draws the update rows greyed with their reason", function()
		local i18n = require("infra.i18n")
		local up, calls = fake_updater("dev")
		local rows = submenu_of(build(up, nil, true), "menu.about.title")
		local reason = i18n.get("menu.about.source_run_reason")
		local head = reason:match("^(.-)%s*[:：]") or reason
		local first = up.INTERVAL_PRESETS[1].code
		local expected = {
			i18n.get("menu.about.check_for_updates"),
			i18n.get("menu.about.frequency_menu") .. ": " .. i18n.get("menu.about.frequency." .. first),
		}
		local found = {}
		for index, row in ipairs(rows) do
			for at, label in ipairs(expected) do
				if type(row.title) == "string" and row.title:find(label, 1, true) == 1 then found[at] = index end
			end
		end
		helpers.assert_true(found[1] ~= nil and found[2] ~= nil, "both update rows are drawn on a local version")
		helpers.assert_true(found[2] > found[1], "the frequency row follows the check row")
		for at, label in ipairs(expected) do
			local row = rows[found[at]]
			helpers.assert_eq(row.title, label .. " — " .. head, "the row says why it is greyed")
			helpers.assert_eq(row.disabled, true, label .. " is greyed")
			helpers.assert_nil(row.fn, label .. " runs nothing")
			helpers.assert_nil(row.menu, label .. " opens nothing")
		end
		helpers.assert_eq(calls.checks, 0, "a local version checks for nothing")
		for _, row in ipairs(submenu_of(build(fake_updater("dev")), "menu.about.title")) do
			helpers.assert_true(type(row.title) ~= "string" or row.title:find(head, 1, true) == nil,
				"an installed build greys no row for this reason: " .. tostring(row.title))
		end
	end)

	-- A menu change used to leave an open Versions page offering the channel the
	-- user had just picked.
	helpers.it("a channel row tells an open Versions page", function()
		local up = fake_updater("dev")
		local Bridge = require("ui.changelog.bridge")
		local previous_push = Bridge._push
		local pushed = {}
		Bridge._push = function(payload) pushed[#pushed + 1] = payload; return true end
		local ok, err = pcall(function()
			local rows = submenu_of(build(up), "menu.about.title")
			local ids = up.CHANNELS.ids()
			rows[CHANNEL_AT].menu[1].fn()
			helpers.assert_eq(#pushed, 1, "the page must hear of the change once")
			helpers.assert_eq(pushed[1].action, "channel_changed")
			helpers.assert_eq(pushed[1].channel, ids[1])
		end)
		Bridge._push = previous_push
		if not ok then error(err, 0) end
	end)
end)


--- Independent presentation captured before replacing the native picker.
local function channel_corpus()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/update_channel_rows.json", "rb"))
	local raw = handle:read("*a")
	handle:close()
	return assert(require("json").decode(raw))
end

helpers.describe("tray (linux): published About channel choices", function()
	helpers.it("retains the captured two states through the actual About provider", function()
		local corpus = channel_corpus()
		local i18n = require("infra.i18n")
		local prior = i18n.get
		local ok, detail = pcall(function()
			for _, locale in ipairs({ "en", "fr" }) do
				local handle = assert(io.open(helpers.driver_root() .. "/../_shared/data/locales/" .. locale .. ".json", "rb"))
				local labels = assert(require("json").decode(handle:read("*a")))
				handle:close()
				i18n.get = function(key) return labels[key] or key end
				for index, state in ipairs(corpus.states) do
					local rows = submenu_of(build((fake_updater(state.selected))), "menu.about.title")
					local row = rows[CHANNEL_AT]
					helpers.assert_eq(row.title, corpus.locales[locale].captions[index])
					helpers.assert_eq(#row.menu, 2)
					for at, leaf in ipairs(row.menu) do
						helpers.assert_eq(leaf.title, corpus.locales[locale].leaf_labels[at])
						helpers.assert_eq(leaf.checked, state.checked[at])
					end
				end
			end
		end)
		i18n.get = prior
		if not ok then error(detail, 0) end
	end)

	helpers.it("consumes alternate published order instead of a private registry loop", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local previous = root.about_update_channel_menu
		local corpus, choices = channel_corpus(), {}
		for _, value in ipairs(corpus.reordered_values) do
			for _, choice in ipairs(corpus.choices) do
				if choice.value == value then choices[#choices + 1] = choice end
			end
		end
		root.about_update_channel_menu = { {
			type = "choice", id = "update_channel", path = "updater.channel",
			i18n = "menu.about.channel_menu", show_current_choice = true,
			current_choice_placeholder = "{channel}", choices = choices,
		} }
		local ok, detail = pcall(function()
			local up, requests = fake_updater("main")
			local row = submenu_of(build(up), "menu.about.title")[CHANNEL_AT]
			helpers.assert_eq(#row.menu, 2)
			for index, choice in ipairs(choices) do
				helpers.assert_eq(row.menu[index].title, require("infra.i18n").get(choice.i18n))
				row.menu[index].fn()
			end
			helpers.assert_eq(requests.set, corpus.reordered_values)
		end)
		root.about_update_channel_menu = previous
		if not ok then error(detail, 0) end
	end)

	helpers.it("does not redraw or update Versions after refused preference writes", function()
		local previous_bridge = package.loaded["ui.changelog.bridge"]
		local pushed = {}
		package.loaded["ui.changelog.bridge"] = { push_subscribed_channel = function(id) pushed[#pushed + 1] = id end }
		local ok, detail = pcall(function()
			for _, refusal in ipairs(channel_corpus().refusals) do
				local up, requests = fake_updater("main")
				up.set_channel = function(id)
					requests.set[#requests.set + 1] = id
					if refusal == "throw" then error("refused channel write") end
					if refusal == "false" then return false end
					return nil
				end
				local changed = { count = 0 }
				local row = submenu_of(build(up, changed), "menu.about.title")[CHANNEL_AT]
				local accepted, result = pcall(row.menu[2].fn)
				helpers.assert_eq(accepted, true, "the native owner exception is a refused callback")
				helpers.assert_eq(result, false, "the native receipt must be exact true")
				helpers.assert_eq(requests.set, { "dev" })
				helpers.assert_eq(up.get_channel(), "main")
				helpers.assert_eq(changed.count, 0)
				helpers.assert_eq(#pushed, 0)
			end
		end)
		package.loaded["ui.changelog.bridge"] = previous_bridge
		if not ok then error(detail, 0) end
	end)
end)


--- Reads independent numeric values and snapped caption expectations.
local function frequency_corpus()
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/tests/corpus/menus/update_check_frequency.json", "rb"))
	local raw = assert(handle:read("*a"))
	assert(handle:close())
	return assert(require("json").decode(raw))
end

--- Exercises the actual manager and menu around durable writer and timer ports.
local function with_frequency_owner(refusal, body)
	local names = {"adapters.timer_scheduler", "adapters.storage", "modules.updater.manager"}
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local writer = require("toml_codec.writer")
	local previous_write = writer.batch_write
	local Installation = require("infra.installation")
	local previous_source_run = Installation.is_source_run
	Installation.is_source_run = function() return false end
	local obs = {timers = {}, cancels = 0, writes = 0, redraws = {count = 0}, requests = 0}
	local path = os.tmpname()
	local original = "[updater]\ncheck_interval_seconds = 3600\nfuture_interval_option = 42\n"
	local file = assert(io.open(path, "wb"))
	assert(file:write(original)); assert(file:close())
	package.loaded["adapters.timer_scheduler"] = {
		HAS_ASYNC = true,
		after = function(delay, fn)
			local handle = {delay = delay, fn = fn, armed = true}
			obs.timers[#obs.timers + 1] = handle
			return handle
		end,
		cancel = function(handle) obs.cancels = obs.cancels + 1; handle.armed = false; return true end,
	}
	package.loaded["adapters.storage"] = require("tests.fakes").storage({initial = {}})
	package.loaded["modules.updater.manager"] = nil
	local up = require("modules.updater.manager")
	up._now = function() return 1700000000 end
	up.current_version = function() return "1.0.0" end
	up.check_for_updates = function() obs.requests = obs.requests + 1; return false end
	local ok, detail = pcall(function()
		up.init({config_path = path, is_paused = function() return false end})
		writer.batch_write = function(...)
			obs.writes = obs.writes + 1
			if refusal == "throw" then error("The cadence writer refused.") end
			if refusal == "false" then return false end
			if refusal == "nil" then return nil end
			return previous_write(...)
		end
		body(up, obs, path, original)
	end)
	up.stop_background_checks()
	writer.batch_write = previous_write
	Installation.is_source_run = previous_source_run
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	os.remove(path)
	if not ok then error(detail, 0) end
end

helpers.describe("shared updater frequency choices (Linux)", function()
	helpers.it("projects independent presets and actual snap values into real menu rows (shared-update-frequency)", function()
		local corpus = frequency_corpus()
		helpers.assert_eq(#corpus.choices, 10)
		for _, expected in ipairs(corpus.snapped_states) do
			local up = fake_updater("dev")
			up.get_check_interval = function() return expected.stored end
			local row = submenu_of(build(up), "menu.about.title")[CHANNEL_AT + 2]
			local i18n = require("infra.i18n")
			helpers.assert_eq(row.title, i18n.get(corpus.i18n) .. ": " .. i18n.get("menu.about.frequency." .. expected.code))
			helpers.assert_eq(#row.menu, #corpus.choices)
			for index, choice in ipairs(corpus.choices) do
				helpers.assert_eq(row.menu[index].title, i18n.get(choice.i18n))
				helpers.assert_eq(row.menu[index].checked, choice.value == expected.value)
			end
		end
	end)

	helpers.it("keeps durable bytes runtime cadence timer and redraw on actual writer refusal (shared-update-frequency)", function()
		for _, refusal in ipairs({"false", "nil", "throw"}) do
			with_frequency_owner(refusal, function(up, obs, path, original)
				local row = submenu_of(build(up, obs.redraws), "menu.about.title")[CHANNEL_AT + 2]
				local timers, cancels = #obs.timers, obs.cancels
				local current_timer = obs.timers[#obs.timers]
				helpers.assert_true(current_timer ~= nil and current_timer.armed, "the native schedule must be owned before refusal")
				local result = row.menu[1].fn()
				helpers.assert_eq(up.get_check_interval(), 3600)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a")); assert(file:close())
				helpers.assert_eq(bytes, original)
				helpers.assert_eq(obs.writes, 1)
				helpers.assert_true(current_timer.armed, "a refused preference cannot retire the owned timer")
				helpers.assert_eq(obs.cancels, cancels, "a refused write cannot release the current timer")
				helpers.assert_eq(#obs.timers, timers, "a refused write cannot restart the background schedule")
				helpers.assert_eq(obs.redraws.count, 0)
				helpers.assert_eq(result, false)
			end)
		end
	end)

	helpers.it("returns acknowledged writes preserves unknown preferences and replays absolute held selections (shared-update-frequency)", function()
		with_frequency_owner(nil, function(up, obs, path)
			local row = submenu_of(build(up, obs.redraws), "menu.about.title")[CHANNEL_AT + 2]
			local selected = frequency_corpus().choices[1].value
			local held = row.menu[1].fn
			local result = held()
			helpers.assert_eq(up.get_check_interval(), selected)
			helpers.assert_eq(obs.writes, 1)
			helpers.assert_eq(obs.redraws.count, 1)
			local file = assert(io.open(path, "rb"))
			local bytes = assert(file:read("*a")); assert(file:close())
			helpers.assert_true(bytes:find("future_interval_option = 42", 1, true) ~= nil)
			helpers.assert_true(bytes:find("check_interval_seconds = " .. selected, 1, true) ~= nil)
			helpers.assert_eq(result, true)
			helpers.assert_eq(held(), true)
			helpers.assert_eq(obs.writes, 1, "an acknowledged absolute selection does not need another write")
		end)
	end)

	helpers.it("consumes the published labels order and numeric mutation values (shared-update-frequency)", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local previous = root.about_update_frequency_menu
		local corpus, choices = frequency_corpus(), {}
		for index = #corpus.choices, 1, -1 do
			local source = corpus.choices[index]
			choices[#choices + 1] = {value = source.value, i18n = source.i18n}
		end
		choices[1].i18n = corpus.alternate_i18n
		root.about_update_frequency_menu = {{type = "choice", id = corpus.id, path = corpus.path,
			i18n = corpus.i18n, show_current_choice = true, current_choice_suffix = corpus.suffix,
			choices = choices}}
		local ok, detail = pcall(function()
			local up, calls = fake_updater("dev"), {}
			up.set_check_interval = function(value) calls[#calls + 1] = value; return true end
			up.stop_background_checks = function() return true end
			up.start_background_checks = function() return true end
			local row = submenu_of(build(up), "menu.about.title")[CHANNEL_AT + 2]
			helpers.assert_eq(#row.menu, #choices)
			for index, choice in ipairs(choices) do
				helpers.assert_eq(row.menu[index].title, require("infra.i18n").get(choice.i18n))
				row.menu[index].fn()
				helpers.assert_eq(calls[index], choice.value)
			end
		end)
		root.about_update_frequency_menu = previous
		if not ok then error(detail, 0) end
	end)
end)


--- Exercises the real About provider with unrelated tray surfaces isolated.
--- @param alternative boolean True to independently replace the declaration's label and reason.
local function with_source_command(alternative, callback)
	local names = { "ui.menu.menu_builder", "infra.manifest_menu", "infra.paths", "infra.i18n",
		"window_titles", "action_parameter_label", "hotstrings.extensions", "hotstrings.languages",
		"_generated.locale_table", "keymap.magic_key_source", "modules.hotstrings.magic_key",
		"modules.hotstrings.preview_settings", "modules.hotstrings.repeat_key", "ui.modal", "ui.text_prompt",
		"llm.trigger_policy", "infra.version", "infra.installation", "ui.menu.start_at_login" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = {} end
	local ok, err = xpcall(function()
		local seen = { effects = 0 }
		local function effect() seen.effects = seen.effects + 1; return false end
		local labels = { ["menu.about.source_run_reason"] = "Source checkout: use an installed release.",
			["common.restore_recommended"] = "Canonical alternate label",
			["common.clear_to_system"] = "Canonical alternate reason: inert control." }
		package.loaded["infra.i18n"] = { get = function(key) return labels[key] or key end,
			section = function(key) return labels[key] or key end }
		local source = debug.getinfo(1, "S").source:gsub("^@", "")
		local driver = assert(source:match("^(.*)/tests/unit/ui/"))
		package.loaded["infra.paths"] = { shared = function(relative) return driver .. "/../_shared/" .. relative end }
		package.loaded["infra.version"] = { identity = function()
			return {kind = "local", version = "", commit = "known"}
		end }
		package.loaded["infra.installation"] = { is_source_run = function() return true end }
		package.loaded["ui.menu.start_at_login"] = { enabled = function() return false end }
		package.loaded["infra.manifest_menu"] = nil
		local renderer = require("infra.manifest_menu")
		package.loaded["infra.manifest_menu"] = setmetatable({ get_array = function(key)
			if key == "top_level" then return {{id = "about"}} end
			return renderer.get_array(key)
		end }, { __index = renderer })
		local declaration = renderer.get_array("about_source_menu")
		helpers.assert_eq(#declaration, 1)
		if alternative then
			declaration[1].i18n = "common.restore_recommended"
			declaration[1].disabled_reason_key = "common.clear_to_system"
		end
		local handle = assert(io.open(driver .. "/../_shared/modules/updater/defaults.json", "rb"))
		local timing = require("json").decode(assert(handle:read("*a"))).timing
		assert(handle:close())
		local up = { get_channel = function() return "dev" end, set_channel = effect,
			get_check_interval = function() return timing.default_check_interval_sec end,
			TIMING = timing, get_menu_label = function() error("A source checkout has no live update label.") end,
			get_state = function() return "idle" end,
			check_for_updates = effect, install = effect, get_cached_release = function() return nil end }
		package.loaded["ui.menu.menu_builder"] = nil
		local rows = require("ui.menu.menu_builder").build({ updater = up, on_quit = effect,
			on_menu_changed = effect, webview = { show = effect } })
		local title = alternative and labels["common.restore_recommended"] or "menu.about.check_for_updates"
		local reason = alternative and "Canonical alternate reason" or "Source checkout"
		local function find(items)
			for _, row in ipairs(items or {}) do
				if row.title == title .. " — " .. reason then return row end
				local nested = find(row.menu)
				if nested then return nested end
			end
		end
		callback(find(rows), seen)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("About source check shared command", function()
	helpers.it("keeps the original disabled reason without native update window install or redraw effects (about-source-command)", function()
		with_source_command(false, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)

	helpers.it("uses the actual declared label and reason instead of native source-only literals (about-source-command)", function()
		with_source_command(true, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)
end)


helpers.describe("Linux About channel durable receipts", function()
	for _, outcome in ipairs({"false", "nil", "number", "throw", "true"}) do
		helpers.it("publishes menu and Versions effects only after exact native ACK (channel-ack " .. outcome .. ")", function()
			local previous_bridge = package.loaded["ui.changelog.bridge"]
			local pushes, calls = 0, 0
			package.loaded["ui.changelog.bridge"] = {push_subscribed_channel = function() pushes = pushes + 1 end}
			local ok, detail = xpcall(function()
				local up = fake_updater("main")
				up.set_channel = function()
					calls = calls + 1
					if outcome == "throw" then error("The native owner refused.") end
					if outcome == "number" then return 2 end
					if outcome == "nil" then return nil end
					return outcome == "true"
				end
				local changed = {count = 0}
				local held = submenu_of(build(up, changed), "menu.about.title")[CHANNEL_AT].menu[2].fn
				local protected, accepted = pcall(held)
				helpers.assert_eq(protected, true)
				helpers.assert_eq(accepted, outcome == "true")
				helpers.assert_eq(calls, 1)
				helpers.assert_eq(changed.count, outcome == "true" and 1 or 0)
				helpers.assert_eq(pushes, outcome == "true" and 1 or 0)
			end, debug.traceback)
			package.loaded["ui.changelog.bridge"] = previous_bridge
			if not ok then error(detail, 0) end
		end)
	end

	for _, outcome in ipairs({"false", "nil", "number", "throw"}) do
		helpers.it("retries actual updater persistence after refusal without changing canonical bytes (channel-ack durable " .. outcome .. ")", function()
			with_frequency_owner(nil, function(up, obs, path, original)
				local writer = require("toml_codec.writer")
				local previous_write = writer.batch_write
				local refusing, writes = true, 0
				writer.batch_write = function(...)
					writes = writes + 1
					if refusing then
						if outcome == "throw" then error("The canonical writer refused.") end
						if outcome == "number" then return 2 end
						if outcome == "false" then return false end
						return nil
					end
					return previous_write(...)
				end
				local initial = up.get_channel()
				local row = submenu_of(build(up, obs.redraws), "menu.about.title")[CHANNEL_AT]
				local target = initial == "main" and "dev" or "main"
				local held = row.menu[target == "main" and 1 or 2].fn
				local accepted = held()
				local file = assert(io.open(path, "rb")); local bytes = file:read("*a"); assert(file:close())
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(bytes, original)
				helpers.assert_eq(up.get_channel(), initial)
				helpers.assert_eq(obs.redraws.count, 0)
				helpers.assert_eq(writes, 1)
				refusing = false
				helpers.assert_eq(held(), true)
				local saved = assert(io.open(path, "rb")); local committed = saved:read("*a"); assert(saved:close())
				helpers.assert_true(committed:find('channel = "' .. target .. '"', 1, true) ~= nil)
				helpers.assert_true(committed:find("future_interval_option = 42", 1, true) ~= nil)
				helpers.assert_eq(up.get_channel(), target)
				helpers.assert_eq(obs.redraws.count, 1)
				helpers.assert_eq(writes, 2)
				helpers.assert_eq(held(), true)
				helpers.assert_eq(writes, 2)
			end)
		end)
	end
end)
