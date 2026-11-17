--- tests/hardware/run_editor_receiving_webkit.lua

--- ==============================================================================
--- MODULE: The Hotstring Editor Received In Real WebKit
--- DESCRIPTION:
--- Opens the personal hotstring editor in the daemon's own WebView manager,
--- under a real X server and WebKit2GTK, and drives it only through the page's
--- own code: its "ready" message, its add-entry form, its Save button and its
--- shortcut auto-close. Every verdict is read back from what the user would
--- meet: the bytes of the personal file, the page's DOM, the real input capture
--- gate and the GTK toplevels that exist.
---
--- WHAT IT ASSERTS (native UI audit, scopes linux-webview and LVB-001):
--- 1. Refused write: with the personal folder read-only, Save leaves the file's
---    bytes untouched, the page shows the translated save error, and the
---    shortcut auto-close that follows keeps the window open (closing it would
---    destroy the only copy of the draft).
--- 2. Healthy save and auto-close: once the folder is writable again, the same
---    page's next save reaches the file with both drafts, the auto-close retires
---    the exact native window (no editor toplevel remains) and releases the input
---    capture the page took when it was focused.
--- 3. Stale epochs: with a new editor page open, a save and a close stamped with
---    the retired page's epoch change neither the file nor the new window, and a
---    stale input release leaves the new page's capture in place.
--- 4. Physical cleanup: the manager's shutdown leaves no editor toplevel and no
---    input capture behind.
---
--- Run from the Linux driver with its normal LUA_PATH under xvfb-run, as a
--- user that file permissions bind (not root). Exit 0 = every check held,
--- 1 = a regression, 2 = the machine cannot host the test.
--- ==============================================================================

local EXPECTED_CHECKS = 17
local WAIT_ATTEMPTS = 80
local WAIT_SECONDS = 0.1

local _checks, _failures = 0, 0

--- @param condition boolean
--- @param what string
local function check(condition, what)
	_checks = _checks + 1
	if condition then
		print("  ok   " .. what)
	else
		_failures = _failures + 1
		print("  FAIL " .. what)
	end
end

--- @param message string
local function abort(message)
	io.stderr:write("ENVIRONMENT: " .. message .. "\n")
	os.exit(2)
end

print("=== the hotstring editor, received in real WebKit ===")
if not os.getenv("DISPLAY") and not os.getenv("WAYLAND_DISPLAY") then abort("no display server; run under xvfb-run.") end
local ok_lgi, lgi = pcall(require, "lgi")
if not ok_lgi then abort("lgi is not installed.") end
local ok_webkit = pcall(lgi.require, "WebKit2", "4.1")
if not ok_webkit then abort("WebKit2GTK 4.1 is unavailable to lgi.") end
local Gtk = lgi.require("Gtk", "3.0")

--- Runs a shell command and reports whether it exited 0 (LuaJIT and 5.2+ shapes).
--- @param command string
--- @return boolean
local function sh(command)
	local first, _, code = os.execute(command)
	return first == 0 or (first == true and (code == nil or code == 0))
end

--- @param value string
--- @return string
local function quote(value) return "'" .. (value:gsub("'", [['\'']])) .. "'" end

local id = io.popen("id -u")
local uid = id and id:read("*l")
if id then id:close() end
if uid == "0" then abort("running as root: file permissions cannot refuse a write.") end

-- A private profile: the editor's preferences live in the driver's storage.
local ffi = require("ffi")
pcall(ffi.cdef, "int setenv(const char *, const char *, int);")
local profile = os.tmpname()
assert(os.remove(profile), "the owned temporary placeholder must retire")
assert(sh("mkdir -m 700 " .. quote(profile)), "the private profile must be created")
for _, name in ipairs({ "CONFIG", "DATA", "CACHE", "STATE" }) do
	local directory = profile .. "/" .. name:lower()
	assert(sh("mkdir -m 700 " .. quote(directory)), "the private XDG root must be created")
	assert(ffi.C.setenv("XDG_" .. name .. "_HOME", directory, 1) == 0)
end
print("OWNED_PROFILE " .. profile)

local PERSONAL_DIR = profile .. "/personal"
local PERSONAL_PATH = PERSONAL_DIR .. "/personal.toml"
-- An empty section first: its entries once reached the page as {} and render()
-- threw on it, so the shortcut's add-entry form never opened.
local PERSONAL_SOURCE = '[[Empty]]\n\n[[General]]\n"probe" = { output = "received" }\n'
assert(sh("mkdir -m 755 " .. quote(PERSONAL_DIR)), "the personal folder must be created")
do
	local file = assert(io.open(PERSONAL_PATH, "wb"))
	assert(file:write(PERSONAL_SOURCE))
	assert(file:close())
