--- _shared/lua/test/tap_hold_shared_file_contract.lua

--- ==============================================================================
--- MODULE: Shared Tap-Hold File Contract
--- DESCRIPTION:
--- The layout every driver's tap_hold.toml keeps (_shared/tap_hold/SCHEMA.md),
--- registered once per driver suite: the spec data parses, a hold modifier has
--- one spelling, and each file of the cross-driver corpus
--- (_shared/tests/corpus/tap_hold_shared_file) is stamped with the current
--- version, names its keys by catalogue id and its combinations by pair id,
--- and holds only the fields the specification lists. A driver whose writer
--- drifted from the layout fails here before the other driver reads it.
---
--- USAGE (one call per driver suite):
---   require("test.tap_hold_shared_file_contract").register(helpers,
---     { driver = "linux", shared_root = "<_shared>" })
--- ==============================================================================

local M = {}

local SharedFile = require("tap_hold.shared_file")
local Migrate = require("tap_hold.migrate")
local TomlCodec = require("toml_codec")

-- The files of the corpus each driver's writer produced.
M.FILES = { "linux_written", "macos_written" }

-- The fields SCHEMA.md lists, per table.
local FIELDS = {
	tap_hold = { enabled = true, inherit_defaults = true, time_activation_seconds = true, sticky_timeout_ms = true,
		lone_modifier_tap_max_ms = true, keys = true },
	key = { tap_action = true, hold_modifier = true, hold_layer = true, hold_action = true,
		time_activation_seconds = true, enabled = true },
	mod_combos = { enabled = true, simultaneous_threshold_ms = true, symmetric = true, config = true },
	pair = { combo = true, tap = true, hold = true },
	karabiner = { integration_enabled = true, runtime = true, close_other_instances = true },
}

--- Reads a file whole, failing loudly when it is missing.
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then error("tap-hold shared file corpus file is missing: " .. path) end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- The fields of a table that the specification does not list.
local function unknown(tbl, known)
	local out = {}
	for field in pairs(tbl) do if not known[field] then out[#out + 1] = tostring(field) end end
	table.sort(out)
	return out
end

--- Registers the contract in a driver suite.
--- @param helpers table The driver's test helpers.
--- @param opts table `{ driver = string, shared_root = string }`.
function M.register(helpers, opts)
	local root = opts.shared_root
	local spec = SharedFile.parse_spec(TomlCodec.decode(read(root .. "/tap_hold/shared_file.toml")))
	local registry = Migrate.load_registry(root .. "/tap_hold/migrations.toml")
	local defaults = TomlCodec.decode(read(root .. "/tap_hold/defaults.toml"))
	local catalogue = {}
	for _, entry in ipairs(defaults.tap_hold.catalog.keys) do catalogue[entry.id] = true end

	helpers.describe("tap-hold shared file contract: " .. opts.driver .. " (tap-hold-shared-file-contract)", function()
		helpers.it("a hold modifier has one spelling, in the spec order", function()
			helpers.assert_eq(SharedFile.canonical_modifier(spec, "Ctrl + Shift"), "ctrl+shift")
			helpers.assert_eq(SharedFile.canonical_modifier(spec, "cmd+shift"), "shift+cmd")
			helpers.assert_eq(SharedFile.canonical_modifier(spec, "lctrl", { lctrl = "ctrl" }), "ctrl")
			helpers.assert_eq(SharedFile.canonical_modifier(spec, "hyper"), nil)
			helpers.assert_eq(SharedFile.canonical_modifier(spec, ""), nil)
		end)

		helpers.it("the only legacy import is macOS config_karabiner.toml", function()
			helpers.assert_eq(registry.legacy_imports, {
				hs = { source = "config_karabiner.toml", translate = "karabiner", retired_suffix = ".migrated" },
			})
		end)

		for _, name in ipairs(M.FILES) do
			helpers.it("corpus file " .. name .. ".toml keeps the shared layout", function()
				local document = TomlCodec.decode(read(root .. "/tests/corpus/tap_hold_shared_file/" .. name .. ".toml"))
				helpers.assert_eq(document[SharedFile.META][Migrate.VERSION_KEY], registry.current, "stamped current")
				helpers.assert_eq(unknown(document, { _meta = true, tap_hold = true, mod_combos = true, karabiner = true }), {})
				local section = document.tap_hold or {}
				helpers.assert_eq(unknown(section, FIELDS.tap_hold), {})
				for key_id, entry in pairs(section.keys or {}) do
					helpers.assert_true(catalogue[key_id], "'" .. key_id .. "' is a catalogue id")
					helpers.assert_eq(unknown(entry, FIELDS.key), {}, key_id)
				end
				local combos = document.mod_combos or {}
				helpers.assert_eq(unknown(combos, FIELDS.mod_combos), {})
				for pair, entry in pairs(combos.config or {}) do
					local first, second = pair:match("^(.-)_then_(.+)$")
					helpers.assert_true(catalogue[first] and catalogue[second], "'" .. pair .. "' is a pair of catalogue ids")
					helpers.assert_eq(unknown(entry, FIELDS.pair), {}, pair)
				end
				helpers.assert_eq(unknown(document.karabiner or {}, FIELDS.karabiner), {})
			end)
		end
	end)
end

return M
