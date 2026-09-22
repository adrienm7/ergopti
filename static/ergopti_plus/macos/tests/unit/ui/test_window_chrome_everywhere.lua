--- tests/unit/ui/test_window_chrome_everywhere.lua

--- ==============================================================================
--- MODULE: Every Window Gets The Same Chrome
--- DESCRIPTION:
--- The system diagnostics window had no visible edge over a white web page:
--- Hammerspoon webviews cast no drop shadow by default, and that window built
--- its own chrome instead of going through ui_builder. The chrome (native title
--- bar and close button, drop shadow, floating level) now comes from one
--- function, ui_builder.window_chrome_steps, and this file fails when it loses a
--- step or when any window of the driver is created without it.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Subtrees that ship in the driver, plus the entry point.
local SOURCE_DIRS = { "adapters", "infra", "modules", "platform", "ui" }
local ROOT_FILES  = { "init.lua" }

-- The driver builds at least the ui_builder windows and the health check window.
local MIN_WEBVIEW_FILES = 2


--- Recursively lists every driver .lua file under a subtree, tests excluded.
--- @param dir string Absolute directory.
--- @param out table Accumulator of absolute paths.
local function collect(dir, out)
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("%s+$", ""):gsub("\\", "/")
		if line:match("%.lua$") and not line:match("/vendor/") and not line:match("/tests/") then
			out[#out + 1] = line
		end
	end
	pipe:close()
end

--- Returns the source with every line comment removed, so a mention in prose
--- neither creates nor satisfies a call site.
--- @param src string
--- @return string
local function strip_comments(src)
	local kept = {}
	for line in (src .. "\n"):gmatch("(.-)\n") do
		kept[#kept + 1] = (line:gsub("%-%-.*$", ""))
	end
	return table.concat(kept, "\n")
end

--- Builds ui_builder against stubs and a recording window.
--- @return table Builder, table calls, table window
local function load_builder()
	local calls = {}
	local window = {}
	for _, name in ipairs({ "windowStyle", "shadow", "level" }) do
		window[name] = function(self, value)
			calls[#calls + 1] = { name = name, value = value }
			return self
		end
	end
	local Builder = helpers.load_with_stubs("ui.ui_builder", {
		webview = { windowMasks = { titled = 1, closable = 2, miniaturizable = 4, utility = 16 } },
		drawing = { windowLevels = { floating = 3, normal = 0 } },
	})
	return Builder, calls, window
end

--- Applies every chrome step to the recording window and returns its calls.
--- @param opts table|nil
--- @return table
local function applied(opts)
	local Builder, calls, window = load_builder()
	for _, step in ipairs(Builder.window_chrome_steps(window, opts)) do step.apply() end
	return calls
end

--- Finds the value a named call received.
--- @param calls table
--- @param name string
--- @return any, boolean found
local function value_of(calls, name)
	for _, call in ipairs(calls) do
		if call.name == name then return call.value, true end
	end
	return nil, false
end





-- ====================================
-- ====================================
-- ======= 1/ The shared chrome =======
-- ====================================
-- ====================================

helpers.describe("window chrome: one function defines every window's frame", function()

	helpers.it("casts a drop shadow so the window has an edge over a white page", function()
		local value, found = value_of(applied(), "shadow")
		helpers.assert_true(found and value == true,
			"Hammerspoon webviews have no shadow by default; every window must turn it on")
	end)

	helpers.it("gives the window a native title bar and close button", function()
		local style = value_of(applied(), "windowStyle")
		helpers.assert_true(type(style) == "number", "windowStyle must be applied")
		helpers.assert_true(style & 1 == 1, "titled: a borderless window has no frame at all")
		helpers.assert_true(style & 2 == 2, "closable: every window can be closed from its frame")
	end)

	helpers.it("floats above other apps unless the caller asks otherwise", function()
		helpers.assert_eq(value_of(applied(), "level"), 3)
		helpers.assert_eq(value_of(applied({ level = 0 }), "level"), 0)
	end)

	helpers.it("keeps the shadow when a caller brings its own style mask", function()
		local calls = applied({ style_masks = 1 + 2 + 4 })
		helpers.assert_eq(value_of(calls, "windowStyle"), 7)
		helpers.assert_eq(value_of(calls, "shadow"), true,
			"a custom mask changes the buttons, never the edge of the window")
	end)

end)





-- ================================================
-- ================================================
-- ======= 2/ No window is built without it =======
-- ================================================
-- ================================================

helpers.describe("window chrome: every webview of the driver goes through it", function()

	helpers.it("finds no hs.webview.new call in a file that skips window_chrome_steps", function()
		local root = helpers.driver_root()
		local files = {}
		for _, dir in ipairs(SOURCE_DIRS) do collect(root .. dir, files) end
		for _, name in ipairs(ROOT_FILES) do files[#files + 1] = root .. name end

		local creators, offenders = 0, {}
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			if fh then
				local src = strip_comments(fh:read("*a"))
				fh:close()
				if src:find("hs.webview.new", 1, true) then
					creators = creators + 1
					if not src:find("window_chrome_steps(", 1, true) then
						offenders[#offenders + 1] = path:sub(#root + 1)
					end
				end
			end
		end
		helpers.assert_true(creators >= MIN_WEBVIEW_FILES,
			"the scan found " .. creators .. " file(s) creating a webview; the walk is broken")
		helpers.assert_eq(offenders, {},
			"these files create a window without the shared chrome (no shadow, no common frame)")
	end)

end)
