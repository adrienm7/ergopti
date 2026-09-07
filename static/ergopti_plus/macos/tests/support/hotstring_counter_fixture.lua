--- tests/support/hotstring_counter_fixture.lua

--- ==============================================================================
--- MODULE: Hotstring Counter Fixture
--- DESCRIPTION:
--- Models native file transactions without accessing extension files on disk.
--- ==============================================================================

local helpers = require("tests.helpers")

return function(callback)
	local original_hs, original_open = _G.hs, io.open
	local ok, err = xpcall(function()
		helpers.with_fresh_modules({ "ui.menu.hotstring_counter", "infra.logger", "infra.fs_dir", "adapters.file_system" }, function()
			local state = { mode = "success", target = "hotstrings", opens = 0, closes = 0, errors = {} }
			local function contents(path)
				if path:match("/manifest%.toml$") and state.manifest_content ~= nil then return state.manifest_content end
				if not path:match("/manifest%.toml$") and state.content ~= nil then return state.content end
				return path:match("/manifest%.toml$") and '[extension]\nname = "Demo"\n' or '[[section]]\n"a" = { output = "b" }\n'
			end
			local logger = helpers.make_logger_stub()
			logger.error = function(_, template, ...) state.errors[#state.errors + 1] = string.format(template, ...) end
			package.loaded["infra.logger"] = logger
			package.loaded["infra.fs_dir"] = { try_entries = function(path)
				return path:match("/extensions/$") and { "demo" } or { "demo.toml" }, true
			end }
			local function attributes(path)
				if path:match("%.toml$") then
					return { mode = "file", dev = 1, ino = path:match("/manifest%.toml$") and 2 or 3,
						size = #contents(path), modification = 1, change = 1 }
				end
				return { mode = "directory", dev = 1, ino = 1 }
			end
			local counter = helpers.load_with_stubs("ui.menu.hotstring_counter", {
				fs = { attributes = attributes, symlinkAttributes = attributes, pathToAbsolute = function(path) return path end },
			})
			io.open = function(path)
				local target = (path:match("/manifest%.toml$") and "manifest" or "hotstrings") == state.target
				if target then state.opens = state.opens + 1 end
				if target and state.mode == "open_nil" then return nil, "PRIVATE_DETAIL", 13 end
				if target and state.mode == "open_throw" then error("PRIVATE_DETAIL") end
				local file = {}
				file.read = function()
					if target and state.mode == "read_nil" then return nil, "PRIVATE_DETAIL", 5 end
					if target and state.mode == "read_throw" then error("PRIVATE_DETAIL") end
					return contents(path)
				end
				file.lines = function()
					if target and (state.mode == "read_nil" or state.mode == "read_throw") then
						return function() error("PRIVATE_DETAIL") end
					end
					return contents(path):gmatch("[^\n]+")
				end
				file.close = function()
					if target then state.closes = state.closes + 1 end
					if target and state.mode == "close_nil" then return nil, "PRIVATE_DETAIL", 5 end
					if target and state.mode == "close_throw" then error("PRIVATE_DETAIL") end
					return true
				end
				return file
			end
			callback(counter, state, { base_dir = "/virtual/macos/" })
		end)
	end, debug.traceback)
	_G.hs, io.open = original_hs, original_open
	if not ok then error(err, 0) end
end
