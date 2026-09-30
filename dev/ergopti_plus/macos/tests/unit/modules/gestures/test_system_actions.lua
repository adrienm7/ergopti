--- tests/unit/modules/gestures/test_system_actions.lua

--- ==============================================================================
--- MODULE: System actions run their exact native command (macOS)
--- DESCRIPTION:
--- Runs every action of modules/gestures/system_actions against a recording
--- process owner and asserts the exact program and argument vector each one
--- starts, the parent it starts under, and what each completion does next.
---
--- ROOT CAUSES ENCODED:
--- 1. The approved system actions did not exist: a binding could not sleep the
---    displays, empty the trash or act on the Finder selection.
--- 2. Each one must be an owned asynchronous process: a synchronous
---    hs.execute would park the runloop that feeds the keyboard tap.
--- 3. The Finder selection must reach xattr and chmod as exact argv entries,
---    and an unreadable or empty selection must start nothing.
--- 4. A confirmed force quit read the frontmost application after its alert,
---    which had brought the driver to the front: it refused instead of killing
---    the application the user acted from, a hung one or one with no window
---    included. It now kills the application read before the question.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED = {
	"modules.gestures.system_actions",
	"modules.gestures.actions_aux_owner",
	"adapters.clipboard",
	"adapters.mouse_control",
	"adapters.file_system",
	"adapters.tcc_grant",
	"adapters.window_info",
	"infra.notifications",
	"infra.i18n",
	"infra.logger",
}

local PARENT = "shortcut_bindings"
local OWN_BUNDLE = "com.ergoptiplus.app"