end

--- @return string|nil
local function personal_bytes()
	local file = io.open(PERSONAL_PATH, "rb")
	if not file then return nil end
	local content = file:read("*a")
	file:close()
	return content
end

--- @param folder_mode string Octal mode for the folder.
--- @param file_mode string Octal mode for the file.
local function chmod(folder_mode, file_mode)
	assert(sh("chmod " .. file_mode .. " " .. quote(PERSONAL_PATH)), "the personal file mode must change")
	assert(sh("chmod " .. folder_mode .. " " .. quote(PERSONAL_DIR)), "the personal folder mode must change")
end

local HotstringsConfig = require("modules.hotstrings.hotstrings_config")
assert(HotstringsConfig.init(nil, PERSONAL_DIR, nil) == true, "the real hotstrings configuration must initialize")
assert(HotstringsConfig.get_config_dir() == PERSONAL_DIR, "the editor must edit the owned personal folder")
HotstringsConfig.load_all()
local Gate = require("platform.input.capture_gate").new({})
local Manager = require("core.ui.ui.webview_manager")
Manager.set_daemon_state({ config = HotstringsConfig, input_capture_gate = Gate })
local Bridge = require("ui.hotstring_editor.bridge")
local APP, BRIDGE = "hotstring_editor", "hsEditor"
local save_error = require("core.i18n.engine.i18n").get("editor.hotstrings.save_error")
assert(type(save_error) == "string" and save_error ~= "" and save_error ~= "editor.hotstrings.save_error",
	"the save error must have a translated label")





-- ===================================
-- ===================================
-- ======= 1/ Driving the page =======
-- ===================================
-- ===================================

local function pump_once()
	while Gtk.events_pending() do Gtk.main_iteration_do(false) end
end

--- Evaluates JavaScript in the editor's live view and returns its string result.
--- @param source string
--- @return string|nil
local function eval(source)
	local view = Manager.webview_for(APP)
	if not view then return nil end
	local answer, done = nil, false
	view:run_javascript(source, nil, function(_, result)
		local ok, value = pcall(function() return view:run_javascript_finish(result):get_js_value():to_string() end)
		answer, done = ok and value or nil, true
	end, nil)
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		if done then return answer end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return answer
end

--- Pumps GTK until a JavaScript predicate answers "true".
--- @param source string
--- @return boolean
local function wait_js(source)
	for _ = 1, WAIT_ATTEMPTS do
		if eval(source) == "true" then return true end
		pump_once()
		os.execute("sleep " .. WAIT_SECONDS)
	end
	return false
end

--- Pumps GTK until a Lua predicate holds.
--- @param predicate function
--- @return boolean
local function wait_lua(predicate)
	for _ = 1, WAIT_ATTEMPTS do
		pump_once()
		if predicate() then return true end
		os.execute("sleep " .. WAIT_SECONDS)
	end
	pump_once()
	return predicate()
end

--- Number of visible editor toplevels GTK still holds.
--- @return integer
local function editor_toplevels()
	local caption, count = Manager.app_caption(APP), 0
	for _, window in ipairs(Gtk.Window.list_toplevels()) do
		if window.title == caption and window.visible then count = count + 1 end
	end
	return count
end

--- Opens the editor in shortcut mode and waits until the page drew the payload.
--- @return number|nil epoch
local function open_editor()
	Bridge.set_pending_mode("shortcut")
	if not Manager.show(APP) then return nil end
	local drawn = wait_js("String(typeof D !== 'undefined' && D !== null && document.getElementById('app').style.display === 'flex')")
	if not drawn then return nil end
	return Manager.current_epoch(APP)
end

--- Fills the page's own add-entry form and presses its Save button.
--- @param trigger string
--- @param output string
local function save_entry(trigger, output)
	-- Shortcut mode opens the form on the default section by itself.
	if not wait_js("String(document.getElementById('entry-modal').classList.contains('on'))") then
		error("the add-entry form is not shown: " .. tostring(eval(
			"JSON.stringify({mode: openMode, section: defaultSec, auto: autoClose, sections: D.sections.map(s => s.name)})")))
	end
	eval(string.format([[
		setTrigContent(document.getElementById('e-trig'), %q);
		setEditorContent(document.getElementById('e-out'), %q);
		document.querySelector('button[onclick="saveEntry(false)"]').click(); 'clicked'
	]], trigger, output))
