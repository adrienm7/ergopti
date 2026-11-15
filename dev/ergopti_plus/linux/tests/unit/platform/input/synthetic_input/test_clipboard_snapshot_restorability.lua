-- static/ergopti_plus/linux/tests/unit/platform/input/synthetic_input/test_clipboard_snapshot_restorability.lua
--- Real clipboard/ShellRunner composition with a private in-memory transport.
local helpers = require("tests.helpers")
local REPLACEMENT = "EP79_PRIVATE_REPLACEMENT_CANARY"
local SELECTED = "EP79_PRIVATE_SELECTED_CANARY"
local URI = "file:///owned/EP79_PRIVATE_URI_CANARY\n"

local function with_snapshot(saved, body, targets, owner, unowned)
	local loaded, globals = {}, {}
	for name, value in pairs(package.loaded) do loaded[name] = value end
	local old_cpath, old_ffi_preload = package.cpath, package.preload.ffi
	local attempts = 0
	local function blocked()
		attempts = attempts + 1
		error("snapshot fixture forbids native operations", 0)
	end
	local function guard(object, name)
		globals[#globals + 1] = { object, name, object[name] }
		object[name] = blocked
	end
	local shell, logger
	local okay, detail = xpcall(function()
		for _, name in ipairs({ "popen", "open", "tmpfile", "input", "output", "lines", "read" }) do guard(io, name) end
		for _, name in ipairs({ "execute", "remove", "rename", "tmpname", "clock", "date", "time" }) do guard(os, name) end
		guard(package, "loadlib")
		package.cpath = ""
		package.loaded.luv = setmetatable({}, { __index = function() return blocked end })
		package.loaded.ffi, package.preload.ffi = nil, blocked
		for _, name in ipairs({ "core.logger.engine", "core.logger.engine.shim", "core.logger.engine.monotonic", "core.ui.engine.display_server", "core.process.adapters.shell_runner", "adapters.clipboard" }) do
			package.loaded[name] = nil
		end
		logger = require("core.logger.engine")
		logger.timestamp_fn = function() return "2000-01-01 00:00:00:000" end
		local tick = 0
		logger.clock_fn = function() tick = tick + 10; return tick end
		logger.set_level("debug")
		assert(require("core.logger.engine.shim") == logger)
		local logs = {}
		logger.set_sink(function(line) logs[#logs + 1] = line end)
		local display = require("core.ui.engine.display_server")
		display._set_for_test(display.X11, "private-memory")
		shell = require("core.process.adapters.shell_runner")
		local validate, run, checked, exact = shell.validate_spawn_args, shell.run, shell.exec_checked, shell.with_exact_stdin
		local s = { value = saved, writes = {}, reads = {}, settles = {}, emits = {}, transforms = 0, layout_calls = 0,
			listings = 0, targets = targets or "TARGETS\nTIMESTAMP\nUTF8_STRING\ntext/plain;charset=utf-8\n" }
		-- The native multi-format owner is a child process; this fixture stands
		-- in for its receipt and serves what it was handed as the clipboard.
		s.target_bytes, s.owner_writes, s.target_reads = owner and owner.bytes or {}, {}, {}
		package.loaded["adapters.clipboard_owner"] = {
			available = function() return owner ~= nil and owner.available == true end,
			write = function(saved_targets)
				s.owner_writes[#s.owner_writes + 1] = saved_targets
				for _, target in ipairs(saved_targets) do
					if target.name == "UTF8_STRING" then s.value = target.data end
				end
				return true
			end,
		}
		-- Real xclip exits 1 when nobody owns the clipboard; the libX11 owner
		-- probe tells that empty clipboard from a failed read.
		s.owner_probes = 0
		s.disowns = 0
		package.loaded["adapters.x11_selection_stamp"] = { owned = function()
			s.owner_probes = s.owner_probes + 1
			if unowned == nil then error("the owner probe runs only after a failed read", 0) end
			return unowned.owned
		end, disown = function()
			s.disowns = s.disowns + 1
			s.value, s.cleared = "", true
			return true
		end }
		package.loaded["adapters.keyboard_layout"] = {
			shortcut_keycode = function(char, fallback)
				s.layout_calls = s.layout_calls + 1
				assert(char == "v" and fallback == 47)
				return 47
			end,
		}
		shell._set_runner(function(command)
			assert(not command:find("\0", 1, true), "the real guard must run before the transport seam")
			if command == "command -v " .. shell.quote("xclip") .. " >/dev/null 2>&1" then return true end
			local clipboard = "timeout 1 xclip -selection clipboard -o 2>/dev/null"
			local primary = "timeout 1 xclip -selection primary -o 2>/dev/null"
			local uri = "timeout 1 xclip -selection clipboard -t text/uri-list -o 2>/dev/null"
			if command == "timeout 1 xclip -selection clipboard -t TARGETS -o 2>/dev/null" then
				s.listings = s.listings + 1
				return { ok = true, output = s.targets }
			end
			local target = command:match("^timeout 1 xclip %-selection clipboard %-t '([^']+)' %-o 2>/dev/null$")
			if target then
				s.target_reads[#s.target_reads + 1] = target
				local bytes = target == "UTF8_STRING" and s.value or s.target_bytes[target]
				if bytes == nil then return { ok = false, output = "" } end
				return { ok = true, output = bytes }
			end
			if command == clipboard or command == primary or command == uri then
				s.reads[#s.reads + 1] = command
				if unowned ~= nil and (#s.writes == 0 or s.cleared) then return { ok = false, output = "" } end
				return { ok = true, output = s.value }
			end
			-- Decode the real generated command independently; no writer/guard mock.
			local header, rest = command:match("^([^\n]*)\n(.*)$")
			local count, token = (header or ""):match("^head %-c (%d+) <<'([%w_]+)' | timeout 1 xclip %-selection clipboard %-in$")
			assert(count and token and rest, "unexpected private transport command")
			local suffix = "\n" .. token .. "\n"
			assert(rest:sub(-#suffix) == suffix)
			local text = rest:sub(1, #rest - #suffix)
			assert(#text == tonumber(count), "the actual writer must preserve exact byte length")
			s.writes[#s.writes + 1] = text
			s.value, s.cleared = text, false
			return true
		end)
		local clip = require("adapters.clipboard")
		local function sleep(ms) s.settles[#s.settles + 1] = ms; return true end
		local function combo(name)
			s.emits[#s.emits + 1] = name
			if name == "ctrl+c" then s.value = s.uri and URI or SELECTED end
			return true
		end
		local channel = { emit = function(code, value)
			s.emits[#s.emits + 1] = { code, value }; return true
		end }
		function s.invoke(owner)
			if owner == "stage" then
				s.stage = clip.new_paste_stage(REPLACEMENT, sleep, 47, function() return true end)
				local ready = s.stage.prepare()
				if ready then s.closed = s.stage.close() end
				return ready
			elseif owner == "paste_text" then return clip.paste_text(REPLACEMENT, channel, sleep)
			elseif owner == "read_selection" then return clip.read_selection(combo, sleep)
			elseif owner == "read_selection_uri_list" then s.uri = true; return clip.read_selection_uri_list(combo, sleep)
			elseif owner == "transform_selection" then
				return clip.transform_selection(function(text)
					s.transforms = s.transforms + 1
					assert(text == SELECTED)
					return REPLACEMENT
				end, combo, sleep)
			end
			error("unknown owned API")
		end
		body(clip, s)
		assert(shell.validate_spawn_args == validate and shell.run == run
			and shell.exec_checked == checked and shell.with_exact_stdin == exact,
			"real composition and guard must remain unchanged")
		for _, lines in ipairs({ logs, logger.ring_buffer_snapshot() }) do
			for _, line in ipairs(lines) do
				assert(not line:find("EP79_PRIVATE", 1, true), "snapshot/replacement/selection canary leaked to logs")
				assert(not line:find("A\0B", 1, true), "binary snapshot leaked to logs")
			end
		end
	end, debug.traceback)
	if shell then shell._reset_runner() end
	if logger then logger.set_sink(nil) end
	package.cpath, package.preload.ffi = old_cpath, old_ffi_preload
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	for i = #globals, 1, -1 do local item = globals[i]; item[1][item[2]] = item[3] end
	if not okay then error(detail, 0) end
	helpers.assert_eq(attempts, 0, "no native operation may replace the private test transport")
end

local owners = { "stage", "paste_text", "read_selection", "read_selection_uri_list", "transform_selection" }
helpers.describe("clipboard snapshot restorability", function()
	for _, owner in ipairs(owners) do
		for _, sample in ipairs({ { name = "NUL", bytes = "A\0B" }, { name = "canary NUL", bytes = "EP79_PRIVATE_SNAPSHOT_A\0B" } }) do
			helpers.it("snapshot preflight: " .. owner .. " refuses " .. sample.name .. " before mutation", function()
				with_snapshot(sample.bytes, function(_, s)
					local accepted = s.invoke(owner)
					-- Check mutation first: baseline APIs can return false too late.
					helpers.assert_eq(#s.writes, 0, "a nonrestorable snapshot must be refused before the first temporary write")
					helpers.assert_eq(s.value, sample.bytes, "the original bytes must remain untouched")
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(#s.reads, 1)
					helpers.assert_eq({ #s.settles, #s.emits, s.transforms, s.layout_calls }, { 0, 0, 0, 0 })
					if s.stage then
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq({ #s.writes, #s.reads, #s.settles, #s.emits }, { 0, 1, 0, 0 })
					end
				end)
			end)
		end
		for _, sample in ipairs({
			{ name = "ASCII", bytes = "EP79_PRIVATE_ASCII" },
			{ name = "empty", bytes = "" },
			{ name = "UTF8", bytes = "EP79_PRIVATE_UTF8 é漢" },
			{ name = "UTF8 two final LF", bytes = "EP79_PRIVATE_UTF8 é漢\n\n" },
		}) do
			helpers.it("snapshot preflight: " .. owner .. " restores " .. sample.name .. " exactly", function()
				with_snapshot(sample.bytes, function(_, s)
					local accepted, text = s.invoke(owner)
					helpers.assert_eq(accepted, true)
					helpers.assert_eq(s.value, sample.bytes)
					helpers.assert_eq(s.writes[#s.writes], sample.bytes, "the actual generated writer must restore every original byte")
					if owner == "stage" then
						helpers.assert_eq(s.closed, true)
						helpers.assert_eq(s.stage.close(), true)
						helpers.assert_eq(#s.writes, 2)
					elseif owner == "read_selection" then helpers.assert_eq(text, SELECTED)
					elseif owner == "read_selection_uri_list" then helpers.assert_eq(text, URI) end
				end)
			end)
		end
		-- ADD-2 (decided by the maintainer on 2026-11-11): the clipboard goes
		-- back unowned, as macOS clears its pasteboard, never as an owned "".
		helpers.it("snapshot preflight: " .. owner .. " gives a clipboard nobody owns back unowned (clipboard-unowned-empty)", function()
			with_snapshot("", function(_, s)
				local accepted = s.invoke(owner)
				helpers.assert_eq(accepted, true, "an ownerless clipboard is an empty one, not a failed read")
				helpers.assert_eq(s.disowns, 1, "the restore must leave the clipboard without an owner")
				helpers.assert_eq(s.cleared, true)
				for _, written in ipairs(s.writes) do
					helpers.assert_true(written ~= "", "an owned empty string was written back")
				end
			end, nil, nil, { owned = false })
		end)
		for _, probe in ipairs({ { name = "owned", owned = true }, { name = "unknown", owned = nil } }) do
			helpers.it("snapshot preflight: " .. owner .. " refuses a failed read of an " .. probe.name
				.. " clipboard (clipboard-unowned-empty)", function()
				with_snapshot("EP79_PRIVATE_UNREAD", function(_, s)
					local accepted = s.invoke(owner)
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(#s.writes, 0, "a clipboard that could not be read is never borrowed")
				end, nil, nil, { owned = probe.owned })
			end)
		end
		-- LCP-001: the text writer offers one type, so a clipboard that also holds
		-- HTML, an image or copied files would come back as text alone.
		for _, extra in ipairs({ "text/html", "image/png", "x-special/gnome-copied-files", "text/uri-list" }) do
			helpers.it("snapshot preflight: " .. owner .. " refuses a clipboard that also holds " .. extra, function()
				local targets = "TARGETS\nTIMESTAMP\nUTF8_STRING\n" .. extra .. "\ntext/plain\n"
				with_snapshot("EP79_PRIVATE_RICH_TEXT", function(_, s)
					local accepted = s.invoke(owner)
					helpers.assert_eq(#s.writes, 0, "a format the writer cannot restore must refuse before borrowing")
					helpers.assert_eq(s.value, "EP79_PRIVATE_RICH_TEXT")
					helpers.assert_eq(accepted, false)
					helpers.assert_eq(s.listings, 1)
					helpers.assert_eq({ #s.settles, #s.emits, s.transforms }, { 0, 0, 0 })
				end, targets)
			end)
		end
	end
	-- LCP-001 follow-up: with the native owner, every advertised format is
	-- saved byte for byte and handed back, NUL bytes included.
	for _, owner in ipairs(owners) do
		helpers.it("multi-format restore: " .. owner .. " hands every saved format to the native owner", function()
			local html, png = "<b>EP79_PRIVATE_HTML</b>", "\137PNG\0\1EP79_PRIVATE_IMAGE"
			local targets = "TARGETS\nTIMESTAMP\nUTF8_STRING\ntext/html\nimage/png\n"
			with_snapshot("EP79_PRIVATE_RICH_TEXT", function(_, s)
				local accepted = s.invoke(owner)
				helpers.assert_eq(accepted, true)
				helpers.assert_eq(s.target_reads, { "UTF8_STRING", "text/html", "image/png" })
				helpers.assert_eq(#s.owner_writes, 1, "the restore goes through the multi-format owner once")
				local restored = {}
				for _, target in ipairs(s.owner_writes[1]) do restored[#restored + 1] = { target.name, target.data } end
				helpers.assert_eq(restored, { { "UTF8_STRING", "EP79_PRIVATE_RICH_TEXT" }, { "text/html", html },
					{ "image/png", png } })
				helpers.assert_eq(s.value, "EP79_PRIVATE_RICH_TEXT")
				for _, written in ipairs(s.writes) do
					helpers.assert_true(written ~= "EP79_PRIVATE_RICH_TEXT", "the text writer must not restore a rich clipboard")
				end
			end, targets, { available = true, bytes = { ["text/html"] = html, ["image/png"] = png } })
		end)
		-- A screenshot copied alone offers no text: xclip's text read fails though
		-- the clipboard has an owner, and every borrower refused, an emoji
		-- hotstring included. Windows saves it with ClipboardAll; the owner's own
		-- formats now decide (CBL-001, clipboard-image-only).
		helpers.it("multi-format restore: " .. owner .. " borrows an image-only clipboard (clipboard-image-only)", function()
			local png = "\137PNG\0\1EP79_PRIVATE_IMAGE_ONLY"
			with_snapshot("", function(_, s)
				helpers.assert_eq(s.invoke(owner), true, "an owner offering no text is not a failed read")
				helpers.assert_eq(#s.owner_writes, 1, "the image goes back through the multi-format owner")
				local restored = {}
				for _, target in ipairs(s.owner_writes[1]) do restored[#restored + 1] = { target.name, target.data } end
				helpers.assert_eq(restored, { { "image/png", png } })
			end, "TARGETS\nTIMESTAMP\nimage/png\n", { available = true, bytes = { ["image/png"] = png } },
				{ owned = true })
		end)
		helpers.it("multi-format restore: " .. owner .. " refuses an image-only clipboard with no owner to restore it (clipboard-image-only)", function()
			with_snapshot("", function(_, s)
				helpers.assert_eq(s.invoke(owner), false)
				helpers.assert_eq({ #s.writes, #s.owner_writes }, { 0, 0 }, "refused before the clipboard changes")
			end, "TARGETS\nTIMESTAMP\nimage/png\n", nil, { owned = true })
		end)
		helpers.it("multi-format restore: " .. owner .. " refuses when one advertised format cannot be read", function()
			local targets = "TARGETS\nUTF8_STRING\ntext/html\nimage/png\n"
			with_snapshot("EP79_PRIVATE_RICH_TEXT", function(_, s)
				helpers.assert_eq(s.invoke(owner), false)
				helpers.assert_eq({ #s.writes, #s.owner_writes, #s.emits }, { 0, 0, 0 })
			end, targets, { available = true, bytes = { ["text/html"] = "<i>x</i>" } })
		end)
	end
	for _, method in ipairs({ "read_checked", "read_primary" }) do
		helpers.it("snapshot preflight: raw " .. method .. " retains NUL without writes", function()
			local bytes = "EP79_PRIVATE_RAW_A\0B"
			with_snapshot(bytes, function(clip, s)
				local accepted, text, why = clip[method]()
				helpers.assert_eq({ accepted, text }, { true, bytes })
				helpers.assert_nil(why)
				helpers.assert_eq({ #s.writes, #s.reads, #s.emits, #s.settles }, { 0, 1, 0, 0 })
			end)
		end)
	end
	helpers.it("snapshot preflight: existing writer hard guard still refuses NUL before dispatch", function()
		with_snapshot("original", function(clip, s)
			helpers.assert_eq(clip.write("EP79_PRIVATE_WRITE_A\0B"), false)
			helpers.assert_eq(s.value, "original")
			helpers.assert_eq({ #s.writes, #s.reads }, { 0, 0 })
		end)
	end)
end)
