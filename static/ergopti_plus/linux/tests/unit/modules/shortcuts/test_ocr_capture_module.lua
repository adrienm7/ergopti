--- tests/unit/modules/shortcuts/test_ocr_capture_module.lua

--- ==============================================================================
--- MODULE: OCR Capture Module Tests (Linux)
--- DESCRIPTION:
--- Drives modules/ocr_capture.lua: the region shell runs in a real shell
--- against stub selectors (the drawn region reaches a private file that is
--- printed, a cancelled selection leaves no folder behind), and the action
--- with fake ports copies the recognised lines, keeps the clipboard when
--- nothing is read and refuses a second selection while one is open.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs a script with stub tools first on PATH.
--- @return string stdout, string dir
local function run_with_stubs(script, stubs)
	local dir = os.tmpname()
	os.remove(dir)
	os.execute("mkdir '" .. dir .. "'")
	for name, body in pairs(stubs) do
		local fh = assert(io.open(dir .. "/" .. name, "w"))
		fh:write("#!/bin/sh\n" .. body .. "\n")
		fh:close()
		os.execute("chmod +x '" .. dir .. "/" .. name .. "'")
	end
	local pipe = assert(io.popen("PATH='" .. dir .. ":/usr/bin:/bin' TMPDIR='" .. dir .. "' sh -c "
		.. "'" .. script:gsub("'", "'\\''") .. "' </dev/null 2>/dev/null"))
	local out = pipe:read("*a")
	pipe:close()
	return out, dir
end

local REGION = 'grim -g "$(slurp)" %s'

local function fake_ports(answer)
	local state = { notices = {}, clipboard = nil, removed = {} }
	state.ports = {
		select = function(callback) state.select = callback end,
		recognize = function(_, callback) callback(answer.words, answer.reason) end,
		set_clipboard = function(text) state.clipboard = text; return true end,
		notify = function(key, _, lines) state.notices[#state.notices + 1] = key; state.lines = lines end,
		remove = function(path) state.removed[#state.removed + 1] = path end,
		log = function() end,
	}
	return state
end

helpers.describe("OCR capture module (Linux)", function()
	local Capture = require("modules.ocr_capture")

	helpers.it("ocr capture: the drawn region reaches a private file that is printed", function()
		local out, dir = run_with_stubs(Capture.region_command(REGION), {
			slurp = 'echo "10,10 50x20"',
			grim = 'for last; do :; done; printf png > "$last"',
		})
		helpers.assert_true(out:match("/ergopti%-ocr%.[^/]+/capture%.png$") ~= nil, "the capture path: " .. out)
		helpers.assert_eq(io.open(out, "rb") ~= nil, true, "the capture is kept for the OCR")
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("ocr capture: a cancelled selection prints nothing and leaves no folder", function()
		local out, dir = run_with_stubs(Capture.region_command(REGION), { slurp = "exit 1", grim = "exit 1" })
		helpers.assert_eq(out, "", "nothing is printed")
		local pipe = assert(io.popen("find '" .. dir .. "' -name 'ergopti-ocr.*' -print"))
		helpers.assert_eq(pipe:read("*a"), "", "the private folder is removed")
		pipe:close()
		os.execute("rm -rf '" .. dir .. "'")
	end)

	helpers.it("ocr capture: the recognised lines reach the clipboard with a notice", function()
		local state = fake_ports({ words = { { text = "Bonjour", line = "1" }, { text = "le", line = "2" },
			{ text = "monde", line = "2" } } })
		Capture._set_ports(state.ports)
		helpers.assert_eq(Capture.run(REGION), true, "the action starts")
		helpers.assert_eq(Capture.run(REGION), false, "a second selection is refused while one is open")
		state.select("/tmp/ergopti-ocr.x/capture.png")
		helpers.assert_eq(state.clipboard, "Bonjour\nle monde", "the line break is kept")
		helpers.assert_eq(state.notices[1], "ocr_capture.copied", "the copy is announced")
		helpers.assert_eq(state.lines, 2, "with its line count")
		helpers.assert_eq(state.removed[1], "/tmp/ergopti-ocr.x/capture.png", "the capture is removed")
		helpers.assert_eq(Capture.run(REGION), true, "the next capture is admitted once this one ended")
		Capture._set_ports(nil)
	end)

	helpers.it("ocr capture: nothing recognised keeps the clipboard and says so", function()
		local state = fake_ports({ words = {} })
		Capture._set_ports(state.ports)
		Capture.run(REGION)
		state.select("/tmp/ergopti-ocr.x/capture.png")
		helpers.assert_nil(state.clipboard, "the clipboard is untouched")
		helpers.assert_eq(state.notices[1], "ocr_capture.nothing_recognised", "the user is told")
		Capture._set_ports(nil)
	end)

	helpers.it("ocr capture: Escape shows nothing", function()
		local state = fake_ports({ words = {} })
		Capture._set_ports(state.ports)
		Capture.run(REGION)
		state.select(nil, "cancelled")
		helpers.assert_eq(#state.notices, 0, "a cancelled selection is quiet")
		Capture._set_ports(nil)
	end)

	helpers.it("ocr capture: the notice escapes the line count it substitutes", function()
		-- A '%' in a gsub replacement is a capture reference: the count must be
		-- escaped as macOS's gsub-replacement gate requires of the same notice.
		local source = assert(helpers.read_module_source("modules.ocr_capture"))
		helpers.assert_true(source:find('body:gsub("{1}", text_utils.escape_gsub_replacement(tostring(lines)))', 1, true) ~= nil,
			"the {1} count is routed through text_utils.escape_gsub_replacement")
		helpers.assert_true(source:find('body:gsub("{1}", tostring(lines))', 1, true) == nil,
			"no bare count is a gsub replacement")
	end)
end)