--- Loads the module over recording doubles and hands both to `body`.
--- @param body function fn(System, record)
--- @param options table|nil { frame, create_statuses, running = { [pid] = bundle id } }
local function with_system(body, options)
	options = options or {}
	helpers.with_fresh_modules(OWNED, function()
		local record = { runs = {}, notices = {}, cleared = {}, moved = {}, created = {} }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.notifications"] = {
			notify = function(message, body_text, kind)
				record.notices[#record.notices + 1] = { message = message, body = body_text, kind = kind }
				return true
			end,
		}
		package.loaded["modules.gestures.actions_aux_owner"] = {
			run = function(executable, args, label, callback, parent)
				record.runs[#record.runs + 1] = {
					executable = executable, args = args, label = label,
					callback = callback, parent = parent,
				}
				return true
			end,
		}
		package.loaded["adapters.clipboard"] = {
			restore = function(saved)
				record.cleared[#record.cleared + 1] = saved == nil
				return true
			end,
		}
		package.loaded["adapters.mouse_control"] = {
			screen_frame_under_cursor = function() return options.frame end,
			setPos = function(x, y)
				record.moved[#record.moved + 1] = { x = x, y = y }
				return true
			end,
		}
		local statuses = options.create_statuses or { "created" }
		package.loaded["adapters.file_system"] = {
			create_if_absent = function(path, content)
				record.created[#record.created + 1] = { path = path, content = content }
				local status = statuses[#record.created] or "created"
				return status == "created", status, nil
			end,
		}
		package.loaded["adapters.tcc_grant"] = { bundle_id = function() return OWN_BUNDLE end }
		local running = options.running or {}
		package.loaded["adapters.window_info"] = {
			application_bundle_id = function(pid) return running[pid] end,
		}
		local System = require("modules.gestures.system_actions")
		body(System, record)
	end)
end

--- Asserts one recorded run.
--- @param run table|nil
--- @param executable string
--- @param args table
local function assert_run(run, executable, args)
	helpers.assert_true(run ~= nil, "a process must have been started")
	helpers.assert_eq(run.executable, executable)
	helpers.assert_eq(run.args, args)
	helpers.assert_eq(run.parent, PARENT, "the process runs under the dispatching parent")
end

--- Completes one recorded run as the process would.
--- @param run table
--- @param ok boolean
--- @param out string|nil
local function complete(run, ok, out)
	run.callback(ok, out, ok and "" or "failure")
end

helpers.describe("macOS system actions start their exact native command", function()
	helpers.it("sleep_displays runs pmset displaysleepnow", function()
		with_system(function(System, record)
			helpers.assert_eq(System.sleep_displays(PARENT), true)
			assert_run(record.runs[1], "/usr/bin/pmset", { "displaysleepnow" })
			helpers.assert_eq(#record.runs, 1)
		end)
	end)

	helpers.it("toggle_dark_mode flips the System Events appearance", function()
		with_system(function(System, record)
			System.toggle_dark_mode(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript", { "-e", System.SCRIPTS.toggle_dark_mode })
			helpers.assert_contains(System.SCRIPTS.toggle_dark_mode, "set dark mode to not dark mode")
		end)
	end)

	helpers.it("empty_trash asks Finder to empty its trash", function()
		with_system(function(System, record)
			System.empty_trash(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript",
				{ "-e", 'tell application "Finder" to empty trash' })
		end)
	end)

	helpers.it("minimize_all minimizes every window of every visible app", function()
		with_system(function(System, record)
			System.minimize_all(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript", { "-e", System.SCRIPTS.minimize_all })
			helpers.assert_contains(System.SCRIPTS.minimize_all, 'set value of attribute "AXMinimized"')
			helpers.assert_contains(System.SCRIPTS.minimize_all, "whose visible is true")
		end)
	end)

	helpers.it("eject_all_disks ejects through Finder and says when nothing was ejectable", function()
		with_system(function(System, record)
			System.eject_all_disks(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript", { "-e", System.SCRIPTS.eject_all_disks })
			helpers.assert_contains(System.SCRIPTS.eject_all_disks, "every disk whose ejectable is true")
			complete(record.runs[1], true, "2")
			helpers.assert_eq(#record.notices, 0, "ejected disks need no notice")
			System.eject_all_disks(PARENT)
			complete(record.runs[2], true, "0")
			helpers.assert_eq(record.notices[1].message, "system_actions.no_disk_to_eject")
		end)
	end)

	helpers.it("quit_frontmost_app quits the frontmost bundle, never the driver itself", function()
		with_system(function(System, record)
			System.quit_frontmost_app(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript",
				{ "-e", string.format(System.SCRIPTS.frontmost_process, OWN_BUNDLE) })
			complete(record.runs[1], true, "812 com.apple.Safari")
			assert_run(record.runs[2], "/usr/bin/osascript",
				{ "-e", 'tell application id "com.apple.Safari" to quit' })

			System.quit_frontmost_app(PARENT)
			complete(record.runs[3], true, "self")
			helpers.assert_eq(#record.runs, 3, "the driver itself is never quit")
		end)
	end)

	-- With the desktop clicked, Finder is frontmost: quitting it removed the
	-- desktop until it was relaunched, which Cmd+Q deliberately cannot do.
	helpers.it("quit and force quit refuse the desktop shell", function()
		with_system(function(System, record)
			local runs = 0
			for _, front in ipairs({ "301 com.apple.finder", "302 com.apple.dock", "303 com.apple.loginwindow" }) do
				System.quit_frontmost_app(PARENT)
				runs = runs + 1
				complete(record.runs[runs], true, front)
				System.force_quit_frontmost(PARENT)
				runs = runs + 1
				complete(record.runs[runs], true, front)
				helpers.assert_eq(#record.runs, runs, front .. " is neither quit nor killed")
			end
		end)
	end)

	helpers.it("force_quit_frontmost sends SIGKILL to the frontmost process", function()
		with_system(function(System, record)
			System.force_quit_frontmost(PARENT)
			complete(record.runs[1], true, "4242 com.apple.TextEdit")
			assert_run(record.runs[2], "/bin/kill", { "-KILL", "4242" })
			System.force_quit_frontmost(PARENT)
			complete(record.runs[3], true, "not a pid")
			helpers.assert_eq(#record.runs, 3, "an unreadable answer kills nothing")
		end)
	end)

	-- The confirmation's alert brings the driver to the front, so a confirmed
	-- force quit that read the frontmost application then found itself.
	helpers.it("a confirmed force quit kills the application read before its question (force-quit-acted-from)",
		function()
			with_system(function(System, record)
				helpers.assert_eq(System.force_quit_frontmost(PARENT,
					{ pid = 4242, bundle_id = "com.apple.Safari" }), true)
				assert_run(record.runs[1], "/bin/kill", { "-KILL", "4242" })
				helpers.assert_eq(#record.runs, 1, "the frontmost application is not read again after the question")
			end, { running = { [4242] = "com.apple.Safari" } })
		end)

	helpers.it("a confirmed force quit refuses the driver, the shell and a pid that changed (force-quit-acted-from)",
		function()
			local running = {
				[500] = OWN_BUNDLE, [301] = "com.apple.finder", [302] = "com.apple.dock",
				[303] = "com.apple.loginwindow", [812] = "com.apple.TextEdit",
			}
			with_system(function(System, record)
				local refused = {
					{ pid = 500, bundle_id = OWN_BUNDLE },
					{ pid = 301, bundle_id = "com.apple.finder" },
					{ pid = 302, bundle_id = "com.apple.dock" },
					{ pid = 303, bundle_id = "com.apple.loginwindow" },
					-- Quit while the question was shown: nothing runs under its pid.
					{ pid = 4242, bundle_id = "com.apple.Safari" },
					-- The pid now names another application.
					{ pid = 812, bundle_id = "com.apple.Safari" },
					{ pid = 1, bundle_id = "com.apple.Safari" },
					{ pid = "4242", bundle_id = "com.apple.Safari" },
				}
				for _, acted_from in ipairs(refused) do
					helpers.assert_eq(System.force_quit_frontmost(PARENT, acted_from), false,
						tostring(acted_from.bundle_id) .. " " .. tostring(acted_from.pid) .. " is refused")
				end
				helpers.assert_eq(#record.runs, 0, "nothing is killed and nothing is read instead")
			end, { running = running })
		end)

	helpers.it("open_app opens by bundle identifier or by name", function()
		with_system(function(System, record)
			helpers.assert_eq(System.open_app("com.apple.Safari", PARENT), true)
			assert_run(record.runs[1], "/usr/bin/open", { "-b", "com.apple.Safari" })
			System.open_app("/Applications/Visual Studio Code.app", PARENT)
			assert_run(record.runs[2], "/usr/bin/open", { "-a", "/Applications/Visual Studio Code.app" })
			helpers.assert_eq(System.open_app(" Safari", PARENT), false)
			helpers.assert_eq(#record.runs, 2, "an invalid application opens nothing")
		end)
	end)

	helpers.it("clear_clipboard drops every pasteboard type", function()
		with_system(function(System, record)
			helpers.assert_eq(System.clear_clipboard(), true)
			helpers.assert_eq(record.cleared, { true })
		end)
	end)

	helpers.it("center_mouse moves the pointer to the centre of its screen", function()
		with_system(function(System, record)
			helpers.assert_eq(System.center_mouse(), true)
			helpers.assert_eq(record.moved, { { x = 500, y = 350 } })
		end, { frame = { x = 100, y = 50, w = 800, h = 600 } })
		with_system(function(System, record)
			helpers.assert_eq(System.center_mouse(), false)
			helpers.assert_eq(#record.moved, 0)
		end)
	end)

	helpers.it("mic_mute_toggle mutes, then restores the level it had", function()
		with_system(function(System, record)
			System.mic_mute_toggle(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript",
				{ "-e", string.format(System.SCRIPTS.mic_toggle, System.MIC_DEFAULT_RESTORE_LEVEL) })
			complete(record.runs[1], true, "muted 70")
			System.mic_mute_toggle(PARENT)
			assert_run(record.runs[2], "/usr/bin/osascript",
				{ "-e", string.format(System.SCRIPTS.mic_toggle, 70) })
			helpers.assert_contains(record.runs[2].args[2], "set volume input volume 70")
		end)
	end)
end)

helpers.describe("macOS Finder selection actions", function()
	helpers.it("remove_quarantine_selection strips the attribute from each selected path", function()
		with_system(function(System, record)
			System.remove_quarantine_selection(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript", { "-ss", "-e", System.SCRIPTS.finder_selection })
			complete(record.runs[1], true, '{"/Users/ana/Downloads/tool.app/", "/Users/ana/a \\"b\\".pkg"}')
			assert_run(record.runs[2], "/usr/bin/xattr", {
				"-r", "-d", "com.apple.quarantine",
				"/Users/ana/Downloads/tool.app/", '/Users/ana/a "b".pkg',
			})
		end)
	end)

	helpers.it("an empty or unreadable selection starts nothing", function()
		with_system(function(System, record)
			System.remove_quarantine_selection(PARENT)
			complete(record.runs[1], true, "{}")
			helpers.assert_eq(#record.runs, 1)
			helpers.assert_eq(record.notices[1].message, "system_actions.no_file_selected")
			System.make_executable_selection(PARENT)
			complete(record.runs[2], true, "/Users/ana/one\n/Users/ana/two")
			helpers.assert_eq(#record.runs, 2, "a line-based report is refused, not split")
		end)
	end)

	helpers.it("make_executable_selection runs chmod +x on the selected paths", function()
		with_system(function(System, record)
			System.make_executable_selection(PARENT)
			complete(record.runs[1], true, '{"/Users/ana/run.sh"}')
			assert_run(record.runs[2], "/bin/chmod", { "+x", "/Users/ana/run.sh" })
		end)
	end)

	helpers.it("open_terminal_here opens Terminal in the Finder folder", function()
		with_system(function(System, record)
			System.open_terminal_here(PARENT)
			assert_run(record.runs[1], "/usr/bin/osascript", { "-ss", "-e", System.SCRIPTS.finder_folder })
			complete(record.runs[1], true, '{"/Users/ana/Projects/"}')
			assert_run(record.runs[2], "/usr/bin/open", { "-a", "Terminal", "/Users/ana/Projects/" })
		end)
	end)

	helpers.it("new_text_file_here creates a free name and reveals it", function()
		with_system(function(System, record)
			System.new_text_file_here(PARENT)
			complete(record.runs[1], true, '{"/Users/ana/Desktop/"}')
			helpers.assert_eq(record.created[1].path, "/Users/ana/Desktop/system_actions.new_text_file_name.txt")
			helpers.assert_eq(record.created[2].path, "/Users/ana/Desktop/system_actions.new_text_file_name 2.txt")
			helpers.assert_eq(record.created[2].content, "")
			assert_run(record.runs[2], "/usr/bin/open",
				{ "-R", "/Users/ana/Desktop/system_actions.new_text_file_name 2.txt" })
		end, { create_statuses = { "exists", "created" } })
	end)

	helpers.it("new_text_file_here stops on a creation error", function()
		with_system(function(System, record)
			System.new_text_file_here(PARENT)
			complete(record.runs[1], true, '{"/Users/ana/Desktop/"}')
			helpers.assert_eq(#record.created, 1)
			helpers.assert_eq(#record.runs, 1, "nothing is revealed when nothing was created")
		end, { create_statuses = { "error" } })
	end)
end)
