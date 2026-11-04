--- tests/unit/modules/shortcuts/system_actions/test_pixel_png_filters.lua

--- ==============================================================================
--- MODULE: Pixel Color PNG Filter Regression
--- DESCRIPTION:
--- Executes the real Python argv produced by the public pixel action against
--- physical PNG captures. Task callbacks model native handoff, not pixel decoding.
--- ==============================================================================

local helpers = require("tests.helpers")
local quote = require("infra.text_utils").shell_quote


--- Delivers real decoded PNG output through the public two-phase action.
--- @param mode string PNG channel count and scanline filter.
--- @return string|nil copied Actual clipboard publication.
--- @return integer decoder_status Actual Python process exit status.
--- @return table notices User-visible notification levels.
local function copy_capture(mode)
	local copied, decoder_status
	local notices = {}
	helpers.with_stub_scope({
		"modules.shortcuts.actions.system_pixel", "adapters.task_lifecycle",
		"adapters.file_system", "infra.notifications", "infra.i18n", "infra.logger",
		"modules.shortcuts.actions.screen_capture_flow",
	}, function()
		local tasks = {}
		package.loaded["adapters.task_lifecycle"] = {
			native = function(label, executable, callback, arguments)
				local task = { label = label, executable = executable, arguments = arguments,
					callback = callback, running = false }
				function task:start() self.running = true; return self end
				function task:isRunning() return self.running end
				function task:terminate() self.running = false; return self end
				tasks[#tasks + 1] = task
				return task
			end,
			start = function(task) return task:start() == task end,
		}
		package.loaded["adapters.file_system"] = {
			create_secure_temp_file = function() return "/private/tmp/pixel-png-capture" end,
			remove_exact = function() return true end,
			classify_no_follow = function() return nil, "absent" end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(_, _, level) notices[#notices + 1] = level end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["modules.shortcuts.actions.screen_capture_flow"] = {
			ensure_permission = function() return true end,
		}
		local actions = helpers.load_with_stubs("modules.shortcuts.actions.system_pixel", {
			mouse = { absolutePosition = function() return { x = 10, y = 20 } end },
			pasteboard = { setContents = function(value) copied = value; return true end },
		})
		helpers.assert_eq(actions.copy_pixel_color(), true)
		helpers.assert_eq(#tasks, 1)
		helpers.assert_eq(tasks[1].executable, "/usr/sbin/screencapture")
		tasks[1].running = false
		tasks[1].callback(0, "", "")
		helpers.assert_eq(#tasks, 2)
		helpers.assert_eq(tasks[2].label, "Pixel extractor")
		helpers.assert_eq(tasks[2].arguments[1], "-c")
		local command = "python3 -B " .. quote(helpers.driver_root()
			.. "tests/support/modules/shortcuts/pixel_png_fixture.py")
			.. " " .. quote(tasks[2].arguments[2]) .. " " .. quote(mode)
			.. " " .. quote(helpers.temp_dir()) .. " 2>&1"
		local process = assert(io.popen(command, "r"))
		local output = assert(process:read("a"))
		local closed, reason, status = process:close()
		helpers.assert_true(closed == true and reason == "exit" and status == 0,
			"the physical PNG fixture and real decoder must finish: " .. output)
		local code, stdout = output:match("^(%-?%d+)\n(.*)$")
		decoder_status = assert(tonumber(code), "fixture must report the actual decoder exit status")
		tasks[2].running = false
		tasks[2].callback(decoder_status, stdout, "")
		helpers.assert_eq(actions.has_pending_pixel_action(), false)
	end)
	return copied, decoder_status, notices
end


helpers.describe("pixel color reconstructs PNG scanline filters", function()
	for _, channels in ipairs({ 3, 4 }) do
		for filter = 0, 4 do
			local mode = string.format("%d:%d", channels, filter)
			helpers.it("copies the actual RGB center for " .. mode .. " (pixel-png-filters)", function()
				local copied, status, notices = copy_capture(mode)
				helpers.assert_eq(copied, "#a1b2c3",
					"compressed PNG bytes are filtered differences, not pixel channels")
				helpers.assert_eq(status, 0)
				helpers.assert_eq(notices, { "success" })
			end)
		end
	end
	for _, mutation in ipairs({ "invalid-filter", "short-row", "unsupported-depth", "palette",
		"interlaced", "missing-end", "bad-crc", "bad-signature", "truncated-chunk" }) do
		helpers.it("refuses " .. mutation .. " without a fabricated color (pixel-png-refusal)", function()
			local copied, status, notices = copy_capture("3:0:" .. mutation)
			helpers.assert_nil(copied, "an undecodable screenshot must not replace the clipboard")
			helpers.assert_true(status ~= 0, "the decoder must report failure instead of silently exiting zero")
			helpers.assert_eq(notices, { "error" })
		end)
	end
end)
