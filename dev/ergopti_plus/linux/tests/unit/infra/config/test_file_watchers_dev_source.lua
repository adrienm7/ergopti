--- tests/unit/infra/config/test_file_watchers_dev_source.lua

--- ==============================================================================
--- MODULE: File Watchers Developer Source Tests
--- DESCRIPTION:
--- A developer run (tools/dev/run-linux-dev.sh) restarts the daemon when a
--- saved .lua of the clone settles, as the macOS developer app reloads on one.
--- These tests pin that a nested driver .lua calls on_source_change and not
--- the hotstring reload, that a test file or a TOML does not, and that an
--- ordinary daemon arms nothing of the kind.
--- ==============================================================================

package.loaded["tests.support.infra.config.file_watchers_fixture"] = nil
local Fixture = require("tests.support.infra.config.file_watchers_fixture")
local helpers, CAN_STAT = Fixture.helpers, Fixture.CAN_STAT

--- Builds a source tree outside /tmp (the Lua filter ignores /tmp paths).
--- @return string root
local function source_tree()
	local root = Fixture.make_non_tmp_dir()
	for _, folder in ipairs({ "/infra", "/modules/deep", "/tests/unit" }) do
		assert(os.execute("mkdir -p '" .. root .. folder .. "'"))
	end
	for _, file in ipairs({ "/infra/a.lua", "/modules/deep/b.lua", "/tests/unit/c.lua", "/data.toml" }) do
		Fixture.write_file(root .. file, "return {}\n")
	end
	return root
end

--- Moves a file's modification time to a distinct second, so the poll sees it.
--- @param path string
--- @param epoch integer
local function retime(path, epoch)
	assert(os.execute("touch -d '@" .. epoch .. "' '" .. path .. "'"))
end

--- Starts a watcher on a tree, edits one file and settles the burst.
--- @param root string Source tree.
--- @param edited string Relative path of the edited file.
--- @param native boolean|nil Uses the installed inotify backend when true.
--- @return table counts { reload = n, source = n }
local function settle_after_edit(root, edited, native)
	local now = 1000
	local counts = { reload = 0, source = 0 }
	local backend = false
	if native then backend = assert(Fixture.native_luv, "inotify source watching requires luv") end
	local watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", backend)
	watcher.start({
		now_ms = function() return now end,
		hotstrings_dir = root,
		source_dirs = { root },
		on_reload = function() counts.reload = counts.reload + 1 end,
		on_source_change = function() counts.source = counts.source + 1 end,
	})
	watcher.pump()
	retime(root .. edited, 1700000100)
	if native then backend.run("nowait") end
	watcher.pump()
	now = now + 1000
	watcher.pump()
	local retired = watcher.stop()
	if native then backend.run("nowait"); retired = watcher.stop() end
	helpers.assert_true(retired, "every watcher retires")
	return counts
end

