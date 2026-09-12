--- tests/unit/lib/test_manifest_menu_fixture_cleanup.lua

--- ==============================================================================
--- MODULE: Manifest Fixture Cleanup Regressions
--- DESCRIPTION:
--- Observes real file ownership across callback and construction failures.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.manifest_menu_fixture")
local CONTENT = '{"test_menu":[{"type":"dynamic","id":"owned"}]}'

--- Captures allocation and injects one failure while preserving real file I/O.
--- @param mode string Failure boundary or success.
local function check_cleanup(mode)
	local original_open, original_remove, original_tmpname = io.open, os.remove, os.tmpname
	local original_load = helpers.load_with_stubs
	local path, callback_reached, readable, removed_after_scope
	local write_handles_closed = 0
	local marker = "manifest-fixture-" .. mode
	local ok, detail = pcall(function()
		os.tmpname = function()
			path = original_tmpname()
			return path
		end
		io.open = function(name, access)
			if name == path and access == "wb" then
				if mode == "open" then return nil, marker end
				local handle = assert(original_open(name, access))
				return {
					write = function(_, content)
						if mode == "write" then return nil, marker end
						return handle:write(content)
					end,
					close = function()
						write_handles_closed = write_handles_closed + 1
						local closed, reason = handle:close()
						if mode == "close" then return nil, marker end
						return closed, reason
					end,
				}
			end
			return original_open(name, access)
		end
		if mode == "construction" then
			helpers.load_with_stubs = function(...)
				original_load(...)
				error(marker)
			end
		end
		if mode == "remove" then os.remove = function() return nil, marker end end
		local results = table.pack(fixture.with_manifest(CONTENT, nil, function(renderer, allocated)
			callback_reached = true
			local handle = assert(original_open(allocated, "rb"))
			readable = handle:read("*a")
			assert(handle:close())
			local built = renderer.build("test_menu", "Test", {
				owned = function(items) items[#items + 1] = { title = "owned row" } end,
			}, nil, {})
			helpers.assert_eq(built[1].title, "owned row", "real JSON and renderer must run")
			if mode == "callback" then error(marker) end
			return "first", nil, "third"
		end))
		helpers.assert_eq(results.n, 3, "fixture preserves callback return arity")
		helpers.assert_eq(results[1], "first")
		helpers.assert_eq(results[3], "third")
	end)
	io.open, os.remove, os.tmpname = original_open, original_remove, original_tmpname
	helpers.load_with_stubs = original_load
	-- Always reclaim an artifact even when the subject regresses or refuses cleanup.
	if path then
		local handle, _, code = original_open(path, "rb")
		removed_after_scope = handle == nil and code == 2
		if handle then assert(handle:close()) end
		if not removed_after_scope then assert(original_remove(path)) end
	end
	helpers.assert_true(type(path) == "string", "fixture must allocate its actual file")
	helpers.assert_eq(ok, mode == "success", "unexpected outcome: " .. tostring(detail))
	if mode ~= "success" then
		helpers.assert_true(tostring(detail):find(marker, 1, true) ~= nil, "original failure must remain visible")
	end
	local reaches_callback = mode == "success" or mode == "callback" or mode == "remove"
	helpers.assert_eq(callback_reached == true, reaches_callback, "failure must occur at the intended boundary")
	if reaches_callback then helpers.assert_eq(readable, CONTENT, "fixture must contain the actual JSON") end
	helpers.assert_eq(write_handles_closed, mode == "open" and 0 or 1, "every opened writer is closed once")
	helpers.assert_eq(removed_after_scope, mode ~= "remove", "fixture must remove its file unless removal refused")
end

helpers.describe("Manifest fixture artifact ownership", function()
	for _, mode in ipairs({ "success", "callback", "open", "write", "close", "construction", "remove" }) do
		helpers.it("(manifest-fixture-cleanup) owns the file through " .. mode, function()
			check_cleanup(mode)
		end)
	end
end)
