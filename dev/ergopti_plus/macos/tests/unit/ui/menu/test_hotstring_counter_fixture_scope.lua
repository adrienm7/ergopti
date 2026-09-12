--- tests/unit/ui/menu/test_hotstring_counter_fixture_scope.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Fixture Isolation
--- DESCRIPTION:
--- Checks exact cache restoration and fresh reader ownership around native fakes.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_counter = require("tests.support.hotstring_counter_fixture")
local MODULES = {
	"hs", "tests.stubs.hs", "infra.i18n", "infra.paths",
	"ui.menu.hotstring_counter", "infra.logger", "infra.fs_dir", "adapters.file_system",
	"toml_codec.reader", "infra.toml.reader",
	"ui.menu.fixture_scope_sentinel", "modules.keymap.registry_fixture_scope_sentinel",
}

local function with_observer(callback)
	helpers.with_stub_scope(MODULES, function()
		local original_open = io.open
		local outcome = table.pack(xpcall(callback, debug.traceback))
		io.open = original_open
		if not outcome[1] then error(outcome[2], 0) end
	end)
end

helpers.describe("Hotstring counter fixture isolation", function()
	for _, predecessor in ipairs({ "absent", "false", "table" }) do
		for _, fails in ipairs({ false, true }) do
			helpers.it("(counter-fixture-scope) restores " .. predecessor .. " owners after "
				.. (fails and "callback failure" or "success"), function()
				with_observer(function()
					local expected = {}
					for _, name in ipairs(MODULES) do
						local value
						if predecessor == "false" then value = false end
						if predecessor == "table" then value = {} end
						expected[name] = value
						package.loaded[name] = value
					end
					local native, open = rawget(_G, "hs"), io.open
					local entered = false
					local ok, reason = pcall(with_counter, function(counter)
						entered = true
						helpers.assert_type(counter.count_all, "function")
						if fails then error("counter fixture injected failure", 0) end
					end)
					helpers.assert_eq(entered, true)
					helpers.assert_eq(ok, not fails)
					if fails then
						helpers.assert_true(tostring(reason):find("counter fixture injected failure", 1, true) ~= nil)
					end
					helpers.assert_true(rawequal(rawget(_G, "hs"), native))
					helpers.assert_true(io.open == open)
					for _, name in ipairs(MODULES) do
						helpers.assert_true(package.loaded[name] == expected[name], name .. " must be restored")
					end
				end)
			end)
		end
	end

	helpers.it("(counter-fixture-scope) reloads reader aliases with their diagnostic owner", function()
		with_observer(function()
			local stale = { parse_text = function() error("stale reader reached", 0) end }
			package.loaded["toml_codec.reader"] = stale
			package.loaded["infra.toml.reader"] = stale
			local previous
			for attempt = 1, 2 do
				with_counter(function(counter, state, context)
					local reader = require("infra.toml.reader")
					helpers.assert_true(reader ~= stale, "the facade must not retain a previous provider or logger")
					helpers.assert_true(reader == package.loaded["toml_codec.reader"])
					if attempt == 2 then helpers.assert_true(reader ~= previous) end
					previous = reader
					helpers.assert_eq(counter.count_all(context, {}).ext, 1)
					local before = #state.errors
					state.mode = "read_nil"
					local _, committed = reader.parse("/virtual/extensions/demo/hotstrings/demo.toml")
					helpers.assert_eq(committed, false)
					helpers.assert_true(#state.errors > before, "reader failures must reach this fixture's logger")
				end)
				helpers.assert_true(package.loaded["toml_codec.reader"] == stale)
				helpers.assert_true(package.loaded["infra.toml.reader"] == stale)
			end
		end)
	end)
end)
