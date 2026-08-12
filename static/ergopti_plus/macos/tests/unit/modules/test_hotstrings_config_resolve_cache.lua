--- tests/unit/modules/test_hotstrings_config_resolve_cache.lua

--- ==============================================================================
--- MODULE: Hotstrings Config — resolve() Memo
--- DESCRIPTION:
--- `hotstrings_config.resolve(category, section)` walks a four-level cascade
--- (user section > user category > TOML section > TOML file > global default)
--- to produce the delay, colour and tooltip policy for a hotstring group.
---
--- WHY IT IS MEMOISED:
--- the tooltip preview resolves it once per CANDIDATE, on every keystroke, while
--- a tooltip is eligible — so the cascade was being re-walked several times per
--- key on the HID thread. The AutoHotkey sibling reached that conclusion first
--- and added `_HSResolveCache` / `_HSResolveGen`
--- (infra/hotstrings/hotstrings_config.ahk); macOS had no equivalent, so the two
--- drivers paid different costs for the same cascade.
---
--- WHY THE INVALIDATION IS THE INTERESTING HALF:
--- a memo that never clears is not a speed-up, it is a stale answer. The three
--- writers that can change what the cascade returns — set_override,
--- clear_override and reload — each drop the whole table, not one key: an
--- override on a CATEGORY changes the answer for every section under it, so
--- evicting only the exact key would leave the sections wrong.
---
--- HOW THE MEMO IS OBSERVED, and what does NOT work:
--- counting calls to the injected TOML resolver looks like the obvious probe and
--- is useless here — `get_toml_meta` is ALREADY memoised behind `_state.toml_cache`,
--- so the resolver is consulted once per category whether or not resolve() caches
--- anything. What this memo actually removes is the cascade walk and the table
--- allocated per call, so the observable is table IDENTITY: a cache hit returns
--- the very same table, a recomputation returns a fresh one. That also states the
--- honest size of the win — the TOML read was already cached; the allocation per
--- preview candidate was not.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==========================================
-- ==========================================
-- ======= 1/ Harness =======================
-- ==========================================
-- ==========================================

--- Builds a config module initialised against a stub TOML resolver.
--- @return table module
local function fresh_config()
	package.loaded["adapters.file_system"] = require("tests.support.file_system_write_stub")
	local cfg = helpers.load_with_stubs("modules.hotstrings.hotstrings_config")

	-- An override path that does not exist: parse_overrides yields empty
	-- overrides, which is the state a fresh install is in and the one the preview
	-- path runs against most of the time.
	cfg.init({
		override_path = os.tmpname() .. "_absent_hotstrings_overrides.toml",
		toml_resolver = function(_category)
			return { delay = 0.4, color = "#123456", sections = {} }
		end,
	})
	return cfg
end




-- ==========================================
-- ==========================================
-- ======= 2/ The memo ======================
-- ==========================================
-- ==========================================

helpers.describe("hotstrings_config.resolve: memoised per (category, section)", function()

	helpers.it("returns the very same table for repeated identical calls", function()
		local cfg = fresh_config()

		local first = cfg.resolve("rolls")
		helpers.assert_true(type(first) == "table" and type(first.delay) == "number",
			"the first resolve must produce a real result — otherwise every assertion "
				.. "below is vacuous")

		for _ = 1, 20 do cfg.resolve("rolls") end
		local again = cfg.resolve("rolls")
		helpers.assert_true(rawequal(first, again),
			"21 resolves of the same (category, section) must yield ONE table; the preview "
				.. "calls this once per candidate on every keystroke, so a fresh table per "
				.. "call is an allocation on the HID thread")
	end)

	helpers.it("keys the memo on the section as well as the category", function()
		local cfg = fresh_config()
		local cat = cfg.resolve("rolls")
		local sec = cfg.resolve("rolls", "some_section")
		helpers.assert_true(not rawequal(cat, sec),
			"resolving a SECTION of an already-resolved category must not be served the "
				.. "category's answer — the cascade has a section level and the key must too")
	end)

end)





-- ==========================================
-- ==========================================
-- ======= 3/ The invalidation ==============
-- ==========================================
-- ==========================================

helpers.describe("hotstrings_config.resolve: every writer drops the memo", function()

	--- Resolves once to warm the memo, runs `mutate`, and reports whether the
	--- next resolve went back to the TOML.
	--- @param mutate function Called with the module.
	--- @return boolean True when the memo was dropped.
	local function memo_dropped_by(mutate)
		local cfg = fresh_config()
		local warm = cfg.resolve("rolls")
		mutate(cfg)
		return not rawequal(warm, cfg.resolve("rolls"))
	end

	helpers.it("set_override drops it", function()
		helpers.assert_true(memo_dropped_by(function(cfg) cfg.set_override("rolls", nil, "delay", 0.9) end),
			"a stale memo after set_override means the user changes a delay from the menu "
				.. "and the tooltip keeps using the old one until the next reload")
	end)

	helpers.it("clear_override drops it", function()
		helpers.assert_true(memo_dropped_by(function(cfg)
			cfg.set_override("rolls", nil, "delay", 0.9)
			cfg.resolve("rolls")
			cfg.clear_override("rolls", nil, "delay")
		end), "clearing an override must return the cascade to the TOML value, not to the memo")
	end)

	helpers.it("reload drops it", function()
		helpers.assert_true(memo_dropped_by(function(cfg) cfg.reload() end),
			"reload is what runs after the override file changes on disk — a memo that "
				.. "survives it makes the file edit invisible")
	end)

	helpers.it("a category override also invalidates its sections", function()
		-- The whole table is dropped rather than one key, because an override on a
		-- CATEGORY changes the answer for every section beneath it. Evicting only
		-- the exact key would leave the sections resolving to the pre-override
		-- value with nothing to show for it.
		local cfg = fresh_config()
		local a = cfg.resolve("rolls", "sec_a")
		local b = cfg.resolve("rolls", "sec_b")
		cfg.set_override("rolls", nil, "delay", 0.9)
		helpers.assert_true(not rawequal(a, cfg.resolve("rolls", "sec_a"))
			and not rawequal(b, cfg.resolve("rolls", "sec_b")),
			"a category-level override must invalidate the sections under it too")
	end)

end)
