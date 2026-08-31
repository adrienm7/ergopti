--- tests/unit/lib/test_toml_reader_cache_hook.lua

--- ==============================================================================
--- MODULE: toml_reader cache-provider hook (regression)
--- DESCRIPTION:
--- Locks down the injected disk-cache hook on the shared TOML reader. The hook is
--- what lets repeat boots skip the slow character-level parse and load a
--- precompiled snapshot instead.
---
--- ROOT CAUSE ENCODED: the reader must (1) short-circuit and return a provider's
--- cached table WITHOUT reading the source file when load() hits, (2) fall through
--- to a real parse when load() misses, and (3) hand the freshly parsed result to
--- store() so the next boot can hit. A regression in any of these three either
--- defeats the optimisation (store never called / load ignored) or — worse —
--- serves wrong data (load result not honoured). Each is asserted below.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")
local reader = helpers.load_with_stubs("infra.toml.reader")

--- Writes a TOML body to a temp file and returns its path.
local function write_temp(name, body)
	local path
	if package.config:sub(1, 1) == "\\" then
		path = (os.getenv("TEMP") or "."):gsub("\\", "/") .. "/" .. name .. "_" .. tostring(os.time()) .. ".toml"
	else
		path = os.tmpname()
	end
	local fh = io.open(path, "w"); assert(fh, "cannot open " .. path)
	fh:write(body); fh:close()
	return path
end

local SAMPLE = [==[
[_meta]
description = "hook fixture"
sections_order = ["alpha"]

[[alpha]]
"hi" = { output = "there" }
]==]

helpers.describe("toml_reader: cache-provider hook", function()
	helpers.it("returns the provider's cached table verbatim on a hit (no parse)", function()
		local sentinel = { sections = { marker = true }, sections_order = { "marker" } }
		local load_calls = 0
		reader.set_cache_provider({
			load  = function(_) load_calls = load_calls + 1; return sentinel end,
			store = function() error("store must not run on a cache hit") end,
		})
		-- Point at a path that does NOT exist: if the hook is honoured the missing
		-- file is irrelevant because we never reach the parse.
		local data = reader.parse("/no/such/file/should/be/read.toml")
		helpers.assert_true(data == sentinel, "must return the exact cached table")
		helpers.assert_eq(load_calls, 1)
		reader.set_cache_provider(nil)
	end)

	helpers.it("parses normally and stores the result on a miss", function()
		local stored_path, stored_data = nil, nil
		reader.set_cache_provider({
			load  = function(_) return nil end,            -- miss
			capture_source = function(p) return { path = p } end,
			store = function(p, d, identity)
				stored_path = p
				stored_data = d
				helpers.assert_eq(identity.path, p,
					"store must receive the exact pre-parse source identity")
			end,
		})
		local path = write_temp("hook_miss", SAMPLE)
		local data = reader.parse(path)
		-- Real parse happened.
		helpers.assert_eq(data.meta.description, "hook fixture")
		helpers.assert_eq(data.sections.alpha.entries[1].output, "there")
		-- store() received the very table we returned.
		helpers.assert_eq(stored_path, path)
		helpers.assert_true(stored_data == data, "store must receive the parsed result")
		reader.set_cache_provider(nil)
		os.remove(path)
	end)

	helpers.it("a provider error during load falls through to a normal parse", function()
		reader.set_cache_provider({
			load  = function(_) error("boom") end,
			capture_source = function() return {} end,
			store = function() end,
		})
		local path = write_temp("hook_err", SAMPLE)
		local data = reader.parse(path)
		helpers.assert_eq(data.meta.description, "hook fixture")
		reader.set_cache_provider(nil)
		os.remove(path)
	end)

	helpers.it("with no provider set, parsing is unaffected", function()
		reader.set_cache_provider(nil)
		local path = write_temp("hook_none", SAMPLE)
		local data = reader.parse(path)
		helpers.assert_eq(data.sections.alpha.entries[1].trigger, "hi")
		os.remove(path)
	end)
end)
