-- tests/unit/ui/test_shared_catalogue_sources.lua
--- Tests the actual pinned reader and the two UI consumers' native boundaries.
local helpers = require("tests.helpers")

helpers.describe("shared UI catalogue sources", function()
	helpers.it("(ui-catalogue-source) admits regular files and refuses real special files without blocking", function()
		local shell = require("core.process.adapters.shell_runner")
		helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"))
		local quote = require("core.text.engine.utils_core").shell_quote
		local runtime = assert(shell.exec_line("command -v luajit"))
		local root = helpers.driver_root()
		local fixture = root .. "/tests/hardware/run_ui_catalogue_sources.py"
		local result = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime) .. " --driver " .. quote(root))
		helpers.assert_true(result == true or result == 0, "native source classification must finish with real FIFOs")
	end)

	helpers.it("(webview-asset-source) refuses real special assets without blocking", function()
		local shell = require("core.process.adapters.shell_runner")
		helpers.assert_true(shell.has_command("python3") and shell.has_command("luajit"))
		local quote = require("core.text.engine.utils_core").shell_quote
		local runtime = assert(shell.exec_line("command -v luajit"))
		local root = helpers.driver_root()
		local fixture = root .. "/tests/hardware/run_webview_asset_sources.py"
		local result = os.execute("python3 " .. quote(fixture) .. " --runtime " .. quote(runtime) .. " --driver " .. quote(root))
		helpers.assert_true(result == true or result == 0, "native WebView asset classification must not block")
	end)

	for _, mode in ipairs({ "read_throw", "read_nil", "close_throw", "close_false" }) do
		helpers.it("(ui-catalogue-source) rejects " .. mode .. " and closes the acquired stream", function()
			local reader = require("core.fs.engine.regular_file_reader")
			local original, closes = reader.open_source, 0
			reader.open_source = function()
				return {
					read = function()
						if mode == "read_throw" then error("read refused") end
						if mode == "read_nil" then return nil end
						return "partial content"
					end,
					close = function()
						closes = closes + 1
						if mode == "close_throw" then error("close refused") end
						return mode ~= "close_false"
					end,
				}
			end
			local called, bytes = pcall(reader.read_source, "/synthetic")
			reader.open_source = original
			helpers.assert_true(called)
			helpers.assert_nil(bytes)
			helpers.assert_eq(closes, 1)
		end)
	end
end)
