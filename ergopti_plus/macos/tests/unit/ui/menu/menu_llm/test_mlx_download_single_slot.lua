--- tests/unit/ui/menu/menu_llm/test_mlx_download_single_slot.lua

--- ==============================================================================
--- MODULE: Regression — only one MLX download may own the shared slots
--- DESCRIPTION:
--- Every piece of download state is a single global slot: deps.active_tasks
--- ["download"] and ["download_tail"], the menubar icon, the /tmp session file
--- and the one shared progress window. pull_model was re-entrant and overwrote
--- all of them.
---
--- ROOT CAUSE ENCODED:
--- Not "the second download misbehaves" but "the first stops owning what it is
--- still using". After a second call, the first download's cancel and timeout
--- paths address the second one's tasks and session file — so a stall in the
--- first tears down the second, and the progress window narrates whichever wrote
--- last. The guard therefore has to be at ENTRY, before any slot is touched.
--- ==============================================================================

local helpers = require("tests.helpers")

local MIXIN_MODULES = {
	"adapters.task_lifecycle",
	"adapters.timer_scheduler",
	"infra.logger",
	"ui.download_window",
	"ui.menu.menu_llm.models_manager_mlx_download",
}


--- Runs one call without touching the host filesystem or shell.
--- @param callback function Scenario receiving the in-memory files and commands.
local function with_native_boundaries(callback)
	local saved_open = io.open
	local saved_execute = os.execute
	local saved_remove = os.remove
	local saved_rename = os.rename
	local files = {}
	local commands = {}
	local outcome = table.pack(xpcall(function()
		io.open = function(path, mode)
			if mode == "r" and files[path] == nil then return nil, "not found" end
			if mode == "w" then files[path] = "" end
			local handle = {}
			function handle:write(...)
				local pieces = {}
				for index = 1, select("#", ...) do
					pieces[index] = tostring(select(index, ...))
				end
				files[path] = (files[path] or "") .. table.concat(pieces)
				return self
			end
			function handle:read(kind)
				local value = files[path]
				if kind == "*l" and type(value) == "string" then
					return value:match("[^\r\n]*")
				end
				return value
			end
			function handle:close() return true end
			return handle
		end
		os.execute = function(command)
			commands[#commands + 1] = command
			if command:match("^chmod %+x /tmp/hs_mlx_dl_%d+%.sh$") then
				return true, "exit", 0
			end
			return nil, "exit", 127
		end
		os.remove = function(path)
			if files[path] == nil then return nil, "not found" end
			files[path] = nil
			return true
		end
		os.rename = function(from_path, to_path)
			if files[from_path] == nil then return nil, "not found" end
			files[to_path] = files[from_path]
			files[from_path] = nil
			return true
		end
		return callback(files, commands)
	end, debug.traceback))
	io.open = saved_open
	os.execute = saved_execute
	os.remove = saved_remove
	os.rename = saved_rename
	if not outcome[1] then error(outcome[2]) end
	return table.unpack(outcome, 2, outcome.n)
end


--- Builds the ctx/deps shape the download mixin is installed with, with the two
--- task slots observable.
--- @return table obj
--- @return table deps
--- @return table window_calls
local function install_mixin()
	return helpers.with_fresh_modules(MIXIN_MODULES, function()
		helpers.load_with_stubs("infra.logger", {
			task = { new = function(_path, _done, _stream_or_args, _args)
				local task = { running = false }
				function task:start()
					self.running = true
					return self
				end
				function task:terminate()
					self.running = false
					return self
				end
				function task:isRunning() return self.running end
				return task
			end },
		})
		local window_calls = { shows = 0, focuses = 0 }
		package.loaded["ui.download_window"] = {
			show = function()
				window_calls.shows = window_calls.shows + 1
				return true
			end,
			focus = function()
				window_calls.focuses = window_calls.focuses + 1
				return true
			end,
			update = function() return true end,
			complete = function() return true end,
		}
		local mixin = require("ui.menu.menu_llm.models_manager_mlx_download")

		local deps = {
			active_tasks             = {},
			state                    = {},
			update_icon              = function() return true end,
			save_prefs               = function() return true end,
			keymap                   = {},
			invalidate_installed_cache = function() return true end,
		}
		local obj = {}
		local install = (type(mixin) == "function") and mixin
			or (type(mixin) == "table" and (mixin.install or mixin.attach or mixin.mixin))
		helpers.assert_type(install, "function",
			"the download mixin must expose an installer this test can call")
		install({
			obj                        = obj,
			deps                       = deps,
			presets                    = {},
			project_venv_python_escaped = "/usr/bin/python3",
			invalidate_installed_cache = function() return true end,
		})
		return obj, deps, window_calls
	end)
end




-- ==================================================================
-- ==================================================================
-- ======= 1/ A second download must not steal the slots ============
-- ==================================================================
-- ==================================================================

helpers.describe("MLX download: the shared slots have exactly one owner", function()

	helpers.it("a second pull_model while one is in flight does not overwrite the task slots", function()
		local obj, deps, window_calls = install_mixin()
		helpers.assert_type(obj.pull_model, "function", "the mixin must expose pull_model")

		-- Simulate a download already owning the slot, exactly as the launcher
		-- assignment does once its task starts.
		local first = { marker = "first" }
		deps.active_tasks["download"] = first

		local ok, accepted = pcall(obj.pull_model, "SecondModel", "org/second", nil)

		helpers.assert_true(ok)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(deps.active_tasks["download"], first,
			"the in-flight download must keep owning the slot; overwriting it makes the first "
			.. "one unstoppable and points its cancel and timeout paths at the second's state")
		helpers.assert_eq(window_calls.focuses, 1,
			"the busy path must surface the already-configured progress window")
		helpers.assert_eq(window_calls.shows, 0,
			"show() requires a new operation kind and must never be used as a focus alias")
	end)

	helpers.it("a tail task alone is enough to refuse re-entry", function()
		local obj, deps = install_mixin()
		local tail = { marker = "tail" }
		deps.active_tasks["download_tail"] = tail

		pcall(obj.pull_model, "SecondModel", "org/second", nil)

		helpers.assert_eq(deps.active_tasks["download_tail"], tail,
			"the tail monitor outlives the launcher, so it alone still marks the slots as owned")
		helpers.assert_nil(deps.active_tasks["download"],
			"and no launcher slot may be claimed by the refused request")
	end)

	helpers.it("an idle manager still accepts a download", function()
		local obj, deps = install_mixin()
		helpers.assert_nil(deps.active_tasks["download"])

		-- This case exists because the two above would pass against a pull_model
		-- that never does anything at all. Its own assertion used to be
		-- assert_true(true) with that sentence — which is the same failure one
		-- level down: it certified nothing either.
		--
		-- Every native boundary is in-memory, so acceptance itself is observable:
		-- no host chmod/file error may masquerade as an entry-guard refusal.
		with_native_boundaries(function(_files, commands)
			local ok, accepted = pcall(obj.pull_model, "FirstModel", "org/first", nil)
			helpers.assert_true(ok, "the isolated idle pull must not raise")
			helpers.assert_eq(accepted, true,
				"an idle manager must commit the launcher transaction")
			helpers.assert_type(deps.active_tasks["download"], "table",
				"the accepted launcher must own the shared download slot")
			helpers.assert_eq(#commands, 1)
			helpers.assert_true(commands[1]:match("^chmod %+x ") ~= nil,
				"the only isolated shell boundary must be launcher chmod")
		end)
	end)

end)
