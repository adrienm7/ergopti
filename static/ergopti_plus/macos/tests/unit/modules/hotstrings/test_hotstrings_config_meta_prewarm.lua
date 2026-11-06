--- tests/unit/modules/hotstrings/test_hotstrings_config_meta_prewarm.lua

--- ==============================================================================
--- MODULE: Hotstrings Config — Category Metadata Prewarm
--- DESCRIPTION:
--- The 2026-11-06 field report measured preview.rebuild over its 5 ms budget
--- seven times (9.29 ms at most), parent keydown. Four of them were the first
--- preview of a category in the session: hotstrings_config read that
--- category's TOML metadata on the keystroke (a snapshot stat, a loadfile and
--- a full read of the source bytes) because get_toml_meta filled its memo on
--- first use. prewarm_meta fills the same memo on run-loop turns after the
--- boot, one category per turn, so the preview only reads memory; the boot
--- asks for it once the hotstring groups are registered
--- (hotstrings-meta-prewarm).
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body against a fresh module over a counting TOML reader and recorded
--- deferred work.
--- @param body function body(cfg, world)
local function with_config(body)
	helpers.with_stub_scope({
		"infra.logger", "infra.toml.reader", "infra.deferred_work", "adapters.file_system",
		"modules.hotstrings.hotstrings_config",
	}, function()
		helpers.load_with_stubs("infra.logger")
		local world = { parses = {}, scheduled = {} }
		package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
		-- The module reads its shared defaults through the real reader at load
		-- time; only the category files under /bundle/ are counted and faked
		package.loaded["infra.toml.reader"] = nil
		local real = require("infra.toml.reader")
		local counting = setmetatable({}, { __index = real })
		counting.parse = function(path, ...)
			if type(path) ~= "string" or path:sub(1, #"/bundle/") ~= "/bundle/" then return real.parse(path, ...) end
			world.parses[#world.parses + 1] = path
			return { sections = {}, meta = { delay = 0.3, color = "#336699", sections = {} } }, true
		end
		package.loaded["infra.toml.reader"] = counting
		package.loaded["infra.deferred_work"] = {
			after = function(delay, callback, label)
				world.scheduled[#world.scheduled + 1] = { delay = delay, callback = callback, label = label }
				return true
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local cfg = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")
		cfg.init({
			override_path = os.tmpname() .. "_absent_hotstrings_overrides.toml",
			toml_resolver = function(category) return "/bundle/" .. category .. ".toml" end,
		})
		body(cfg, world)
	end)
end

--- Fires the recorded deferred work in order until none is left.
--- @param world table
--- @return integer turns
local function drain(world)
	local turns = 0
	while #world.scheduled > 0 do
		local entry = table.remove(world.scheduled, 1)
		turns = turns + 1
		if turns > 100 then error("the prewarm never settled") end
		entry.callback()
	end
	return turns
end

helpers.describe("hotstrings_config: category metadata prewarm (hotstrings-meta-prewarm)", function()
	helpers.it("the first preview of a prewarmed category reads no file (hotstrings-meta-prewarm)", function()
		with_config(function(cfg, world)
			helpers.assert_eq(cfg.prewarm_meta({ "rolls", "sfbsreduction" }), true)
			helpers.assert_eq(world.parses, {}, "the prewarm parsed inside its caller's turn")
			helpers.assert_eq(drain(world), 3, "one category per run-loop turn, then the closing turn")
			helpers.assert_eq(world.parses, { "/bundle/rolls.toml", "/bundle/sfbsreduction.toml" })
			local resolved = cfg.resolve("rolls")
			cfg.resolve("sfbsreduction", "some_section")
			helpers.assert_eq(#world.parses, 2, "a preview after the prewarm read a category TOML")
			helpers.assert_eq(resolved.color, "#336699", "the prewarmed metadata is what resolve answers")
		end)
	end)

	helpers.it("a category a preview already read is not read again (hotstrings-meta-prewarm)", function()
		with_config(function(cfg, world)
			cfg.resolve("rolls")
			helpers.assert_eq(cfg.prewarm_meta({ "rolls" }), true)
			drain(world)
			helpers.assert_eq(world.parses, { "/bundle/rolls.toml" })
		end)
	end)

	helpers.it("a refused timer is reported, never a silent success (hotstrings-meta-prewarm)", function()
		with_config(function(cfg)
			package.loaded["infra.deferred_work"].after = function() return false end
			helpers.assert_eq(cfg.prewarm_meta({ "rolls" }), false)
		end)
	end)

	helpers.it("the boot prewarms once the hotstring groups are registered (hotstrings-meta-prewarm)", function()
		local source = helpers.read_driver_unit('Boot.mark("Hotstring groups registered')
		local registered = source:find('Boot.mark("Hotstring groups registered (personal + dynamic + common)")', 1, true)
		local prewarm = source:find("prewarm_meta(", 1, true)
		helpers.assert_true(registered ~= nil, "the boot stage marker moved")
		helpers.assert_true(prewarm ~= nil and prewarm > registered,
			"init.lua must prewarm the category metadata after the groups are registered")
	end)
end)
