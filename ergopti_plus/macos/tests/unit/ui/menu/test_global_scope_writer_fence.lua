--- tests/unit/ui/menu/test_global_scope_writer_fence.lua

--- ==============================================================================
--- MODULE: Global Scope Under The Writer Fence (macOS)
--- DESCRIPTION:
--- Composes real scoped-preference owners through the global restore, admitted
--- by the real global writer fence. A category that refuses leaving debt keeps
--- the fence for itself; the composition's rollback settles that debt, and the
--- fence must then admit the other categories' reverts and every later writer.
--- A debt that cannot be settled keeps everything refused.
--- ==============================================================================

local helpers = require("tests.helpers")

--- The real writer fence over quiescent terminal owners.
--- @return table fence run_exclusive, is_pending
local function writer_fence()
	local function unused() error("unrelated owner must not run") end
	return require("ui.menu.global_actions_transaction").create({
		state = {}, capture_preferences = unused, sync_runtime = unused, restore_state = unused,
		settings = { get = unused, set = unused, get_keys = unused },
		file_mover = { capture = unused, move = unused, restore = unused },
		reset_journal = { prepare = unused, mark_commit = unused, mark_prepared = unused, clear = unused },
		gestures = { get_action = unused, set_action = unused, enable_all = unused, disable_all = unused },
		shortcuts = { set_shortcut_action = unused, get_keyboard_action = unused, set_keyboard_action = unused,
			get_keyboard_assignments = unused },
		karabiner = { snapshot_settings = unused, reset_to_defaults = unused, restore_settings = unused },
		request_reload = unused, terminal_pending = function() return false end,
	})
end

--- Two scoped owners, each over its own in-memory config file, admitted by one fence.
--- @return table fixture
local function fixture()
	local sources = { layout = "[layout]\npause_switch_enabled = true\n", llm = "[llm]\nollama_port = 1234\n" }
	local files, controls = {}, { refuse_publish = {}, refuse_restore = {} }
	for name, content in pairs(sources) do files[name] = content end
	local adapter = {
		read_with_status = function(path) return files[path], files[path] and "ok" or "absent" end,
		write = function() error("conditional publication is required") end,
		write_if_unchanged = function(path, content, expected)
			if controls.refuse_publish[path] then
				controls.refuse_publish[path] = controls.refuse_publish[path] - 1
				if controls.refuse_publish[path] == 0 then controls.refuse_publish[path] = nil end
				return false
			end
			if expected.status == "ok" and expected.content ~= files[path] then return false end
			if expected.status == "absent" and files[path] ~= nil then return false end
			files[path] = content
			return true
		end,
	}
	local preferences = {
		source_snapshot = function(path) return { status = files[path] and "ok" or "absent", content = files[path] } end,
		replace_source = function() return true end,
	}
	local checkpoint = {
		capture = function() return {} end,
		replace = function() return true, {} end,
		restore = function() return true end,
	}
	local fence = writer_fence()
	local generation = 0
	local function owner(scope, path)
		return require("ui.menu.scoped_preferences").new({
			scope = scope, path = path, files = adapter, state = {}, preferences = preferences, checkpoint = checkpoint,
			capture_preferences = function() return {} end,
			backup_path = function() generation = generation + 1; return path .. "-backup-" .. generation end,
			admission = fence.run_exclusive,
			paused = function() return false end,
			runtime = {
				capture = function() return {} end,
				apply = function() return true end,
				restore = function()
					if controls.refuse_restore[path] then
						controls.refuse_restore[path] = controls.refuse_restore[path] - 1
						if controls.refuse_restore[path] == 0 then controls.refuse_restore[path] = nil end
						return false
					end
					return true
				end,
			},
		})
	end
	local owners = { keyboard_layout = owner("keyboard_layout", "layout"), llm = owner("llm", "llm") }
	local refreshes = {}
	package.loaded["ui.menu.global_scope"] = nil
	local global = require("ui.menu.global_scope").new({
		owners = {
			keyboard_layout = function() return owners.keyboard_layout end,
			llm = function() return owners.llm end,
		},
		backup_path = function(scope) return "remap-" .. scope end,
		defer = function(continuation) continuation(); return true end,
		paused = function() return false end,
		refresh = function(committed, report) refreshes[#refreshes + 1] = { committed, report } end,
	})
	return { global = global, fence = fence, owners = owners, files = files, sources = sources,
		controls = controls, refreshes = refreshes }
end

helpers.describe("macOS global scope under the writer fence", function()
	helpers.it("settles a refused category's debt through the fence, then reverts the others", function()
		local f = fixture()
		-- The IA publication is refused and its first runtime restore too: it
		-- leaves debt, which keeps the fence for that owner alone.
		f.controls.refuse_publish.llm, f.controls.refuse_restore.llm = 1, 1
		helpers.assert_eq(f.global.apply("clear"), true)
		helpers.assert_eq(#f.refreshes, 1)
		local committed, report = f.refreshes[1][1], f.refreshes[1][2]
		helpers.assert_eq(committed, false)
		helpers.assert_eq(report.failed, "llm")
		helpers.assert_eq(report.reverted, true, "the committed layout category is reverted")
		helpers.assert_eq(f.files.layout, f.sources.layout)
		helpers.assert_eq(f.files.llm, f.sources.llm)
		helpers.assert_eq(f.owners.llm.pending(), false)
		helpers.assert_eq(f.fence.is_pending(), false, "a settled debt releases the writer fence")
		helpers.assert_eq(f.fence.run_exclusive("Preference save", function() return true end), true,
			"an ordinary save is admitted again")
		helpers.assert_eq(f.global.apply("recommended"), true)
		helpers.assert_eq(f.refreshes[2][1], true, "a second global restore runs")
	end)

	helpers.it("keeps every writer refused while the debt cannot be settled", function()
		local f = fixture()
		f.controls.refuse_publish.llm, f.controls.refuse_restore.llm = 1, 2
		helpers.assert_eq(f.global.apply("clear"), true)
		local report = f.refreshes[1][2]
		helpers.assert_eq(report.reverted, false, "an unsettled inverse stays owed")
		helpers.assert_eq(f.owners.llm.pending(), true)
		helpers.assert_eq(f.fence.run_exclusive("Preference save", function() error("must not run") end), false)
		helpers.assert_eq(f.owners.keyboard_layout.apply("recommended"), false, "another owner waits")
		helpers.assert_eq(f.owners.llm.retry_restore(), true, "the owed inverse settles on retry")
		helpers.assert_eq(f.files.llm, f.sources.llm)
		helpers.assert_eq(f.fence.is_pending(), false)
		helpers.assert_eq(f.fence.run_exclusive("Preference save", function() return true end), true)
	end)
end)
