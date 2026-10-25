--- tests/unit/infra/config/test_shared_probe_native.lua

--- ==============================================================================
--- MODULE: Native Shared-Tree Probe Admission
--- DESCRIPTION:
--- Invalid sibling candidates must neither block discovery nor shadow a valid
--- packaged child tree. Actual files and regular symlinks retain precedence;
--- incomplete descriptor cleanup cannot certify a shared tree.
--- ==============================================================================

local helpers = require("tests.helpers")
local native = require("luv")
local Shell = require("adapters.shell_runner")

helpers.describe("shared-probe-native", function()
	for _, kind in ipairs({ "fifo", "directory", "file", "symlink" }) do
		helpers.it("(shared-probe-native) classifies a sibling " .. kind .. " before selecting the shipped layout", function()
			local base = os.tmpname()
			os.remove(base)
			local root = base .. "/driver"
			local sibling = base .. "/_shared/data/locales/en.json"
			local child = root .. "/_shared/data/locales/en.json"
			assert(Shell.run("mkdir -p -- " .. Shell.quote(root .. "/_shared/data/locales")
				.. " " .. Shell.quote(base .. "/_shared/data/locales")))
			local file = assert(io.open(child, "w"))
			assert(file:write('{}')); assert(file:close())
			if kind == "fifo" then assert(Shell.run("mkfifo -- " .. Shell.quote(sibling)))
			elseif kind == "directory" then assert(native.fs_mkdir(sibling, 448))
			elseif kind == "symlink" then assert(native.fs_symlink(child, sibling))
			else
				file = assert(io.open(sibling, "w")); assert(file:write('{}')); assert(file:close())
			end
			local expected = root .. ((kind == "file" or kind == "symlink") and "/../_shared" or "/_shared")
			local code = string.format([[package.path = %q
local resolved = require("infra.paths").shared_root_from(%q)
assert(resolved == %q, "a nonregular candidate must not shadow the packaged child tree")
]], package.path, root, expected)
			local expired, exited, exit_code, exit_signal = false, false, nil, nil
			local timer = assert(native.new_timer())
			local child_process
			child_process = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
				exited, exit_code, exit_signal = true, status, signal
				native.timer_stop(timer); native.close(timer); native.close(child_process)
			end))
			assert(require("infra.native_timer").start(native, timer, 2000, 0, function()
				expired = true; child_process:kill("sigkill")
			end))
			while not exited do native.run("once") end
			native.run("nowait")
			assert(Shell.run("rm -r -- " .. Shell.quote(base)))
			helpers.assert_eq(expired, false, "layout discovery must never wait for a FIFO writer")
			helpers.assert_eq(exit_code, 0, "the physical candidate type must determine layout precedence")
			helpers.assert_eq(exit_signal, 0, "a terminated probe is never a successful discovery")
		end)
	end

	helpers.it("(shared-probe-native) refuses an unacknowledged probe close", function()
		local previous_io = io.open
		local previous_reader = package.loaded["infra.regular_file_reader"]
		local paths = require("infra.paths")
		local closes = 0
		local function open(path)
			helpers.assert_contains(path, "/probe-owner/")
			return { close = function() closes = closes + 1; return nil, "EIO" end }
		end
		io.open = open
		package.loaded["infra.regular_file_reader"] = { open_source = open }
		local ok, result = pcall(paths.shared_root_from, "/probe-owner/driver")
		io.open = previous_io
		package.loaded["infra.regular_file_reader"] = previous_reader
		helpers.assert_eq(ok, true)
		helpers.assert_nil(result, "a candidate whose stream did not close cannot certify the tree")
		helpers.assert_eq(closes, 2, "each candidate releases exactly its own probe stream")
	end)
end)
