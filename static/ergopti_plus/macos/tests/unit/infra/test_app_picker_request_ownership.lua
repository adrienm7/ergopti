--- tests/unit/infra/test_app_picker_request_ownership.lua

--- ==============================================================================
--- MODULE: Application Picker Request Ownership Regressions
--- DESCRIPTION:
--- Proves that only the most recent Add action may publish a chooser or mutate
--- its settings destination when asynchronous discovery completions are reordered.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = {
	"infra.app_picker",
	"adapters.shell_runner",
	"adapters.file_system",
	"infra.i18n",
	"infra.logger",
	"infra.text_utils",
}

local function with_picker(run, options)
	helpers.with_fresh_modules(MODULES, function()
		local pending, choosers, native_callbacks = {}, {}, {}
		package.loaded["adapters.shell_runner"] = {
			spawn = function(_, _, on_done)
				pending[#pending + 1] = on_done
				return { start = function() return true end }
			end,
		}
		package.loaded["adapters.file_system"] = {
			directory_status = function(path)
				if path == "/Applications" or path == "/System/Applications" then
					return "present", { mode = "directory" }
				end
				return "absent"
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.text_utils"] = {
			escape_gsub_replacement = function(value) return value end,
		}
		local AppPicker = helpers.load_with_stubs("infra.app_picker", {
			application = {
				frontmostApplication = function() return nil end,
				infoForBundlePath = function() return {} end,
			},
			image = { imageFromAppBundle = function() return nil end },
			chooser = {
				new = function(callback)
					local reference = {}
					-- Native registry references outlive the visible panel and root closures
					native_callbacks[reference] = callback
					local chooser = { callback = callback, shown = 0, deleted = 0 }
					function chooser:placeholderText() return self end
					function chooser:choices() return self end
					function chooser:bgDark() return self end
					function chooser:show()
						self.shown = self.shown + 1
						if options and options.on_show then options.on_show(self) end
						return self
					end
					function chooser:delete()
						self.deleted = self.deleted + 1
						if options and options.on_delete then options.on_delete(self) end
						if options and options.delete_error_at == #choosers then error("native delete refused") end
						native_callbacks[reference] = nil
					end
					choosers[#choosers + 1] = chooser
					if options and options.on_new then options.on_new(chooser) end
					return chooser
				end,
			},
		})
		local original_getenv = os.getenv
		os.getenv = function(key)
			if key == "HOME" then return "/fixture" end
			return original_getenv(key)
		end
		local ok, failure = xpcall(function() run(AppPicker, pending, choosers, native_callbacks) end, debug.traceback)
		os.getenv = original_getenv
		if not ok then error(failure, 0) end
	end)
end

local function add_action(picker, on_change)
	local menu = picker.build_menu({}, on_change, "search")
	helpers.assert_type(menu[1] and menu[1].action, "function")
	return menu[1].action
end

helpers.describe("app_picker — discovery request ownership", function()
	helpers.it("(picker-terminal-order) cleanup reentry preserves selected change order", function()
		local start_successor, choose_successor, reentered
		with_picker(function(picker, pending, choosers, native_callbacks)
			local applied = {}
			start_successor = add_action(picker, function() applied[#applied + 1] = "B" end)
			choose_successor = function() choosers[2].callback({ text = "B", appPath = "/Applications/B.app" }) end
			add_action(picker, function() applied[#applied + 1] = "A" end)()
			pending[1](0, "/Applications/A.app\0")
			choosers[1].callback({ text = "A", appPath = "/Applications/A.app" })
			helpers.assert_eq(applied, { "A", "B" })
			helpers.assert_eq(choosers[1].deleted, 1)
			helpers.assert_eq(choosers[2].deleted, 1)
			helpers.assert_eq(next(native_callbacks), nil)
		end, { on_delete = function()
			if reentered then return end
			reentered = true
			start_successor()
			choose_successor()
		end })
	end)

	for _, outcome in ipairs({ "cancel", "select" }) do
		helpers.it("(picker-terminal-debt) retries failed cleanup after " .. outcome, function()
			local refused = false
			with_picker(function(picker, pending, choosers, native_callbacks)
				local applied = 0
				local start = add_action(picker, function() applied = applied + 1 end)
				start()
				pending[1](0, "/Applications/A.app\0")
				local observer = setmetatable({ choosers[1] }, { __mode = "v" })
				local choice = outcome == "select" and { text = "A", appPath = "/Applications/A.app" } or nil
				choosers[1].callback(choice)
				helpers.assert_not_nil(next(native_callbacks), "refused native cleanup leaves a real registry root")
				choosers[1].callback(choice)
				helpers.assert_eq(applied, outcome == "cancel" and 0 or 1, "a retained callback must already be inert")
				start()
				helpers.assert_eq(choosers[1].deleted, 2)
				helpers.assert_eq(choosers[2].deleted, 0)
				choosers[1] = nil
				collectgarbage("collect")
				helpers.assert_nil(observer[1])
				choosers[2].callback(nil)
				helpers.assert_eq(next(native_callbacks), nil)
			end, { on_delete = function()
				if refused then return end
				refused = true
				error("injected terminal deletion refusal")
			end })
		end)
	end

	for _, outcome in ipairs({ "cancel", "select", "throw" }) do
		helpers.it("(picker-terminal-release) releases native callback after " .. outcome, function()
			with_picker(function(picker, pending, choosers, native_callbacks)
				local applied = 0
				add_action(picker, function()
					applied = applied + 1
					if outcome == "throw" then error("injected settings failure") end
				end)()
				pending[1](0, "/Applications/A.app\0")
				local observer = setmetatable({ choosers[1] }, { __mode = "v" })
				local choice = outcome ~= "cancel" and { text = "A", appPath = "/Applications/A.app" } or nil
				local ok, failure = pcall(choosers[1].callback, choice)
				if outcome == "throw" then
					helpers.assert_eq(ok, false)
					helpers.assert_true(tostring(failure):find("injected settings failure", 1, true) ~= nil)
				else
					helpers.assert_eq(ok, true)
					helpers.assert_eq(failure, nil)
				end
				helpers.assert_eq(applied, outcome == "cancel" and 0 or 1)
				helpers.assert_eq(choosers[1].deleted, 1)
				helpers.assert_eq(next(native_callbacks), nil, "completion must release the registry root")
				choosers[1] = nil
				collectgarbage("collect")
				helpers.assert_nil(observer[1], "a completed callback must not root its native owner")
			end)
		end)
	end

	helpers.it("(picker-cleanup-stale) retries a failed stale candidate without deleting its successor", function()
		local start_successor, reentered, stale
		with_picker(function(picker, pending, choosers)
			local applied = 0
			local start = add_action(picker, function() applied = applied + 1 end)
			start_successor = start
			start()
			pending[1](0, "/Applications/A.app\0")
			helpers.assert_eq(#choosers, 2)
			helpers.assert_eq(choosers[1].deleted, 1)
			helpers.assert_eq(choosers[2].deleted, 0)
			start()
			helpers.assert_eq(choosers[1].deleted, 2, "detached stale candidates must also be retried")
			helpers.assert_eq(choosers[2].deleted, 1)
			helpers.assert_eq(choosers[3].deleted, 0)
			choosers[1].callback({ text = "A", appPath = "/Applications/A.app" })
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(applied, 0)
			choosers[3].callback({ text = "C", appPath = "/Applications/C.app" })
			helpers.assert_eq(applied, 1)
		end, {
			on_new = function(owner)
				if reentered then return end
				reentered, stale = true, owner
				start_successor()
			end,
			on_delete = function(owner)
				if owner == stale and owner.deleted == 1 then error("injected stale deletion refusal") end
			end,
		})
	end)

	helpers.it("(picker-cleanup-retry-reentry) nested retry never deletes its inflight owner twice", function()
		local start_successor, reentered
		with_picker(function(picker, pending, choosers)
			local applied = 0
			local start = add_action(picker, function() applied = applied + 1 end)
			start_successor = start
			start()
			pending[1](0, "/Applications/A.app\0")
			start()
			helpers.assert_eq(#choosers, 1)
			start()
			helpers.assert_eq(#choosers, 2)
			helpers.assert_eq(choosers[1].deleted, 2)
			helpers.assert_eq(choosers[2].deleted, 0)
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(applied, 1)
		end, { on_delete = function(owner)
			if owner.deleted == 1 then error("injected first deletion refusal") end
			if reentered then return end
			reentered = true
			start_successor()
		end })
	end)

	helpers.it("(picker-cleanup-reentry) deleting an old chooser cannot retire its successor", function()
		local start_successor, reentered
		with_picker(function(picker, pending, choosers)
			local applied = 0
			local start = add_action(picker, function() applied = applied + 1 end)
			start_successor = start
			start()
			pending[1](0, "/Applications/A.app\0")
			start()
			helpers.assert_eq(#choosers, 2)
			helpers.assert_eq(choosers[1].deleted, 1, "native teardown must not recursively delete the same owner")
			helpers.assert_eq(choosers[2].deleted, 0)
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(applied, 1)
		end, { on_delete = function()
			if reentered then return end
			reentered = true
			start_successor()
		end })
	end)

	helpers.it("(picker-cleanup-release) failed deletion is retried and releases its exact owner", function()
		with_picker(function(picker, pending, choosers)
			local start = add_action(picker, function() end)
			start()
			pending[1](0, "/Applications/A.app\0")
			local observer = setmetatable({ choosers[1] }, { __mode = "v" })
			start()
			helpers.assert_eq(#choosers, 1, "refused cleanup must block publication")
			choosers[1] = nil
			collectgarbage("collect")
			helpers.assert_not_nil(observer[1], "debt must retain its retry capability")
			start()
			helpers.assert_eq(observer[1].deleted, 2)
			helpers.assert_eq(#choosers, 1, "retry must create only the new owner")
			collectgarbage("collect")
			helpers.assert_nil(observer[1], "successful cleanup must release the retained owner")
		end, { on_delete = function(owner)
			if owner.deleted == 1 then error("injected first deletion refusal") end
		end })
	end)

	for _, newer_exit in ipairs({ 0, 1 }) do
		helpers.it("(picker-cache-generation) obsolete scans cannot publish after newer exit " .. newer_exit, function()
			with_picker(function(picker, pending)
				local first, second, second_success, cached
				picker.discover_apps(function(choices) first = choices end)
				picker.discover_apps(function(choices, success) second, second_success = choices, success end)
				pending[2](newer_exit, "/Applications/New.app\0")
				pending[1](0, "/Applications/Old.app\0")
				helpers.assert_eq(first[1].text, "Old", "each caller still receives its own successful scan")
				helpers.assert_eq(second_success, newer_exit == 0)
				if newer_exit == 0 then helpers.assert_eq(#second, 1) else helpers.assert_nil(second) end
				picker.discover_apps(function(choices) cached = choices end)
				if newer_exit == 0 then
					helpers.assert_eq(#pending, 2)
					helpers.assert_eq(cached[1].text, "New")
				else
					helpers.assert_eq(#pending, 3, "a newer failed scan must remain retryable")
					helpers.assert_eq(cached, nil)
					pending[3](0, "/Applications/Recovered.app\0")
					helpers.assert_eq(cached[1].text, "Recovered")
				end
			end)
		end)
	end

	helpers.it("(hs-268-partial-cache) failed discovery never publishes partial stdout", function()
		with_picker(function(picker, pending)
			local first, second, third
			picker.discover_apps(function(choices) first = choices end)
			pending[1](1, "/Applications/Partial.app\0")
			helpers.assert_nil(first)
			picker.discover_apps(function(choices) second = choices end)
			helpers.assert_eq(#pending, 2, "failure must leave discovery retryable")
			pending[2](0, "/Applications/Recovered.app\0")
			helpers.assert_eq(#second, 1)
			picker.discover_apps(function(choices) third = choices end)
			helpers.assert_eq(#pending, 2, "only a confirmed success may warm the cache")
			helpers.assert_eq(#third, 1)
		end)
	end)

	helpers.it("(hs-267-out-of-order) only the newest completion presents and applies", function()
		with_picker(function(picker, pending, choosers)
			local applied = {}
			add_action(picker, function() applied[#applied + 1] = "A" end)()
			add_action(picker, function() applied[#applied + 1] = "B" end)()
			helpers.assert_eq(#pending, 2)
			pending[2](0, "/Applications/B.app\0")
			pending[1](0, "/Applications/A.app\0")
			helpers.assert_eq(#choosers, 1,
				"the stale A result must not delete B or create an obsolete chooser")
			choosers[1].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(#applied, 1)
			helpers.assert_eq(applied[1], "B")
		end)
	end)

	helpers.it("(hs-267-reversed) an old completion cannot present before the newest one", function()
		with_picker(function(picker, pending, choosers)
			add_action(picker, function() end)()
			add_action(picker, function() end)()
			pending[1](0, "/Applications/A.app\0")
			helpers.assert_eq(#choosers, 0)
			pending[2](0, "/Applications/B.app\0")
			helpers.assert_eq(#choosers, 1)
		end)
	end)

	helpers.it("(hs-267-retired-callback) cancellation and duplicate callbacks are inert", function()
		with_picker(function(picker, pending, choosers)
			local applied = 0
			add_action(picker, function() applied = applied + 1 end)()
			pending[1](0, "/Applications/A.app\0")
			choosers[1].callback(nil)
			choosers[1].callback({ text = "A", appPath = "/Applications/A.app" })
			helpers.assert_eq(applied, 0, "a cancelled owner must not be revived by a queued callback")

			add_action(picker, function() applied = applied + 1 end)()
			helpers.assert_eq(#choosers, 2,
				"the warm cache may complete synchronously but must still create a fresh owner")
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(applied, 1, "selection must settle its exact request at most once")
		end)
	end)

	helpers.it("(hs-267-cleanup-debt) refused stale cleanup cannot destroy a newer request", function()
		with_picker(function(picker, pending, choosers)
			local applied = 0
			add_action(picker, function() applied = applied + 1 end)()
			pending[1](0, "/Applications/A.app\0")
			add_action(picker, function() applied = applied + 1 end)()
			helpers.assert_eq(#choosers, 1,
				"a cleanup refusal must retain its exact owner instead of publishing a half-owned successor")
			choosers[1].callback({ text = "A", appPath = "/Applications/A.app" })
			helpers.assert_eq(applied, 0, "the retained stale chooser must no longer own settings")
		end, { delete_error_at = 1 })
	end)

	helpers.it("(hs-267-reentrant-show) a request superseded from show cannot publish its candidate", function()
		local start_b
		local reentered = false
		with_picker(function(picker, pending, choosers)
			local applied = {}
			local start_a = add_action(picker, function() applied[#applied + 1] = "A" end)
			start_b = add_action(picker, function() applied[#applied + 1] = "B" end)
			start_a()
			pending[1](0, "/Applications/A.app\0")
			helpers.assert_eq(#choosers, 2,
				"the reentrant latest request must publish exactly one successor chooser")
			helpers.assert_eq(choosers[1].deleted, 1,
				"resuming the old show continuation must not delete its retired owner twice")
			choosers[2].callback({ text = "B", appPath = "/Applications/B.app" })
			helpers.assert_eq(applied[1], "B")
			helpers.assert_nil(applied[2])
		end, { on_show = function()
			if reentered then return end
			reentered = true
			start_b()
		end })
	end)
end)

-- The focused helper restores its captured package entry after each case. Keep
-- the explicit terminal assignment as a suite-order fence for source scanners.
package.loaded["adapters.shell_runner"] = nil
