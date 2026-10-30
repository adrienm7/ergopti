--- tests/unit/adapters/test_reload_breadcrumb.lua

--- ==============================================================================
--- MODULE: Reload Breadcrumb
--- DESCRIPTION:
--- The synchronous trail a controlled reload leaves on disk, over a real file:
--- 1. a reload's acceptance opens a new trail and each later stage appends one
---    line of a stage name and a monotonic time, closed before returning;
--- 2. an exit alone writes nothing, and an exit that supersedes a reload keeps
---    appending to its trail;
--- 3. the next boot appends `boot` to an existing, short trail only;
--- 4. a stage name outside the closed vocabulary is a caller bug and raises.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Loads the adapter over a fresh file path and a scripted clock.
--- @return table breadcrumb, string path, table clock
local function load_breadcrumb()
	package.loaded["adapters.reload_breadcrumb"] = nil
	local breadcrumb = require("adapters.reload_breadcrumb")
	local path = os.tmpname()
	os.remove(path)
	local clock = { ns = 5e9 }
	breadcrumb.configure_for_tests({ path = path, clock = function() return clock.ns end })
	return breadcrumb, path, clock
end

--- Reads the trail's lines.
--- @param path string
--- @return table|nil lines Nil when the file does not exist.
local function lines_of(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local text = file:read("*a")
	file:close()
	local lines = {}
	for line in text:gmatch("[^\n]+") do lines[#lines + 1] = line end
	return lines
end

helpers.describe("reload breadcrumb", function()
	helpers.it("opens a trail on a reload's acceptance and appends each stage (reload-breadcrumb)", function()
		local breadcrumb, path, clock = load_breadcrumb()
		helpers.assert_eq(breadcrumb.record("reload", "lease_fenced"), false, "no trail before an acceptance")
		helpers.assert_nil(lines_of(path))
		helpers.assert_true(breadcrumb.record("reload", "accepted"))
		clock.ns = 5.25e9
		helpers.assert_true(breadcrumb.record("reload", "lease_fence_requested"))
		helpers.assert_eq(lines_of(path), { "accepted 5000.000", "lease_fence_requested 5250.000" },
			"each line is on disk when record returns")

		-- The next reload starts a new trail instead of growing the previous one
		helpers.assert_true(breadcrumb.record("reload", "accepted"))
		helpers.assert_eq(lines_of(path), { "accepted 5250.000" })
		os.remove(path)
	end)

	helpers.it("writes nothing for an exit alone and follows a reload upgraded to an exit (reload-breadcrumb)", function()
		local breadcrumb, path = load_breadcrumb()
		helpers.assert_eq(breadcrumb.record("exit", "accepted"), false)
		helpers.assert_eq(breadcrumb.record("exit", "teardown_attempt"), false)
		helpers.assert_nil(lines_of(path), "a quit never touches the reload trail")
		breadcrumb.record("reload", "accepted")
		helpers.assert_true(breadcrumb.record("exit", "upgraded_to_exit"))
		helpers.assert_eq(#lines_of(path), 2)
		os.remove(path)
	end)

	helpers.it("appends the boot line to an existing short trail only (reload-breadcrumb)", function()
		local breadcrumb, path = load_breadcrumb()
		helpers.assert_eq(breadcrumb.record_boot(), false, "no trail, no boot line")
		helpers.assert_nil(lines_of(path))
		breadcrumb.record("reload", "accepted")
		breadcrumb.record("reload", "hs_reload_called")

		-- The next process boots with no trail open of its own
		breadcrumb.configure_for_tests({ path = path, clock = function() return 6e9 end })
		helpers.assert_true(breadcrumb.record_boot())
		helpers.assert_eq(lines_of(path), { "accepted 5000.000", "hs_reload_called 5000.000", "boot 6000.000" })

		local file = assert(io.open(path, "wb"))
		file:write(string.rep("x", breadcrumb.MAX_BYTES + 1))
		file:close()
		helpers.assert_eq(breadcrumb.record_boot(), false, "boots without a reload never grow it unbounded")
		os.remove(path)
	end)

	helpers.it("refuses a stage name outside the closed vocabulary (reload-breadcrumb)", function()
		local breadcrumb, path = load_breadcrumb()
		for _, stage in ipairs({ "Accepted", "has space", "/Users/someone", "", string.rep("a", 65) }) do
			helpers.assert_eq(pcall(breadcrumb.record, "reload", stage), false, stage)
		end
		helpers.assert_true(breadcrumb.record("reload", "accepted"))
		helpers.assert_true(breadcrumb.record("reload", "step_script-watcher-1"))
		os.remove(path)
	end)

	helpers.it("names the trail in the default logs folder, whatever LogsDirPath says (reload-breadcrumb)", function()
		package.loaded["adapters.reload_breadcrumb"] = nil
		local breadcrumb = require("adapters.reload_breadcrumb")
		breadcrumb.configure_for_tests(nil)
		local path = breadcrumb.path()
		helpers.assert_true(type(path) == "string" and path:match("/Library/Logs/ergopti_plus/reload_breadcrumb%.txt$") ~= nil,
			tostring(path))
	end)
end)