end

--- The page's focus listener asks the daemon to hold the input capture.
local function focus_page()
	eval("window.dispatchEvent(new FocusEvent('focus')); 'focused'")
	wait_lua(function() return Gate.blocks_text() end)
end




-- ======================================
-- ======================================
-- ======= 2/ The four flows ============
-- ======================================
-- ======================================

local function run()
	assert(Bridge.set_pref("auto_close", true), "the auto-close preference must persist")
	assert(Bridge.set_pref("default_section", "General"), "the default section must persist")

	print("--- refused write ---")
	local first = open_editor()
	check(type(first) == "number", "the editor opens and draws the personal source")
	if not first then return end
	focus_page()
	check(Gate.blocks_text() == true, "the focused page holds the input capture")
	chmod("555", "444")
	save_entry("zqa", "Alpha")
	local alerted = wait_js("String(document.getElementById('msg-modal').classList.contains('on'))")
	check(alerted and eval("document.getElementById('msg-text').textContent") == save_error,
		"the page shows the translated save error")
	check(personal_bytes() == PERSONAL_SOURCE, "the refused save leaves the file's bytes untouched")
	-- The auto-close was posted right after the save; give it every chance to land.
	wait_lua(function() return editor_toplevels() == 0 end)
	check(Manager.current_epoch(APP) == first and editor_toplevels() == 1,
		"the auto-close after a refused save keeps the same window open")

	print("--- healthy save and auto-close ---")
	chmod("755", "644")
	eval("closeModal('msg-modal'); showAddEntry(D.sections.findIndex(s => s.name === 'General')); 'opened'")
	save_entry("zqb", "Beta")
	local closed = wait_lua(function() return Manager.current_epoch(APP) == nil end)
	local saved = personal_bytes() or ""
	check(saved:find('"zqa"', 1, true) ~= nil and saved:find('"zqb"', 1, true) ~= nil
		and saved:find('"probe"', 1, true) ~= nil, "the next save writes both drafts and keeps the existing entry")
	check(closed, "the auto-close retires the page")
	check(wait_lua(function() return editor_toplevels() == 0 end), "no editor toplevel remains after the auto-close")
	check(Gate.blocks_text() == false, "the auto-close releases the page's input capture")

	print("--- stale epochs ---")
	local second = open_editor()
	check(type(second) == "number" and second ~= first, "a new editor page opens with a new epoch")
	if not second then return end
	focus_page()
	local before = personal_bytes()
	local stale_save = Manager.route_message(APP, BRIDGE, { action = "save", data = {
		sections_order = { "General" },
		sections = { General = { description = "General", entries = {} } },
	} }, first)
	pump_once()
	check(stale_save == nil and personal_bytes() == before, "a save stamped with the retired epoch writes nothing")
	local stale_close = Manager.route_message(APP, BRIDGE, { action = "close", data = {} }, first)
	pump_once()
	check(stale_close == nil and Manager.current_epoch(APP) == second and editor_toplevels() == 1,
		"a close stamped with the retired epoch leaves the new window open")
	check(Gate.release(APP, first) == false and Gate.blocks_text() == true,
		"a stale input release leaves the new page's capture in place")
	check(wait_js("String(D !== null && D.sections.some(s => (s.entries || []).some(e => e.trigger === 'zqb')))"),
		"the new page shows the saved drafts")

	print("--- physical cleanup ---")
	check(Manager.shutdown() == true, "the manager acknowledges its shutdown")
	check(wait_lua(function() return editor_toplevels() == 0 end), "no editor toplevel remains after shutdown")
	check(Gate.blocks_text() == false, "no input capture remains after shutdown")
end

local ran, err = xpcall(run, debug.traceback)
if not ran then
	_failures = _failures + 1
	print("  FAIL the flow raised: " .. tostring(err))
end
pcall(Manager.shutdown)
pcall(chmod, "755", "644")
sh("rm -rf " .. quote(profile))
check(_checks == EXPECTED_CHECKS, string.format("every check ran (%d of %d)", _checks, EXPECTED_CHECKS))
print(string.format("=== %d check(s), %d failure(s) ===", _checks, _failures))
os.exit(_failures == 0 and 0 or 1)