helpers.describe("file_watchers developer source trees", function()
	if not CAN_STAT then
		print("  [developer source watching not executed: stat(1) unavailable]")
		return
	end

	helpers.it("(linux-dev-mode-autoreload) restarts on a nested driver .lua, not the hotstring reload", function()
		local root = source_tree()
		local counts = settle_after_edit(root, "/modules/deep/b.lua")
		Fixture.rm_dir(root)
		helpers.assert_eq(counts.source, 1, "a saved nested .lua restarts the developer run once")
		helpers.assert_eq(counts.reload, 0, "the hotstring re-scan cannot load new code")
	end)

	for _, backend in ipairs({ "polling", "inotify" }) do
		for _, location in ipairs({ "root", "directory", "filename" }) do
			helpers.it("(source-watch-path-framing) keeps a newline in the source " .. location .. " through " .. backend, function()
				local root = source_tree()
				local edited = "/modules/deep/b.lua"
				if location == "root" then
					assert(os.rename(root, root .. "\ncheckout"))
					root = root .. "\ncheckout"
				elseif location == "directory" then
					assert(os.rename(root .. "/modules/deep", root .. "/modules/line\nbreak"))
					edited = "/modules/line\nbreak/b.lua"
				else
					assert(os.rename(root .. edited, root .. "/modules/deep/line\nbreak.lua"))
					edited = "/modules/deep/line\nbreak.lua"
				end
				local counts = settle_after_edit(root, edited, backend == "inotify")
				Fixture.rm_dir(root)
				helpers.assert_eq(counts.source, 1, "a valid POSIX path still identifies the edited source")
				helpers.assert_eq(counts.reload, 0, "a source edit never reloads the TOML catalogue")
			end)
		end
	end

	for _, refusal in ipairs({
		{ name = "failed walk with partial output", completed = false, output = "/partial\0", detail = "command exited with status 1", reason = "enumeration failed" },
		{ name = "truncated record", completed = true, output = "/partial", reason = "incomplete NUL framing" },
		{ name = "empty record", completed = true, output = "\0", reason = "empty path" },
	}) do
		helpers.it("(source-watch-path-framing) refuses " .. refusal.name .. " and retires prior watches", function()
			local root = source_tree()
			local shell = require("adapters.shell_runner")
			local query_count = 0
			local controlled = setmetatable({ exec_checked = function(command, ...)
				if command:sub(1, 5) == "find " then
					query_count = query_count + 1
					return refusal.completed, refusal.output, refusal.detail
				end
				return shell.exec_checked(command, ...)
			end }, { __index = shell })
			local watcher = helpers.load_module_with_dependency("infra.file_watchers", "adapters.shell_runner", controlled)
			local ok, err = pcall(watcher.start, { hotstrings_dir = root, source_dirs = { root },
				on_source_change = function() error("a refused census cannot reload") end })
			watcher.stop()
			assert(Fixture.native_ok and type(Fixture.native_luv.run) == "function", "native watcher retirement requires luv")
			Fixture.native_luv.run("nowait")
			local retired = watcher.stop()
			Fixture.rm_dir(root)
			helpers.assert_eq(ok, false, "an incomplete source census cannot be advertised as armed")
			helpers.assert_eq(query_count, 1, "refusal stops the census immediately")
			helpers.assert_contains(tostring(err), refusal.reason)
			helpers.assert_eq(retired, true, "watchers armed before the refusal keep their close ownership")
		end)
	end

	helpers.it("(linux-dev-mode-autoreload) ignores a saved test file", function()
		local root = source_tree()
		local counts = settle_after_edit(root, "/tests/unit/c.lua")
		Fixture.rm_dir(root)
		helpers.assert_eq(counts.source, 0, "a test edit changes nothing the daemon runs")
	end)

	helpers.it("(linux-dev-mode-autoreload) keeps a TOML edit on the hotstring reload", function()
		local root = source_tree()
		local counts = settle_after_edit(root, "/data.toml")
		Fixture.rm_dir(root)
		helpers.assert_eq(counts.source, 0)
		helpers.assert_eq(counts.reload, 1, "a hotstring file still reloads the catalogue")
	end)

	helpers.it("(linux-dev-mode-autoreload) arms no source restart outside a developer run", function()
		local root = source_tree()
		local now, reloads = 1000, 0
		local watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
		watcher.start({ now_ms = function() return now end, base_dir = root,
			on_reload = function() reloads = reloads + 1 end })
		watcher.pump()
		retime(root .. "/modules/deep/b.lua", 1700000100)
		watcher.pump()
		now = now + 1000
		watcher.pump()
		watcher.stop()
		Fixture.rm_dir(root)
		helpers.assert_eq(reloads, 0, "an installed daemon does not watch nested sources")
	end)

	helpers.it("refuses source trees without their restart callback", function()
		local watcher = helpers.load_module_with_dependency("infra.file_watchers", "luv", false)
		local ok, err = pcall(watcher.start, { base_dir = "/nonexistent", source_dirs = { "/nonexistent" } })
		watcher.stop()
		helpers.assert_eq(ok, false)
		helpers.assert_contains(tostring(err), "on_source_change")
	end)
end)
