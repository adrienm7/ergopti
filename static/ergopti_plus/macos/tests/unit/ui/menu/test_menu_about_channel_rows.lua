--- tests/unit/ui/menu/test_menu_about_channel_rows.lua

--- ==============================================================================
--- MODULE: The About Submenu Offers The Update Channels In One Picker (macOS)
--- DESCRIPTION:
--- macOS showed no channel at all: the feed was fixed when the app was built.
--- The channels then became one flat row each under the version, which read as
--- a list of unrelated commands. They now sit in ONE submenu right before the
--- check row, titled with the subscribed channel's registry name (« Canal de
--- mise à jour : Dev »), listing every registry channel in registry order with
--- the subscribed one ticked; a click subscribes through the menu session's
--- channel owner. Built through the real builder and renderer, with the real
--- French templates, so a row the renderer drops or a title that loses its
--- channel fails here.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- The real French catalogue, so titles are checked against the shipped template.
local function french()
	local handle = assert(io.open(helpers.shared("data/locales/fr.json"), "rb"))
	local decoded = Json.decode(handle:read("*a"))
	handle:close()
	return decoded
end

--- A channel-owner double: it persists like the real owner, so the next build
--- reads the channel a click chose.
local function fake_owner(subscribed)
	local calls = {}
	return {
		get = function() return subscribed end,
		set = function(id)
			calls[#calls + 1] = id
			subscribed = id
			return true
		end,
		subscribe = function() end,
	}, calls
end

--- Builds the About submenu through the real module and renderer, translating
--- with the shipped French catalogue.
local function build(owner)
	package.loaded["ui.menu.menu_about"] = nil
	local About = helpers.load_with_stubs("ui.menu.menu_about")
	local catalogue = french()
	require("infra.i18n").get = function(key) return catalogue[key] or key end
	local item = About.build({ channel_owner = owner }, {
		start_at_login = function() error("Building About must not change startup.") end,
		uninstall = function() error("Building About must not uninstall the application.") end,
	})
	return item.submenu, catalogue
end

--- The expected title of the picker for a subscribed channel.
local function expected_title(catalogue, id)
	local Updater = require("modules.updater")
	local name = catalogue[Updater.channels().channel(id).label_key]
	return (catalogue["menu.about.channel_menu"]:gsub("{channel}", name))
end

--- The picker row: the only row whose submenu lists the channel labels.
local function picker(rows, catalogue)
	local Updater = require("modules.updater")
	local first = catalogue[Updater.channels().channel(Updater.channels().ids()[1]).menu_label_key]
	local found = {}
	for index, row in ipairs(rows) do
		if type(row.menu) == "table" and row.menu[1] and row.menu[1].title == first then
			found[#found + 1] = index
		end
	end
	helpers.assert_eq(#found, 1, "exactly one submenu must hold the channel rows")
	return rows[found[1]], found[1]
end

helpers.describe("menu_about: one titled submenu for the update channels", function()
	helpers.it("titles the picker with the subscribed channel and ticks it alone", function()
		local ids = require("modules.updater").channels().ids()
		helpers.assert_true(#ids >= 2, "the registry must declare the channels")
		for _, subscribed in ipairs(ids) do
			local rows, catalogue = build((fake_owner(subscribed)))
			local row, at = picker(rows, catalogue)
			helpers.assert_eq(row.title, expected_title(catalogue, subscribed),
				"the title names the subscribed channel " .. subscribed)
			helpers.assert_true(catalogue["menu.about.channel_menu"]:find("{channel}", 1, true) ~= nil,
				"the French template carries its placeholder")
			helpers.assert_eq(rows[at - 1].title, "-", "the picker follows the version block's separator")
			helpers.assert_eq(#row.menu, #ids, "one row per registry channel")
			local ticked = 0
			for index, id in ipairs(ids) do
				local channel = require("modules.updater").channels().channel(id)
				helpers.assert_eq(row.menu[index].title, catalogue[channel.menu_label_key],
					"channel row " .. index .. " reads its registry label, in registry order")
				if row.menu[index].checked == true then
					ticked = ticked + 1
					helpers.assert_eq(id, subscribed, "only the subscribed channel is ticked")
				end
			end
			helpers.assert_eq(ticked, 1, "exactly one channel is ticked")
		end
	end)

	helpers.it("a channel row subscribes through the owner and the title follows", function()
		local ids = require("modules.updater").channels().ids()
		local owner, calls = fake_owner(ids[1])
		local rows, catalogue = build(owner)
		local row = picker(rows, catalogue)
		row.menu[#ids].fn()
		helpers.assert_eq(calls, { ids[#ids] }, "the last row subscribes to the last channel")
		local rebuilt = build(owner)
		helpers.assert_eq(picker(rebuilt, catalogue).title, expected_title(catalogue, ids[#ids]),
			"the rebuilt title names the channel just chosen")
		for index = 1, #ids do picker(rebuilt, catalogue).menu[index].fn() end
		helpers.assert_eq(#calls, 1 + #ids, "every row subscribes")
		for index, id in ipairs(ids) do
			helpers.assert_eq(calls[1 + index], id, "row " .. index .. " subscribes to its own channel")
		end
	end)

	helpers.it("no channel is a flat row of the About submenu any more", function()
		local rows, catalogue = build((fake_owner("dev")))
		local Updater = require("modules.updater")
		for _, row in ipairs(rows) do
			for _, id in ipairs(Updater.channels().ids()) do
				helpers.assert_true(row.title ~= catalogue[Updater.channels().channel(id).menu_label_key],
					"the channel " .. id .. " must be listed inside the picker only")
			end
		end
	end)

	-- The Versions window's banner used to have no owner to subscribe through.
	helpers.it("the Versions row opens on the subscribed channel with the owner", function()
		local owner = fake_owner("dev")
		local previous = package.loaded["ui.changelog"]
		local opened = {}
		package.loaded["ui.changelog"] = { open = function(opts) opened[#opened + 1] = opts return true end }
		local ok, err = pcall(function()
			local rows, catalogue = build(owner)
			local label = catalogue["menu.about.changelog"]
			local versions = nil
			for _, row in ipairs(rows) do
				if row.title == label then versions = row end
			end
			helpers.assert_not_nil(versions, "the About submenu must list the Versions row")
			versions.fn()
			helpers.assert_eq(#opened, 1, "the Versions window must open once")
			helpers.assert_eq(opened[1].channel, "dev", "it opens on the subscribed channel")
			helpers.assert_true(opened[1].channel_owner == owner, "its banner subscribes through the same owner")
		end)
		package.loaded["ui.changelog"] = previous
		package.loaded["ui.menu.menu_about"] = nil
		if not ok then error(err, 0) end
	end)

	helpers.it("without an owner the picker is left out rather than drawn dead", function()
		local rows, catalogue = build(nil)
		local Updater = require("modules.updater")
		local first = catalogue[Updater.channels().channel(Updater.channels().ids()[1]).menu_label_key]
		local prefix = catalogue["menu.about.channel_menu"]:match("^(.-){channel}")
		for _, row in ipairs(rows) do
			helpers.assert_true(row.title:find(prefix, 1, true) ~= 1,
				"a channel picker with nobody to persist it must not be offered")
			helpers.assert_true(not (type(row.menu) == "table" and row.menu[1] and row.menu[1].title == first),
				"no submenu may list the channels")
		end
	end)
end)


--- Reads the pre-migration two-channel presentation without consulting the registry.
--- @return table corpus
local function channel_corpus()
	local handle = assert(io.open(helpers.shared("tests/corpus/menus/update_channel_rows.json"), "rb"))
	local raw = handle:read("*a")
	handle:close()
	return assert(require("adapters.json_codec").decode(raw))
end

helpers.describe("macOS published About channel choices", function()
	helpers.it("follows a reordered shared declaration through the actual About provider", function()
		local renderer = require("infra.manifest_menu")
		local root = renderer.get_root()
		local previous = root.about_update_channel_menu
		local i18n = require("infra.i18n")
		local previous_get = i18n.get
		local expected, choices = channel_corpus(), {}
		for _, value in ipairs(expected.reordered_values) do
			for _, choice in ipairs(expected.choices) do
				if choice.value == value then choices[#choices + 1] = choice end
			end
		end
		root.about_update_channel_menu = { {
			type = "choice", id = "update_channel", path = "updater.channel",
			i18n = "menu.about.channel_menu", show_current_choice = true,
			current_choice_placeholder = "{channel}", choices = choices,
		} }
		local ok, detail = pcall(function()
			local owner, requests = fake_owner("main")
			local rows, catalogue = build(owner)
			local prefix = catalogue["menu.about.channel_menu"]:match("^(.-){channel}")
			local row
			for _, entry in ipairs(rows) do
				if entry.title:find(prefix, 1, true) == 1 then row = entry end
			end
			helpers.assert_not_nil(row, "the actual About provider must draw its declared channel choice")
			helpers.assert_eq(#row.menu, 2, "the captured two choices remain complete")
			for index, choice in ipairs(choices) do
				helpers.assert_eq(row.menu[index].title, catalogue[choice.i18n],
					"the real provider must consume the published order")
				row.menu[index].fn()
			end
			helpers.assert_eq(requests, expected.reordered_values)
		end)
		root.about_update_channel_menu, i18n.get = previous, previous_get
		if not ok then error(detail, 0) end
	end)
end)


helpers.describe("macOS captured About channel states", function()
	helpers.it("retains both original short captions, full leaves and exclusive ticks", function()
		local corpus = channel_corpus()
		for index, state in ipairs(corpus.states) do
			local rows, catalogue = build((fake_owner(state.selected)))
			local row = picker(rows, catalogue)
			helpers.assert_eq(row.title, corpus.locales.fr.captions[index])
			helpers.assert_eq(#row.menu, 2)
			for at, leaf in ipairs(row.menu) do
				helpers.assert_eq(leaf.title, corpus.locales.fr.leaf_labels[at])
				helpers.assert_eq(leaf.checked, state.checked[at])
			end
		end
	end)

	helpers.it("retains the preference owner's refusal and exception behavior", function()
		for _, refusal in ipairs(channel_corpus().refusals) do
			local owner, requests = fake_owner("main")
			owner.set = function(id)
				requests[#requests + 1] = id
				if refusal == "throw" then error("refused channel write") end
				if refusal == "false" then return false end
				return nil
			end
			local rows, catalogue = build(owner)
			local row = picker(rows, catalogue)
			local ok, result = pcall(row.menu[2].fn)
			helpers.assert_eq(ok, true, "the channel callback protects native owner exceptions")
			helpers.assert_eq(result, false, "a refused native owner never acknowledges the callback")
			helpers.assert_eq(requests, { "dev" })
			helpers.assert_eq(owner.get(), "main", "refusal must not publish a guessed preference")
			local rebuilt, translated = build(owner)
			helpers.assert_eq(picker(rebuilt, translated).title, channel_corpus().locales.fr.captions[1])
		end
	end)
end)


helpers.describe("macOS About channel durable receipts", function()
	for _, outcome in ipairs({"false", "nil", "number", "throw"}) do
		helpers.it("protects exact owner refusal and preserves the current channel (channel-ack " .. outcome .. ")", function()
			local owner, calls = fake_owner("main")
			owner.set = function(id)
				calls[#calls + 1] = id
				if outcome == "throw" then error("The channel owner refused.") end
				if outcome == "number" then return 2 end
				if outcome == "false" then return false end
				return nil
			end
			local rows, catalogue = build(owner)
			local ok, accepted = pcall(picker(rows, catalogue).menu[2].fn)
			helpers.assert_eq(ok, true)
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(calls, {"dev"})
			helpers.assert_eq(owner.get(), "main")
		end)
	end

	for _, outcome in ipairs({"false", "nil", "number", "throw"}) do
		helpers.it("retries the actual durable owner only after a refused write (channel-ack durable " .. outcome .. ")", function()
			local names = {"modules.updater.channel", "adapters.update_launcher"}
			local previous = {}
			for _, name in ipairs(names) do previous[name] = package.loaded[name] end
			local writer = require("toml_codec.writer")
			local real_write = writer.batch_write
			local path = os.tmpname()
			local original = "[updater]\nchannel = \"main\"\nfuture_channel_option = 42\n"
			local file = assert(io.open(path, "wb")); assert(file:write(original)); assert(file:close())
			local writes, publications, launcher_calls = 0, 0, 0
			local refusing = true
			local state = {update_channel = "main"}
			local ok, detail = xpcall(function()
				package.loaded["adapters.update_launcher"] = {select_channel = function()
					launcher_calls = launcher_calls + 1; return true
				end}
				package.loaded["modules.updater.channel"] = nil
				local owner = require("modules.updater.channel").new({state = state, save = function()
					writes = writes + 1
					if refusing then
						if outcome == "throw" then error("The durable writer refused.") end
						if outcome == "number" then return 2 end
						if outcome == "false" then return false end
						return nil
					end
					return real_write(path, {{section = "updater", key = "channel", value = state.update_channel}})
				end})
				owner.subscribe("receipt-test", function() publications = publications + 1 end)
				local rows, catalogue = build(owner)
				local held = picker(rows, catalogue).menu[2].fn
				local accepted = held()
				local before = assert(io.open(path, "rb")); local bytes = before:read("*a"); assert(before:close())
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(bytes, original)
				helpers.assert_eq(state.update_channel, "main")
				helpers.assert_eq(owner.get(), "main")
				helpers.assert_eq(publications, 0)
				helpers.assert_eq(launcher_calls, 0)
				helpers.assert_eq(writes, 1)
				refusing = false
				helpers.assert_eq(held(), true)
				local after = assert(io.open(path, "rb")); local committed = after:read("*a"); assert(after:close())
				helpers.assert_true(committed:find('channel = "dev"', 1, true) ~= nil)
				helpers.assert_true(committed:find("future_channel_option = 42", 1, true) ~= nil)
				helpers.assert_eq(owner.get(), "dev")
				helpers.assert_eq(publications, 1)
				helpers.assert_eq(writes, 2)
				helpers.assert_eq(held(), true)
				helpers.assert_eq(writes, 2, "the native owner acknowledges the already durable absolute selection")
			end, debug.traceback)
			for _, name in ipairs(names) do package.loaded[name] = previous[name] end
			os.remove(path)
			if not ok then error(detail, 0) end
		end)
	end
end)


helpers.describe("macOS About channel post-publication refusal", function()
	helpers.it("does not manufacture a rollback when a packaged observer raises after the durable ACK (channel-ack post-publication)", function()
		local names = {"modules.updater.channel", "adapters.update_launcher"}
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name] end
		local updater = require("modules.updater")
		local previous_source = updater.is_local_source
		local writer = require("toml_codec.writer")
		local path = os.tmpname()
		local file = assert(io.open(path, "wb"))
		assert(file:write('[updater]\nchannel = "main"\nfuture_channel_option = 42\n')); assert(file:close())
		local state = {update_channel = "main"}
		local writes, deliveries, heard = 0, 0, 0
		local ok, detail = xpcall(function()
			updater.is_local_source = function() return false end
			package.loaded["adapters.update_launcher"] = {select_channel = function()
				deliveries = deliveries + 1
				error("The packaged observer raised after publication.")
			end}
			package.loaded["modules.updater.channel"] = nil
			local owner = require("modules.updater.channel").new({state = state, save = function()
				writes = writes + 1
				return writer.batch_write(path, {{section = "updater", key = "channel", value = state.update_channel}})
			end})
			owner.subscribe("receipt-test", function() heard = heard + 1 end)
			local rows, catalogue = build(owner)
			local protected, accepted = pcall(picker(rows, catalogue).menu[2].fn)
			local saved = assert(io.open(path, "rb")); local bytes = saved:read("*a"); assert(saved:close())
			helpers.assert_eq(protected, true)
			helpers.assert_eq(accepted, false, "an incomplete native return is not an acknowledged callback")
			helpers.assert_eq(writes, 1)
			helpers.assert_eq(deliveries, 1)
			helpers.assert_eq(heard, 0)
			helpers.assert_eq(owner.get(), "dev", "the callback does not borrow inverse publication authority")
			helpers.assert_true(bytes:find('channel = "dev"', 1, true) ~= nil)
			helpers.assert_true(bytes:find("future_channel_option = 42", 1, true) ~= nil)
		end, debug.traceback)
		updater.is_local_source = previous_source
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		os.remove(path)
		if not ok then error(detail, 0) end
	end)
end)
