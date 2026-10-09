--- tests/support/virtual_toml_file_fixture.lua

--- ==============================================================================
--- MODULE: Virtual TOML File Fixture
--- DESCRIPTION:
--- Models native file transactions for the TOML reader without touching disk:
--- every path under the virtual tree answers the content the test sets, and each
--- open and close of it is counted so a test can prove a stream was released.
--- ==============================================================================

local helpers = require("tests.helpers")

return function(callback)
	local original_hs, original_open = _G.hs, io.open
	local ok, err = xpcall(function()
		helpers.with_stub_scope({ "infra.logger", "toml_codec.reader", "infra.toml.reader" }, function()
			local state = { opens = 0, closes = 0, content = '[[section]]\n"a" = { output = "b" }\n' }
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			local function attributes(path)
				if path:match("%.toml$") then
					return { mode = "file", dev = 1, ino = 3, size = #state.content, modification = 1, change = 1 }
				end
				return { mode = "directory", dev = 1, ino = 1 }
			end
			-- Installs a fresh hs stub whose filesystem answers the virtual tree.
			helpers.load_with_stubs("toml_codec.reader", {
				fs = { attributes = attributes, symlinkAttributes = attributes, pathToAbsolute = function(path) return path end },
			})
			io.open = function()
				state.opens = state.opens + 1
				local file = {}
				file.read = function() return state.content end
				file.lines = function() return state.content:gmatch("[^\n]+") end
				file.close = function()
					state.closes = state.closes + 1
					return true
				end
				return file
			end
			callback(state)
		end)
	end, debug.traceback)
	_G.hs, io.open = original_hs, original_open
	if not ok then error(err, 0) end
end
