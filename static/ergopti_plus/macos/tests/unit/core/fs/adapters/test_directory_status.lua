--- tests/unit/core/fs/adapters/test_directory_status.lua

--- ==============================================================================
--- MODULE: Followed Directory Root Classification
--- DESCRIPTION:
--- Native lstat absence and followed directory attributes have distinct contracts.
--- ==============================================================================

local helpers = require("tests.helpers")

local function with_adapter(run)
	local previous_hs = rawget(_G, "hs")
	local state = { entry = { mode = "directory" }, followed = { mode = "directory" }, follows = 0 }
	local ok, failure = xpcall(function()
		helpers.with_fresh_modules({ "core.fs.adapters.file_system", "core.logger.engine.logger", "core.fs.engine.dir", "core.text.engine.utils" }, function()
			package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
			package.loaded["core.text.engine.utils"] = {}
			package.loaded["core.fs.engine.dir"] = { try_entries = function()
				if state.list_error then return nil, false, "cannot list parent" end
				return state.listed and { "Applications" } or {}, true
			end }
			_G.hs = { fs = {
				symlinkAttributes = function() return state.entry end,
				attributes = function()
					state.follows = state.follows + 1
					if state.throw then error("injected followed stat failure") end
					return state.followed, state.follow_error, state.follow_errno
				end,
			} }
			run(require("core.fs.adapters.file_system"), state)
		end)
	end, debug.traceback)
	_G.hs = previous_hs
	if not ok then error(failure, 0) end
end

helpers.describe("FileSystem.directory_status", function()
	helpers.it("rejects invalid absolute-root inputs", function()
		with_adapter(function(adapter)
			for _, path in ipairs({ "", "relative", false }) do
				local status = adapter.directory_status(path)
				helpers.assert_eq(status, "error")
			end
			helpers.assert_eq(adapter.directory_status(nil), "error")
		end)
	end)

	helpers.it("refuses a link when followed attributes are unavailable", function()
		with_adapter(function(adapter, state)
			state.entry = { mode = "link" }
			hs.fs.attributes = nil
			helpers.assert_eq(adapter.directory_status("/fixture/Applications"), "error")
		end)
	end)

	for _, link in ipairs({ false, true }) do
		helpers.it("accepts a directory with final link=" .. tostring(link), function()
			with_adapter(function(adapter, state)
				if link then state.entry = { mode = "link" } end
				local status, attributes = adapter.directory_status("/fixture/Applications")
				helpers.assert_eq(status, "present")
				helpers.assert_eq(attributes.mode, "directory")
				helpers.assert_eq(state.follows, link and 1 or 0)
			end)
		end)
	end

	for _, mode in ipairs({ "file", "linked_file", "dangling", "stat_throw", "stat_error", "unknown_absence", "list_error" }) do
		helpers.it("refuses " .. mode .. " without calling it absent", function()
			with_adapter(function(adapter, state)
				state.entry = { mode = "link" }
				if mode == "file" then state.entry = { mode = "file" } end
				if mode == "linked_file" then state.followed = { mode = "file" } end
				if mode == "dangling" then state.followed = nil end
				if mode == "stat_throw" then state.throw = true end
				if mode == "stat_error" then state.follow_error = "inaccessible target" end
				if mode == "unknown_absence" then state.entry = nil; state.listed = true end
				if mode == "list_error" then state.entry = nil; state.list_error = true end
				local status, failure = adapter.directory_status("/fixture/Applications")
				helpers.assert_eq(status, "error")
				helpers.assert_type(failure, "string")
				helpers.assert_true(#failure > 0)
			end)
		end)
	end

	helpers.it("accepts only proven absence as an optional missing root", function()
		with_adapter(function(adapter, state)
			state.entry = nil
			local status, detail = adapter.directory_status("/fixture/Applications")
			helpers.assert_eq(status, "absent")
			helpers.assert_nil(detail)
			helpers.assert_eq(state.follows, 0)
		end)
	end)
end)

helpers.describe("FileSystem.followed_mode (config-backup-special-nodes)", function()
	helpers.it("does not mistake a filename for an ENOENT reason (followed-mode-enoent-path)", function()
		with_adapter(function(adapter, state)
			state.followed = nil
			state.follow_error = "cannot obtain information from file '/No such file or directory': Permission denied"
			local status, detail = adapter.followed_mode("/No such file or directory")
			helpers.assert_eq(status, "error", "the filename is not the native failure reason")
			helpers.assert_contains(detail, "Permission denied")
			state.follow_error = "cannot obtain information from file '/fixture/missing': No such file or directory"
			helpers.assert_eq(adapter.followed_mode("/fixture/missing"), "absent")
			state.follow_errno = 13
			helpers.assert_eq(adapter.followed_mode("/fixture/missing"), "error", "a native errno outranks text")
		end)
	end)

	helpers.it("(config-backup-special-nodes) reports the followed mode without opening anything", function()
		with_adapter(function(adapter, state)
			state.followed = { mode = "named pipe" }
			local status, mode = adapter.followed_mode("/fixture/pipe")
			helpers.assert_eq(status, "present")
			helpers.assert_eq(mode, "named pipe")
		end)
	end)

	helpers.it("(config-backup-special-nodes) reports a dangling link as absent and any other refusal as an error", function()
		with_adapter(function(adapter, state)
			state.followed = nil
			state.follow_error = "No such file or directory"
			helpers.assert_eq((adapter.followed_mode("/fixture/dangling")), "absent")
			state.follow_error = "Permission denied"
			helpers.assert_eq((adapter.followed_mode("/fixture/denied")), "error")
			state.throw = true
			helpers.assert_eq((adapter.followed_mode("/fixture/throws")), "error")
			helpers.assert_eq((adapter.followed_mode("relative")), "error")
		end)
	end)
end)
