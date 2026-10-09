--- tests/unit/ui/menu/test_menu_about_check_row.lua

--- ==============================================================================
--- MODULE: The About Check Row Opens The Update-Check Window (macOS)
--- DESCRIPTION:
--- "Check for updates" used to hand the check to Sparkle, whose English,
--- left-aligned alert named no channel. The row now opens the shared
--- update-check window over the menu session's automatic-check and channel
--- owners; a row that already names a found release is the user's consent and
--- still goes straight to Sparkle. Built through the real builder and renderer.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Builds the About submenu of a packaged build and returns its check row with
--- the recorded window opens and Sparkle requests.
local function build(latest)
	local recorded = { opens = {}, requests = {} }
	local saved = {
		window = package.loaded["ui.update_check"],
		launcher = package.loaded["adapters.update_launcher"],
	}
	package.loaded["ui.update_check"] = {
		open = function(opts) recorded.opens[#recorded.opens + 1] = opts; return true end,
	}
	package.loaded["adapters.update_launcher"] = {
		request_check = function(channel) recorded.requests[#recorded.requests + 1] = channel; return true end,
		select_channel = function() return true end,
	}
	local Updater = require("modules.updater")
	local real_local = Updater.is_local_source
	Updater.is_local_source = function() return false end
	package.loaded["ui.menu.menu_about"] = nil
	local owner = { get = function() return "dev" end, set = function() return true end, subscribe = function() end }
	local checks = {
		presets = function() return {} end,
		interval_code = function() return "1d" end,
		interval = function() return 86400 end,
		set_interval = function() return true end,
		latest = function() return latest end,
	}
	local refresh = function() end
	local ok, rows = pcall(function()
		local About = helpers.load_with_stubs("ui.menu.menu_about")
		return About.build({ channel_owner = owner, update_checks = checks, updateMenu = refresh }, {
			start_at_login = function() error("Building About must not change startup.") end,
			uninstall = function() error("Building About must not uninstall the application.") end,
		}).submenu
	end)
	Updater.is_local_source = real_local
	package.loaded["ui.menu.menu_about"] = nil
	local function restore()
		package.loaded["ui.update_check"] = saved.window
		package.loaded["adapters.update_launcher"] = saved.launcher
	end
	if not ok then restore(); error(rows, 0) end
	recorded.owner, recorded.checks, recorded.refresh, recorded.restore = owner, checks, refresh, restore
	local i18n = require("infra.i18n")
	for _, row in ipairs(rows) do
		if row.title == i18n.get("menu.about.check_for_updates")
			or (latest and type(row.title) == "string" and row.title:find(latest.tag, 1, true)) then
			recorded.row = row
		end
	end
	return recorded
end

helpers.describe("menu_about: the check row (macOS)", function()
	helpers.it("opens the update-check window over the menu session's owners", function()
		local recorded = build(nil)
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the About submenu offers the check row")
			recorded.row.fn()
			helpers.assert_eq(#recorded.opens, 1, "the click opens the update-check window")
			helpers.assert_eq(#recorded.requests, 0, "Sparkle is not asked to check")
			helpers.assert_true(recorded.opens[1].checks == recorded.checks, "the window checks through the Lua owner")
			helpers.assert_true(recorded.opens[1].channel_owner == recorded.owner, "switches go through the channel owner")
			helpers.assert_true(recorded.opens[1].on_change == recorded.refresh, "the menu refreshes after an answer")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)

	helpers.it("a row that names a found release installs it through Sparkle", function()
		local recorded = build({ tag = "v0.0.0-dev.150", channel = "dev" })
		local ok, err = pcall(function()
			helpers.assert_not_nil(recorded.row, "the row names the found release")
			recorded.row.fn()
			helpers.assert_eq(recorded.requests, { "dev" }, "Sparkle installs from the release's channel")
			helpers.assert_eq(#recorded.opens, 0, "no second check before the consented install")
		end)
		recorded.restore()
		if not ok then error(err, 0) end
	end)
end)


--- Exercises the actual source-only provider through its native-bound renderer.
--- @param alternative boolean True to independently replace the declared label and reason.
local function with_source_row(alternative, callback)
	helpers.with_stub_scope({ "ui.menu.menu_about", "infra.manifest_menu", "infra.paths", "infra.i18n",
		"infra.logger", "adapters.json_codec", "modules.updater", "modules.updater.auto_check",
		"ui.changelog", "adapters.update_launcher", "ui.menu.start_at_login", "hs", "tests.stubs.hs" }, function()
		local native = require("tests.stubs.hs")
		native.__reset()
		_G.hs = native
		package.loaded["hs"] = native
		local seen = { effects = 0 }
		local function effect() seen.effects = seen.effects + 1; return false end
		local labels = { ["menu.about.source_run_reason"] = "Source checkout: use an installed release.",
			["common.restore_recommended"] = "Canonical alternate label",
			["common.clear_to_system"] = "Canonical alternate reason: inert control." }
		package.loaded["infra.i18n"] = { get = function(key) return labels[key] or key end,
			section = function(key) return labels[key] or key end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.paths"] = { shared = helpers.shared }
		package.loaded["modules.updater"] = {
			is_local_source = function() return true end,
			installed_channel = function() return "dev" end,
			build_identity = function() return { kind = "local", version = "", commit = "known" } end,
			releases_page_url = function() return "https://example.invalid/releases" end,
		}
		local defaults_file = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
		local defaults = assert(require("adapters.json_codec").decode(assert(defaults_file:read("*a"))))
		assert(defaults_file:close())
		package.loaded["modules.updater.auto_check"] = { stored_interval = function()
			return defaults.timing.default_check_interval_sec
		end }
		package.loaded["ui.changelog"] = { open = effect }
		package.loaded["adapters.update_launcher"] = { request_check = effect, select_channel = effect }
		package.loaded["ui.menu.start_at_login"] = { enabled = function() return false end }
		local renderer = require("infra.manifest_menu")
		local declaration = renderer.get_array("about_source_menu")
		helpers.assert_eq(#declaration, 1)
		if alternative then
			declaration[1].i18n = "common.restore_recommended"
			declaration[1].disabled_reason_key = "common.clear_to_system"
		end
		local title = alternative and labels["common.restore_recommended"] or "menu.about.check_for_updates"
		local reason = alternative and "Canonical alternate reason" or "Source checkout"
		local owner = { get = function() return "dev" end, set = effect }
		local About = require("ui.menu.menu_about")
		local rows = About.build({ channel_owner = owner, state = {} }, {
			start_at_login = effect, uninstall = effect,
		}).submenu
		local found
		for _, row in ipairs(rows) do if row.title == title .. " — " .. reason then found = row end end
		callback(found, seen)
	end)
end

helpers.describe("About source check shared command", function()
	helpers.it("keeps the original disabled reason and exposes no native update or window action (about-source-command)", function()
		with_source_row(false, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)

	helpers.it("uses the actual declared label and reason instead of source-only native literals (about-source-command)", function()
		with_source_row(true, function(row, seen)
			helpers.assert_type(row, "table")
			helpers.assert_eq(row.disabled, true)
			helpers.assert_nil(row.fn)
			helpers.assert_nil(row.menu)
			helpers.assert_nil(row.checked)
			helpers.assert_eq(seen.effects, 0)
		end)
	end)
end)


--- Runs a retained real About callback and restores its recorded native ports.
--- @param offer table Initially displayed release.
--- @param callback function Test observations outside the protected action.
local function with_retained_offer(offer, callback)
	local recorded = build(offer)
	local ok, err = pcall(callback, recorded)
	recorded.restore()
	if not ok then error(err, 0) end
end

helpers.describe("About retained release consent", function()
	helpers.it("acknowledges the unchanged actual offer only after the launcher accepts", function()
		with_retained_offer({ tag = "v0.0.0-dev.150", channel = "dev" }, function(recorded)
			local accepted = recorded.row.fn()
			helpers.assert_eq(accepted, true)
			helpers.assert_eq(recorded.requests, { "dev" })
			helpers.assert_eq(#recorded.opens, 0)
		end)
	end)

	for _, change in ipairs({ "channel", "cleared", "replaced", "borrowed_tag", "borrowed_channel" }) do
		helpers.it("retires the held callback after its offer changes: " .. change, function()
			local offer = { tag = "v0.0.0-dev.150", channel = "dev" }
			with_retained_offer(offer, function(recorded)
				if change == "channel" then
					recorded.owner.get = function() return "main" end
				elseif change == "cleared" then
					recorded.checks.latest = function() return nil end
				elseif change == "replaced" then
					recorded.checks.latest = function() return { tag = "v0.0.0-dev.151", channel = "dev" } end
				elseif change == "borrowed_tag" then
					offer.tag = "v0.0.0-dev.151"
				else
					offer.channel = "main"
					recorded.owner.get = function() return "main" end
				end
				local accepted = recorded.row.fn()
				helpers.assert_eq(#recorded.requests, 0, "a retired offer never chooses a Sparkle feed")
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#recorded.opens, 0)
			end)
		end)
	end

	for _, invalid in ipairs({ "owner_missing", "owner_throw", "channel_number", "checks_missing", "checks_throw",
		"offer_number", "tag_missing", "tag_number", "channel_missing", "channel_boolean" }) do
		helpers.it("refuses missing or malformed current owner data: " .. invalid, function()
			with_retained_offer({ tag = "v0.0.0-dev.150", channel = "dev" }, function(recorded)
				if invalid == "owner_missing" then recorded.owner.get = nil
				elseif invalid == "owner_throw" then recorded.owner.get = function() error("inert owner refusal") end
				elseif invalid == "channel_number" then recorded.owner.get = function() return 1 end
				elseif invalid == "checks_missing" then recorded.checks.latest = nil
				elseif invalid == "checks_throw" then recorded.checks.latest = function() error("inert check refusal") end
				else
					local current = { tag = "v0.0.0-dev.150", channel = "dev" }
					if invalid == "offer_number" then current = 1
					elseif invalid == "tag_missing" then current.tag = nil
					elseif invalid == "tag_number" then current.tag = 150
					elseif invalid == "channel_missing" then current.channel = nil
					else current.channel = true end
					recorded.checks.latest = function() return current end
				end
				local accepted = recorded.row.fn()
				helpers.assert_eq(#recorded.requests, 0)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#recorded.opens, 0)
			end)
		end)
	end

	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("returns strict refusal from the actual launcher port: " .. outcome, function()
			with_retained_offer({ tag = "v0.0.0-dev.150", channel = "dev" }, function(recorded)
				package.loaded["adapters.update_launcher"].request_check = function(channel)
					recorded.requests[#recorded.requests + 1] = channel
					if outcome == "throw" then error("inert launcher refusal") end
					if outcome == "number" then return 1 end
					if outcome == "text" then return "accepted" end
					if outcome == "false" then return false end
					return nil
				end
				local accepted = recorded.row.fn()
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(recorded.requests, { "dev" })
				helpers.assert_eq(#recorded.opens, 0)
			end)
		end)
	end
end)


--- Uses the real channel and automatic-check owners to replace or retire an offer.
--- @param mutation string Public owner operation exercised before the held click.
local function public_owner_retirement(mutation)
	helpers.with_stub_scope({ "modules.updater.channel", "modules.updater.auto_check" }, function()
		with_retained_offer({ tag = "v0.0.0-dev.150", channel = "dev" }, function(recorded)
			local state, values, saved, tag = { update_channel = "dev" }, {}, {}, "v0.0.0-dev.150"
			local channel = require("modules.updater.channel").new({ state = state, save = function()
				saved[#saved + 1] = state.update_channel; return true
			end })
			local AutoCheck = require("modules.updater.auto_check")
			local checks = AutoCheck.new({
				state = state, save = function() return true end, channel = channel.get,
				is_paused = function() return false end, on_available = function() return true end,
				config = AutoCheck.load_config(), now = function() return 1700000000 end,
				current_version = function() return "0.0.0-dev.140" end,
				installed_channel = function() return "dev" end,
				timer = { after = function() error("inactive public owner must not arm a timer") end,
					cancel = function() return true end },
				storage = { get = function(key, default) return values[key] or default end,
					set = function(key, value) values[key] = value; return true end },
				http = { get = function(url, headers, callback)
					callback({ ok = true, status = 200, headers = {}, body =
						'[{"tag_name":"' .. tag .. '","prerelease":true,"published_at":"2026-09-02T00:00:00Z","assets":[]}]' })
					return true
				end },
			})
			local answers = {}
			local dispatched = checks.check_now("dev", function(result) answers[#answers + 1] = result end)
			helpers.assert_eq(dispatched, true)
			helpers.assert_eq(answers[1].state, "available")
			helpers.assert_eq(checks.latest().tag, "v0.0.0-dev.150")
			recorded.owner.get, recorded.checks.latest = channel.get, checks.latest
			channel.subscribe("retained_about_offer", checks.on_channel_changed)
			if mutation == "channel" then
				local committed = channel.set("main")
				helpers.assert_eq(committed, true)
				helpers.assert_eq(saved, { "main" })
				helpers.assert_nil(checks.latest(), "actual subscription publication retires the old offer")
			elseif mutation == "cleared" then
				local retired = checks.on_channel_changed()
				helpers.assert_eq(retired, true)
				helpers.assert_nil(checks.latest())
			else
				tag = "v0.0.0-dev.151"
				local replaced = checks.check_now("dev", function(result) answers[#answers + 1] = result end)
				helpers.assert_eq(replaced, true)
				helpers.assert_eq(checks.latest().tag, "v0.0.0-dev.151")
			end
			local accepted = recorded.row.fn()
			helpers.assert_eq(#recorded.requests, 0, "public retirement cannot be bypassed by a retained native row")
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#recorded.opens, 0)
		end)
	end)
end

helpers.describe("About actual public owner retirement", function()
	for _, mutation in ipairs({ "channel", "cleared", "replaced" }) do
		helpers.it("preserves actual owner retirement before held native installation: " .. mutation, function()
			public_owner_retirement(mutation)
		end)
	end
end)


--- Observes the actual native-bound renderer; every row still comes from its real builder.
local function with_declared_packaged_check(definition, offer, body)
	local renderer = require("infra.manifest_menu")
	local root = renderer.get_root()
	local previous, original_build = root.about_source_menu, renderer.build
	local captured
	if definition ~= false then root.about_source_menu = definition end
	renderer.build = function(...)
		local result = original_build(...)
		captured = result
		return result
	end
	local recorded
	local ok, detail = xpcall(function()
		recorded = build(offer)
		body(recorded, captured, root)
	end, debug.traceback)
	if recorded then recorded.restore() end
	root.about_source_menu, renderer.build = previous, original_build
	if not ok then error(detail, 0) end
end

helpers.describe("Packaged About check consumes the existing shared command", function()
	helpers.it("retains the existing canonical declaration and no-offer native window owner", function()
		with_declared_packaged_check(false, nil, function(recorded, _, root)
			local row = root.about_source_menu[1]
			helpers.assert_eq(row.type, "command")
			helpers.assert_eq(row.id, "about_source_check")
			helpers.assert_eq(row.i18n, "menu.about.check_for_updates")
			helpers.assert_eq(row.disabled_when, {"about_source_release_ready"})
			helpers.assert_not_nil(recorded.row)
			recorded.row.fn()
			helpers.assert_eq(#recorded.opens, 1)
			helpers.assert_eq(#recorded.requests, 0)
			helpers.assert_true(recorded.opens[1].checks == recorded.checks)
			helpers.assert_true(recorded.opens[1].channel_owner == recorded.owner)
		end)
	end)
	helpers.it("consumes the existing shared label through the actual renderer in all21 locales", function()
		local handle = assert(io.open(helpers.shared("data/locale_order.json"), "rb"))
		local locales = assert(require("adapters.json_codec").decode(handle:read("*a"))).order; assert(handle:close())
		helpers.assert_eq(#locales, 21)
		for _, locale in ipairs(locales) do
			local file = assert(io.open(helpers.shared("data/locales/" .. locale .. ".json"), "rb"))
			local labels = assert(require("adapters.json_codec").decode(file:read("*a"))); assert(file:close())
			-- The native binding captures its catalogue object at construction.
			-- Bind each real catalogue before the existing build helper resets stubs.
			helpers.with_stub_scope({"infra.manifest_menu", "infra.i18n", "ui.menu.menu_about"}, function()
				local native_i18n = require("infra.i18n")
				native_i18n.get = function(key) return labels[key] or key end
				package.loaded["infra.manifest_menu"] = nil
				local renderer = require("infra.manifest_menu")
				renderer.get_root().about_source_menu[1].i18n = "common.restore_recommended"
				with_declared_packaged_check(false, nil, function(recorded, rendered)
					local found
					for _, row in ipairs(rendered) do if row.title == labels["common.restore_recommended"] then found = row end end
					helpers.assert_not_nil(found, "actual shared packaged caption: " .. locale)
					helpers.assert_eq(found.disabled, nil)
					found.fn()
					helpers.assert_eq(#recorded.opens, 1)
					helpers.assert_eq(#recorded.requests, 0)
				end)
			end)
		end
	end)
	for _, offered in ipairs({false, true}) do
		helpers.it("refuses a missing declared check owner before publication (offer=" .. tostring(offered) .. ")", function()
			local offer = offered and {tag = "v0.0.0-dev.150", channel = "dev"} or nil
			with_declared_packaged_check(nil, offer, function(recorded)
				helpers.assert_nil(recorded.row)
				helpers.assert_eq(#recorded.opens, 0)
				helpers.assert_eq(#recorded.requests, 0)
			end)
		end)
	end
	helpers.it("rechecks the shared declaration before delivering a retained no-offer callback", function()
		with_declared_packaged_check(false, nil, function(recorded, _, root)
			root.about_source_menu = {}
			helpers.assert_eq(recorded.row.fn(), false)
			helpers.assert_eq(#recorded.opens, 0)
			helpers.assert_eq(#recorded.requests, 0)
		end)
	end)
	helpers.it("preserves native missing-owner refusal for a valid offered release", function()
		with_declared_packaged_check(false, {tag = "v0.0.0-dev.150", channel = "dev"}, function(recorded)
			recorded.owner.get = nil
			helpers.assert_eq(recorded.row.fn(), false)
			helpers.assert_eq(#recorded.opens, 0)
			helpers.assert_eq(#recorded.requests, 0)
		end)
	end)
end)

helpers.describe("Offered About commands retain live shared admission", function()
	helpers.it("refuses a retained offered callback after declaration withdrawal", function()
		with_declared_packaged_check(false, {tag = "v0.0.0-dev.150", channel = "dev"}, function(recorded, _, root)
			root.about_source_menu = {}
			helpers.assert_eq(recorded.row.fn(), false)
			helpers.assert_eq(#recorded.opens, 0)
			helpers.assert_eq(#recorded.requests, 0)
		end)
	end)
	helpers.it("refuses a retained offered callback after its required readiness is withdrawn", function()
		with_declared_packaged_check(false, {tag = "v0.0.0-dev.150", channel = "dev"}, function(recorded, _, root)
			local row = root.about_source_menu[1]
			local previous = row.disabled_when
			row.disabled_when = {"independent_missing_offered_owner"}
			local ok, detail = xpcall(function()
				helpers.assert_eq(recorded.row.fn(), false)
				helpers.assert_eq(#recorded.opens, 0)
				helpers.assert_eq(#recorded.requests, 0)
			end, debug.traceback)
			row.disabled_when = previous
			if not ok then error(detail, 0) end
		end)
	end)
end)
