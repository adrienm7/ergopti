--- tests/unit/lib/test_file_watchers_adaptive_settle.lua

--- ==============================================================================
--- MODULE: infra/file_watchers adaptive quiescence for bulk writes
--- DESCRIPTION:
--- The git guard only covers git; a OneDrive / Dropbox / rsync sync (or any bulk
--- write) leaves no lock and would still let the watcher reload mid-operation.
--- The source-agnostic defence is quiescence: a burst of MANY distinct files is
--- held until file activity has been quiet for the long bulk-settle window, while
--- a lone edit still reloads after the short edit window.
---
--- This fires a many-file batch through the project watcher and, stepping the
--- clock, asserts it is STILL held at the edit-settle window and reloads exactly
--- once at the bulk-settle window — with git idle throughout, so only the
--- quiescence policy is under test. It fails against a watcher that reloads on
--- the short debounce regardless of how many files changed.
--- ==============================================================================

local helpers = require("tests.helpers")

package.loaded["infra.ui_restore"] = {
	defer_reload = function(fn) if type(fn) == "function" then fn() end end,
	snapshot     = function() end,
	restore      = function() end,
}
-- git idle throughout: isolate the source-agnostic quiescence hold from the git gate.
package.loaded["infra.git_status"] = { operation_in_progress = function() return false end }

package.loaded["infra.file_watchers"] = nil
local FW          = require("infra.file_watchers")
local reload_gate = require("reload_gate")

helpers.describe("infra/file_watchers — adaptive quiescence for bulk writes (macos-reload-during-git-pull)", function()
	helpers.it("holds a many-file burst until the bulk settle, not the lone-edit settle", function()
		local prev_pw, prev_timer, prev_attr, prev_reload =
			hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload

		local clock       = 0
		local watch_cbs   = {}
		local captured_fn = nil
		local reloads     = 0

		hs.pathwatcher = { new = function(_path, cb)
			watch_cbs[#watch_cbs + 1] = cb
			local watcher = {}
			function watcher:start() return self end
			function watcher:stop() return nil end
			return watcher
		end }
		hs.timer = {
			doAfter = function(_s, fn) captured_fn = fn; return { stop = function() end } end,
			secondsSinceEpoch = function() return clock end,
		}
		hs.fs.attributes = function(_p) return nil end
		hs.reload = function() reloads = reloads + 1 end

		_G.script_watchers = nil
		FW.start({
			hotstrings_dir = "/fake/hotstrings/",
			base_dir = "/fake/base/",
			personal_hotstrings_dir = "/fake/personal",
		})

		-- A bulk write lands: many distinct .lua files in one FSEvents batch.
		clock = 1000
		local batch = {}
		for i = 1, reload_gate.BULK_THRESHOLD + 5 do batch[i] = "/fake/base/m" .. i .. ".lua" end
		for _, cb in ipairs(watch_cbs) do pcall(cb, batch) end
		helpers.assert_true(type(captured_fn) == "function", "the bulk change must arm a settle poll")

		-- At the lone-edit settle window the bulk burst must STILL be held.
		clock = 1000 + reload_gate.EDIT_SETTLE_SEC
		local fn = captured_fn
		captured_fn = nil
		fn()
		helpers.assert_true(reloads == 0, "a bulk burst must NOT reload after only the edit settle window")
		helpers.assert_true(type(captured_fn) == "function", "it must keep polling until the bulk window")

		-- Once the bulk-settle window of quiet has elapsed, it reloads exactly once.
		clock = 1000 + reload_gate.BULK_SETTLE_SEC
		fn = captured_fn
		captured_fn = nil
		fn()
		helpers.assert_true(reloads == 1, "the bulk write reloads once settled (got " .. reloads .. ")")

		hs.pathwatcher, hs.timer, hs.fs.attributes, hs.reload =
			prev_pw, prev_timer, prev_attr, prev_reload
		_G.script_watchers = nil
	end)
end)
