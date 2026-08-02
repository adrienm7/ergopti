--- tests/unit/platform/remap/test_defaults_shared_path_resolver.lua

--- ==============================================================================
--- MODULE: Karabiner Defaults — Shared-Path Resolution
--- DESCRIPTION:
--- karabiner/defaults.lua reads _shared/tap_hold/defaults.toml at MODULE LOAD
--- time, from the top level of its own body. It used to locate the file by a
--- hand-rolled four-level parent walk from its own source path, while its
--- sibling config.lua already asked infra.paths — the resolver that exists so
--- the shared root lives in one place and survives the symlinked and packaged
--- layouts.
---
--- WHY THIS IS NOT COSMETIC:
--- a wrong path here does not fail politely. TomlReader.parse() returns an EMPTY
--- result table for a file it cannot open, so the `type(parsed.sections) ==
--- "table"` guard passes and the failure surfaces later as require_section()
--- calling error() — during require, on a chain (defaults <- config <-
--- karabiner/init <- init.lua) that used to be un-pcall'd. A defaults.toml the
--- walk could not reach therefore cost the WHOLE boot, 23 lines before
--- hs.shutdownCallback is armed: Karabiner kept remapping with no teardown.
---
--- WHAT IS PINNED:
---   1. The resolver is consulted, and its answer is used when it gives one.
---   2. The walk-up survives as a fallback when the resolver has no answer —
---      removing it would trade one single point of failure for another.
---   3. init.lua still pcalls the require chain. That half of the fix is already
---      in place, and it is the half that turns a missing file from a dead
---      session into one disabled feature, so it is pinned here beside the
---      cause rather than left to be re-broken silently.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ================================================
-- ================================================
-- ======= 1/ The resolver is asked first =========
-- ================================================
-- ================================================

helpers.describe("karabiner/defaults: shared path resolution", function()

	helpers.it("uses infra.paths when it resolves", function()
		-- A resolver that answers with a marker path: if defaults.lua asks it and
		-- uses the answer, the marker is what gets parsed.
		local asked_for = nil
		package.loaded["infra.paths"] = {
			shared = function(rel)
				asked_for = rel
				return "/probe/_shared/" .. tostring(rel)
			end,
			shared_root = function() return "/probe/_shared" end,
		}
		local parsed_path = nil
		package.loaded["infra.toml.reader"] = {
			parse = function(p)
				parsed_path = p
				-- Minimal shape so module load completes: the sections defaults.lua
				-- requires must all be present, otherwise it error()s and this test
				-- would be measuring the raise rather than the path.
				return { sections = {
					hs_timeouts = { tap_hold_timeout_ms = 250, sticky_timeout_ms = 3000,
						simultaneous_threshold_ms = 100, combo_symmetric = false },
					hs_tap_hold = {},
					hs_combos   = {},
				} }
			end,
		}

		package.loaded["platform.remap.defaults"] = nil
		local ok, err = pcall(require, "platform.remap.defaults")

		package.loaded["infra.paths"] = nil
		package.loaded["infra.toml.reader"] = nil
		package.loaded["platform.remap.defaults"] = nil

		-- The load error is carried into the messages below rather than asserted on
		-- its own: `pcall` succeeding proves only that nothing threw, and this test
		-- is about WHICH path was used. A raise shows up as a nil path with the
		-- error text attached, which says more than "it crashed".
		local ctx = ok and "" or (" — load raised: " .. tostring(err))
		helpers.assert_eq("tap_hold/defaults.toml", asked_for,
			"defaults.lua must ask infra.paths for the shared-relative path, not walk up itself" .. ctx)
		helpers.assert_eq("/probe/_shared/tap_hold/defaults.toml", parsed_path,
			"the resolver's answer must be the path actually parsed — asking and then "
				.. "ignoring it is the same bug with an extra call" .. ctx)
	end)

	helpers.it("falls back to the parent walk when the resolver has no answer", function()
		-- shared_root() returns nil when it cannot find the tree. Losing the walk
		-- would trade one single point of failure for another.
		package.loaded["infra.paths"] = {
			shared      = function() return nil end,
			shared_root = function() return nil end,
		}
		local parsed_path = nil
		package.loaded["infra.toml.reader"] = {
			parse = function(p)
				parsed_path = p
				return { sections = {
					hs_timeouts = { tap_hold_timeout_ms = 250, sticky_timeout_ms = 3000,
						simultaneous_threshold_ms = 100, combo_symmetric = false },
					hs_tap_hold = {},
					hs_combos   = {},
				} }
			end,
		}

		package.loaded["platform.remap.defaults"] = nil
		local ok, err = pcall(require, "platform.remap.defaults")

		package.loaded["infra.paths"] = nil
		package.loaded["infra.toml.reader"] = nil
		package.loaded["platform.remap.defaults"] = nil

		local ctx = ok and "" or (" — load raised: " .. tostring(err))
		helpers.assert_true(parsed_path ~= nil and parsed_path:find("_shared/tap_hold/defaults.toml", 1, true) ~= nil,
			"the walk-up fallback must still produce a _shared/tap_hold path, got: "
				.. tostring(parsed_path) .. ctx)
	end)

end)





-- ==================================================
-- ==================================================
-- ======= 2/ The boot chain stays pcall'd ==========
-- ==================================================
-- ==================================================

helpers.describe("init.lua: the Karabiner require cannot abort boot", function()

	helpers.it("requires platform.remap through pcall", function()
		-- The other half of the same defect. defaults.lua raises at module load, so
		-- an un-pcall'd require here ends the session before hs.shutdownCallback is
		-- armed — and Karabiner keeps remapping the keyboard with no teardown,
		-- which is the worst possible failure for a keyboard driver.
		-- Selected by a declaration unique to init.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("local function has_common_hotstring_groups")
		helpers.assert_true(src ~= nil, "init.lua source must be locatable")

		helpers.assert_true(src:find('pcall%(require, "platform%.remap"%)') ~= nil,
			"init.lua must load platform.remap through pcall — a bare require lets a "
				.. "missing or truncated tap_hold/defaults.toml take the whole boot down")
		helpers.assert_true(src:find('local karabiner%s*=%s*require%("platform%.remap"%)') == nil,
			"a bare `local karabiner = require(\"platform.remap\")` is back — that is "
				.. "exactly the form this guards against")
	end)

end)
