--- tests/unit/lib/test_logger_log_folder_failure.lua

--- ==============================================================================
--- MODULE: Logger — an unusable log folder is reported, never swallowed
--- DESCRIPTION:
--- init_log_path() used to pcall hs.fs.mkdir on every component and discard the
--- result. A dangling logs link or a refused create therefore left no trace: the
--- boot log stopped at config-path initialization and every later line targeted
--- a folder that did not exist (symlinked-config-dir).
---
--- FEATURES & RATIONALE:
--- 1. A folder that stays absent after mkdir is logged to the still-active boot
---    log, with the exact component and cause, and init_log_path returns false.
--- 2. A dangling symbolic link is named as such.
--- 3. An existing component, including a link to a real folder, is not an error.
--- ==============================================================================

local helpers = require("tests.helpers")

local _real_logger_loaded = package.loaded["infra.logger"]
package.loaded["infra.logger"] = nil
local Logger = require("infra.logger")

local CONFIG_DIR = "/tmp/ergopti_test_log_folder/"
local LOG_DIR = CONFIG_DIR .. "hammerspoon/logs/"

--- Runs `body` with hs.fs.mkdir / attributes / symlinkAttributes replaced and a
--- capturing sink installed, then restores everything.
--- @param missing string Component (trailing slash) that mkdir cannot create.
--- @param link_mode string|nil symlinkAttributes().mode reported for it.
--- @param body function Receives the captured lines and init_log_path results.
local function with_unusable(missing, link_mode, body)
	local hs = _G.hs
	local saved = {
		mkdir = hs.fs.mkdir,
		attributes = hs.fs.attributes,
		symlink = hs.fs.symlinkAttributes,
		doAfter = hs.timer.doAfter,
	}
	hs.fs.mkdir = function(path)
		if path == missing then return nil, "Permission denied" end
		return nil, "File exists"
	end
	hs.fs.attributes = function(path)
		if path == missing then return nil end
		return { mode = "directory", modification = os.time() }
	end
	hs.fs.symlinkAttributes = function(path)
		if path .. "/" == missing and link_mode then return { mode = link_mode } end
		return nil
	end
	hs.timer.doAfter = function() return { stop = function() return true end } end
	local lines = {}
	Logger.set_sink(function(line) lines[#lines + 1] = line end)

	local ok, err = pcall(function()
		local usable, detail = Logger.init_log_path(CONFIG_DIR, 14)
		body(lines, usable, detail)
	end)

	Logger.set_sink(nil)
	hs.fs.mkdir = saved.mkdir
	hs.fs.attributes = saved.attributes
	hs.fs.symlinkAttributes = saved.symlink
	hs.timer.doAfter = saved.doAfter
	if not ok then error(err, 0) end
end

--- True when any captured ERROR line contains every fragment.
local function error_line_with(lines, ...)
	local fragments = { ... }
	for _, line in ipairs(lines) do
		if line:find("[ERROR]", 1, true) then
			local all = true
			for _, fragment in ipairs(fragments) do
				if not line:find(fragment, 1, true) then all = false end
			end
			if all then return true end
		end
	end
	return false
end

helpers.describe("logger — unusable log folder (symlinked-config-dir)", function()
	helpers.it("reports a create refusal with the exact component and cause", function()
		with_unusable(LOG_DIR, nil, function(lines, usable, detail)
			helpers.assert_eq(usable, false)
			helpers.assert_contains(detail, LOG_DIR)
			helpers.assert_contains(detail, "Permission denied")
			helpers.assert_true(error_line_with(lines, LOG_DIR, "Permission denied"),
				"the refusal must reach the boot log before the logger re-points; got:\n"
				.. table.concat(lines, "\n"))
		end)
	end)

	helpers.it("names a dangling logs link as such", function()
		with_unusable(LOG_DIR, "link", function(lines, usable, detail)
			helpers.assert_eq(usable, false)
			helpers.assert_contains(detail, "symbolic link whose target does not exist")
			helpers.assert_true(error_line_with(lines, "symbolic link whose target does not exist"))
		end)
	end)

	helpers.it("accepts existing components, including a link to a real folder", function()
		with_unusable("/never-requested/", nil, function(lines, usable, detail)
			helpers.assert_eq(usable, true)
			helpers.assert_nil(detail)
			helpers.assert_true(not error_line_with(lines, "Log folder"),
				"an existing folder must not be reported: " .. table.concat(lines, "\n"))
		end)
	end)
end)

package.loaded["infra.logger"] = _real_logger_loaded
