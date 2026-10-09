--- macos/tests/unit/modules/updater/test_update_channels_vectors.lua

--- ==============================================================================
--- MODULE: Update Channel Registry Vectors (macOS)
--- DESCRIPTION:
--- Replays _shared/modules/updater/channel_vectors.json through the shared Lua
--- port (updater.channels) loaded with the real channels.json, decoded with the
--- shared decoder (hs.json maps a JSON null to an absent field the same way).
--- The JavaScript matcher and the AHK port replay the same file, so the three
--- interpreters of the registry cannot disagree on which channel owns a tag or
--- which candidate a check offers.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local SHARED = helpers.shared("modules/updater/")

local function read_json(name)
	local handle = assert(io.open(SHARED .. name, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return assert(Json.decode(raw), name .. " must decode")
end

--- The vectors spell "no channel" as an empty string: the shared decoder turns
--- a JSON null into a non-nil sentinel, so the shared data never uses null.
local function none(value)
	if value == "" then return nil end
	return value
end

local function load_registry()
	package.loaded["updater.channels"] = nil
	local Channels = require("updater.channels")
	return Channels, Channels.load(read_json("channels.json"))
end

helpers.describe("updater.channels — shared vectors (macOS)", function()
	local vectors = read_json("channel_vectors.json")
	local Channels, registry, load_err = load_registry()

	helpers.it("loads the real registry in stability order", function()
		helpers.assert_true(registry ~= nil, "registry must load: " .. tostring(load_err))
		helpers.assert_eq(registry.ids(), { "main", "dev" })
		helpers.assert_eq(registry.unreleased_build_channel, "dev")
		helpers.assert_eq(registry.channel("main").label_key, "updater.channel.main")
	end)

	helpers.it("maps every vector tag to its channel", function()
		helpers.assert_true(#vectors.tag >= 20, "the tag vectors must be present")
		for _, v in ipairs(vectors.tag) do
			helpers.assert_eq(registry.channel_for_tag(v.tag), none(v.channel), "tag vector " .. v.id)
			for _, id in ipairs(registry.ids()) do
				helpers.assert_eq(registry.matches(id, v.tag), id == none(v.channel),
					"matches(" .. id .. ") for tag vector " .. v.id)
			end
		end
	end)

	helpers.it("resolves persisted values and aliases exactly", function()
		helpers.assert_true(#vectors.resolve >= 5, "the resolve vectors must be present")
		for _, v in ipairs(vectors.resolve) do
			helpers.assert_eq(registry.resolve(v.value), none(v.expect), "resolve vector " .. v.id)
		end
	end)

	helpers.it("lists each view's releases and the more stable channels' ones", function()
		helpers.assert_true(#vectors.visible >= 5, "the visible vectors must be present")
		for _, v in ipairs(vectors.visible) do
			helpers.assert_eq(registry.visible_in(v.view, v.tag), v.expect, "visible vector " .. v.id)
		end
	end)

	helpers.it("offers candidates exactly like the other drivers", function()
		helpers.assert_true(#vectors.offer >= 8, "the offer vectors must be present")
		for _, v in ipairs(vectors.offer) do
			helpers.assert_eq(registry.should_offer(v.latest, v.current, v.selected, v.installed),
				v.expect, "offer vector " .. v.id)
		end
	end)

	helpers.it("picks a channel's latest release by semver order", function()
		helpers.assert_true(#vectors.pick >= 5, "the pick vectors must be present")
		for _, v in ipairs(vectors.pick) do
			local index = registry.pick_latest(v.tags, v.channel)
			helpers.assert_eq(index and v.tags[index] or nil, none(v.expect), "pick vector " .. v.id)
		end
	end)

	helpers.it("lists the other channels published after the installed build", function()
		helpers.assert_true(#vectors.newer_elsewhere >= 10, "the newer_elsewhere vectors must be present")
		for _, v in ipairs(vectors.newer_elsewhere) do
			helpers.assert_eq(registry.newer_elsewhere(v.releases, v.selected, v.installed), v.expect,
				"newer_elsewhere vector " .. v.id)
		end
	end)

	helpers.it("refuses a registry where two channels claim the same tags", function()
		local decoded = read_json("channels.json")
		decoded.channels[2].tag = decoded.channels[1].tag
		local refused, err = Channels.load(decoded)
		helpers.assert_nil(refused)
		helpers.assert_contains(err, "claim the same tags")
	end)

	helpers.it("refuses an alias that shadows a channel id", function()
		local decoded = read_json("channels.json")
		decoded.channels[2].aliases = { "main" }
		local refused, err = Channels.load(decoded)
		helpers.assert_nil(refused)
		helpers.assert_contains(err, "declared twice")
	end)
end)
