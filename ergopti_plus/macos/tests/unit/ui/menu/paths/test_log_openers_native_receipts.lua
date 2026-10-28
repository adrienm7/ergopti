--- tests/unit/ui/menu/paths/test_log_openers_native_receipts.lua

--- ==============================================================================
--- MODULE: Errors Log Native Classification Receipts
--- DESCRIPTION:
--- Runs the actual FileSystem and log opener over physical POSIX entries. Only
--- proven absence may tell the user that today's errors file does not exist.
--- ==============================================================================

local helpers = require("tests.helpers")
local lfs = require("lfs")
local shell_quote = require("text_utils").shell_quote
local OWNERS = { "ui.log_openers", "infra.logger", "infra.config_paths",
	"infra.notifications", "adapters.file_system", "infra.fs_dir" }

--- Uses real filesystem outcomes and always reopens its private fixture for cleanup.
--- @param kind string Physical entry to exercise.
--- @param check function Receives the subject and recording ports.
local function with_entry(kind, check)
	local dir = os.tmpname()
	assert(os.remove(dir))
	assert(lfs.mkdir(dir))
	local path = dir .. "/errors.log"
	local target = dir .. "/target.log"
	local ok, failure = xpcall(function()
		if kind == "file" or kind == "denied" then
			local file = assert(io.open(path, "wb"))
			assert(file:write("A real warning is present.\n"))
			assert(file:close())
		elseif kind == "directory" then
			assert(lfs.mkdir(path))
		elseif kind == "link" or kind == "dangling" then
			if kind == "link" then
				local file = assert(io.open(target, "wb"))
				assert(file:write("A linked warning is present.\n"))
				assert(file:close())
			end
			assert(lfs.link(target, path, true))
		end
		if kind == "denied" then
			assert(os.execute("chmod 000 " .. shell_quote(dir)))
			local attributes, detail = lfs.attributes(path)
			helpers.assert_nil(attributes, "The native permission denial must actually occur")
			helpers.assert_type(detail, "string")
		end
		helpers.with_stub_scope(OWNERS, function()
			local observed = { opened = {}, notified = {}, errors = {} }
			local logger = helpers.make_logger_stub()
			logger.today_errors_path = function() return path end
			logger.error = function(_, message, ...)
				observed.errors[#observed.errors + 1] = string.format(message, ...)
			end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.config_paths"] = {}
			package.loaded["infra.notifications"] = { notify = function(message)
				observed.notified[#observed.notified + 1] = message
				return observed.notify_ok ~= false
			end }
			local subject = helpers.load_with_stubs("ui.log_openers", { fs = {
				attributes = lfs.attributes,
				symlinkAttributes = lfs.symlinkattributes,
				dir = lfs.dir,
			} })
			local FileSystem = require("adapters.file_system")
			observed.status = FileSystem.path_status(path)
			observed.open = function(opened)
				observed.opened[#observed.opened + 1] = opened
				return true
			end
			check(subject, observed, path)
		end)
	end, debug.traceback)
	assert(os.execute("chmod 700 " .. shell_quote(dir)))
	if lfs.attributes(path, "mode") == "directory" then assert(lfs.rmdir(path))
	elseif lfs.symlinkattributes(path) then assert(os.remove(path)) end
	if lfs.attributes(target) then assert(os.remove(target)) end
	assert(lfs.rmdir(dir))
	if not ok then error(failure, 0) end
end

helpers.describe("errors log native classification", function()
	for _, kind in ipairs({ "denied", "directory", "dangling" }) do
		helpers.it("(errors-log-classification) refuses " .. kind .. " without claiming an empty day", function()
			with_entry(kind, function(subject, observed)
				helpers.assert_eq(observed.status, kind == "denied" and "error" or "present")
				helpers.assert_eq(subject.open_today_errors(observed.open), false)
				helpers.assert_eq(#observed.opened, 0)
				helpers.assert_eq(#observed.notified, 0, "An inspection failure proves nothing about today's warnings")
				helpers.assert_true(#observed.errors > 0, "The inspection failure must remain visible")
			end)
		end)
	end
	for _, kind in ipairs({ "file", "link" }) do
		helpers.it("(errors-log-classification) opens a real " .. kind, function()
			with_entry(kind, function(subject, observed, path)
				helpers.assert_eq(subject.open_today_errors(observed.open), true)
				helpers.assert_eq(observed.opened, { path })
				helpers.assert_eq(#observed.notified, 0)
				helpers.assert_eq(#observed.errors, 0)
			end)
		end)
	end
	helpers.it("(errors-log-classification) announces only a physically absent file", function()
		with_entry("absent", function(subject, observed)
			helpers.assert_eq(observed.status, "absent")
			helpers.assert_eq(subject.open_today_errors(observed.open), true)
			helpers.assert_eq(#observed.opened, 0)
			helpers.assert_eq(observed.notified, { "menu.debug.no_errors_today" })
			helpers.assert_eq(#observed.errors, 0)
		end)
	end)
	helpers.it("(errors-log-classification) preserves a refused file opener", function()
		with_entry("file", function(subject, observed, path)
			helpers.assert_eq(subject.open_today_errors(function(opened)
				observed.opened[#observed.opened + 1] = opened
				return false
			end), false)
			helpers.assert_eq(observed.opened, { path })
			helpers.assert_eq(#observed.notified, 0)
		end)
	end)
	helpers.it("(errors-log-classification) preserves a refused absence notification", function()
		with_entry("absent", function(subject, observed)
			observed.notify_ok = false
			helpers.assert_eq(subject.open_today_errors(observed.open), false)
			helpers.assert_eq(#observed.opened, 0)
			helpers.assert_eq(observed.notified, { "menu.debug.no_errors_today" })
			helpers.assert_eq(#observed.errors, 1)
		end)
	end)
end)
