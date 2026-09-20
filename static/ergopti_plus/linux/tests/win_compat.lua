--- static/ergopti_plus/linux/tests/win_compat.lua

--- ==============================================================================
--- MODULE: Windows Test Mode (Linux driver)
--- DESCRIPTION:
--- The Linux driver targets POSIX, and its suite asserts POSIX behaviour:
--- $HOME resolution, /tmp fixtures, atomic rename-replace, /dev/urandom,
--- mkdir -p, and real sh/coreutils pipelines. On a Windows checkout that
--- layer is absent, which turned 27 otherwise-green tests red for reasons
--- that had nothing to do with the driver.
---
--- This module emulates the POSIX surface the suite needs, for the test
--- process only, and only on Windows (package.config separator "\\").
--- Production modules are untouched, no assertion is relaxed, and Linux CI
--- never loads this file: tests/run.lua calls install() and install() is a
--- no-op anywhere else.
---
--- WHAT IS EMULATED, AND WHY IT STAYS HONEST:
--- 1. HOME/XDG locators answer inside an isolated drive-relative /tmp tree,
---    pre-created at install, so persistence tests exercise the real storage
---    adapter instead of failing on a missing directory.
--- 2. os.tmpname() answers /tmp/ergopti-win-test/<run>-N, so the ^/tmp/
---    fixture assertions and the absolute-path guards keep checking what
---    they check on Linux. Windows resolves those paths drive-relative,
---    natively. The per-run stamp keeps one run's leftovers (os.remove
---    cannot delete directories here) from colliding with the next run's
---    fixtures.
--- 3. os.rename() removes an existing destination first (POSIX replace).
---    Lua file calls are otherwise unwrapped: bytes on disk are real.
--- 4. Bare "mkdir" commands are executed natively (cmd creates intermediate
---    directories), because cmd's mkdir has no -p flag and would otherwise
---    create garbage directories while reporting success.
--- 5. Commands headed by a POSIX tool (sh, tar, rm, chmod, cp, mv, cat, grep,
---    mktemp, test, pwd) or by an existing script path are routed to the sh
---    and coreutils shipping with Git for Windows, with /tmp operands mapped
---    to the same drive-absolute tree Lua sees. The tools really run; only
---    the platform gap is bridged. Anything else reaches cmd.exe exactly as
---    before, so tool-absence verdicts (xclip, wl-copy, xdotool) are unchanged.
--- 6. /dev/urandom answers synthetic bytes. The nonce path (open, read(18),
---    base64, CSP authoring) is fully executed; only the kernel entropy
---    source itself is unavailable on this platform.
---
--- CONSTRAINTS A FUTURE TEST MUST RESPECT:
--- - No executed heredoc may carry "/tmp/" as data: command strings map that
---   prefix to the fixture tree. Heredoc composition is string-asserted only.
--- - One suite at a time: tmpname() counts per install with a per-run
---   stamp, and install() wipes the fixture tree (verified, retried, loud
---   on survival).
--- ==============================================================================

local M = {}

--- Whether this process needs the Windows emulation.
--- @return boolean
local function is_windows()
	return package.config:sub(1, 1) == "\\"
end
M.is_windows = is_windows


-- =========================================
-- =========================================
-- ======= 1/ Saved primitives =============
-- =========================================
-- =========================================

local real_execute = os.execute
local real_popen = io.popen
local real_open = io.open
local real_remove = os.remove
local real_rename = os.rename
local real_tmpname = os.tmpname
local real_getenv = os.getenv

local _installed = false
local _is_jit = type(jit) == "table"


-- =========================================
-- =========================================
-- ======= 2/ Fixture roots ================
-- =========================================
-- =========================================

--- Literal POSIX spelling, resolved natively by Windows drive-relative
--- rules ("/tmp/x" opens "<cwd-drive>:\tmp\x"). Nothing is translated on
--- the Lua side, so installer path normalisation sees byte-identical input
--- on both platforms.
local WIN_TMP = "/tmp/ergopti-win-test"
local WIN_HOME = "/tmp/ergopti-win-home"
local WIN_CONFIG = WIN_HOME .. "/.config"
local WIN_STORE_DIR = WIN_CONFIG .. "/ergopti_plus"
local WIN_DATA = WIN_HOME .. "/.local/share"

--- Drive letter the fixture tree lives on, detected from the suite's working
--- directory at install ("D:" here). Shell children need it spelled out:
--- the MSYS tools behind the Git userland map "/d/tmp/..." to "D:\tmp\...",
--- which is the same directory Lua reaches drive-relative.
local WIN_DRIVE = "C:"

--- Lowercase drive for the MSYS spelling ("/d/tmp/...").
--- @return string
local function msys_drive()
	return WIN_DRIVE:sub(1, 1):lower()
end

--- Absolute Git userland carrying sh and coreutils, backslash native for
--- cmd.exe. Discovered at install; nil when Git for Windows is absent, in
--- which case POSIX-tool commands fail honestly instead of half-working.
local TOOL_DIR = nil

--- Run tag baked into every tmpname: os.remove cannot delete directories
--- on Windows, so per-run fixture directories outlive their test, and a
--- rmdir wipe can report success while a scanner still holds a fresh
--- archive. Stable per-run counters would then collide with the previous
--- run's leftovers ("Permission denied" creating over a stale directory).
--- Seconds-resolution time is unique across runs because one suite takes
--- minutes; concurrent suites remain unsupported (see header).
local RUN_TAG = "0"

--- Prefix resolving bare POSIX tool names through the Git userland. A
--- double-quoted absolute tool path does not survive cmd.exe quote
--- stripping once single-quoted operands follow, while a PATH lookup does.
--- @return string Empty when no userland was discovered.
local function tool_path_prefix()
	if not TOOL_DIR then return "" end
	return 'set "PATH=' .. TOOL_DIR .. ';%PATH%" & '
end

local tmp_counter = 0


-- =========================================
-- =========================================
-- ======= 3/ Small utilities ==============
-- =========================================
-- =========================================

local function to_win(path)
	return (tostring(path):gsub("/", "\\"))
end

--- Maps the /tmp fixture namespace to the drive-absolute spelling shell
--- children require. Lua file calls keep the literal spelling.
--- @param value string
--- @return string
local function translate_tmp_abs(value)
	if type(value) ~= "string" then return value end
	return (value:gsub("/tmp/", WIN_DRIVE .. "/tmp/"))
end

--- Maps the /tmp fixture namespace to the MSYS spelling POSIX tools
--- require. A "D:/..." operand would read as a remote host:path to tar,
--- while "/d/..." is the userland's own name for the same directory Lua
--- reaches drive-relative. Anchored so an already drive-absolute operand
--- ("D:/tmp/...") is left alone: the userland converts that spelling
--- itself.
--- @param value string
--- @return string
local function translate_tmp_tool(value)
	if type(value) ~= "string" then return value end
	value = value:gsub("^/tmp/", "/" .. msys_drive() .. "/tmp/")
	return (value:gsub("([%s\"'=])/tmp/", "%1/" .. msys_drive() .. "/tmp/"))
end

--- cmd.exe has no /dev/null. Rewrite null redirections to NUL so routed
--- commands neither fail nor litter the checkout; 2>&1 already works.
--- @param cmd string
--- @return string
local function rewrite_null(cmd)
	cmd = cmd:gsub("2>%s*/dev/null", "2>NUL")
	cmd = cmd:gsub(">%s*/dev/null", ">NUL")
	return cmd
end

--- Splits a command into POSIX words, honouring single quotes (with the
--- close-escape-reopen '\'' sequence), double quotes, and backslashes.
--- @param cmd string
--- @return table Array of words.
local function split_words(cmd)
	local words, cur, quote = {}, {}, nil
	local i = 1
	while i <= #cmd do
		local c = cmd:sub(i, i)
		if quote then
			if quote == "'" and c == "'" then
				if cmd:sub(i, i + 3) == "'\\''" then
					cur[#cur + 1] = "'"
					i = i + 4
				else
					quote = nil
					i = i + 1
				end
			elseif quote == '"' and c == "\\" and i < #cmd then
				-- Inside double quotes a backslash escapes only $, `, ", \
				-- and newline. Anywhere else (notably a Windows separator)
				-- it is a literal character: swallowing it would fuse
				-- "\tmp\dir" into one relative word.
				local nxt = cmd:sub(i + 1, i + 1)
				if nxt == "$" or nxt == "`" or nxt == "\"" or nxt == "\\"
					or nxt == "\n" then
					cur[#cur + 1] = nxt
					i = i + 2
				else
					cur[#cur + 1] = c
					i = i + 1
				end
			elseif c == quote then
				quote = nil
				i = i + 1
			else
				cur[#cur + 1] = c
				i = i + 1
			end
		elseif c == "'" or c == '"' then
			quote = c
			i = i + 1
		elseif c == "\\" and i < #cmd then
			cur[#cur + 1] = cmd:sub(i + 1, i + 1)
			i = i + 2
		elseif c:match("%s") then
			if #cur > 0 then
				words[#words + 1] = table.concat(cur)
				cur = {}
			end
			i = i + 1
		else
			cur[#cur + 1] = c
			i = i + 1
		end
	end
	if #cur > 0 then words[#words + 1] = table.concat(cur) end
	return words
end


-- =========================================
-- =========================================
-- ======= 4/ mkdir emulation ==============
-- =========================================
-- =========================================

--- Runs a bare mkdir through cmd's own recursive directory creation.
--- cmd's mkdir has no -p flag: passing one through would create literal
--- "-p" directories while reporting success.
--- @param cmd string The full mkdir command.
--- @return boolean|number Version-appropriate success signal, false on failure.
local function emulate_mkdir(cmd)
	if cmd:find("&&", 1, true) or cmd:find("||", 1, true)
		or cmd:find("|", 1, true) or cmd:find(";", 1, true) then
		return real_execute(cmd)
	end
	local stripped = cmd:gsub("%d*>%s*%S+", "")
	local words = split_words(stripped:match("^%s*mkdir%s*(.-)%s*$") or "")
	local dirs = {}
	for _, word in ipairs(words) do
		if word ~= "" and word:sub(1, 1) ~= "-" then
			dirs[#dirs + 1] = word
		end
	end
	if #dirs == 0 then return false end
	for _, dir in ipairs(dirs) do
		local native = to_win(dir)
		local first = real_execute('mkdir "' .. native .. '" >NUL 2>&1')
		if not (first == true or first == 0) then return false end
	end
	if _is_jit then return 0 end
	return true
end


-- =========================================
-- =========================================
-- ======= 5/ POSIX tool routing ===========
-- =========================================
-- =========================================

--- Command heads routed to the Git userland instead of cmd.exe.
local TOOL_HEADS = {
	sh = true,
	tar = true,
	rm = true,
	chmod = true,
	cp = true,
	mv = true,
	cat = true,
	grep = true,
	mktemp = true,
	test = true,
	pwd = true,
	wc = true,
}

--- Splits `sh -c 'SCRIPT' args...` into the script (honouring the '\''
--- escape) and the remaining argument words. Returns nil when the shape
--- does not match or an argument word is a redirection or operator, in
--- which case the caller falls back to inline execution.
--- @param tail string Command tail after the sh head.
--- @return string|nil script
--- @return table|nil words
local function split_sh_c(tail)
	local start = tail:match("^%s*%-c%s*'()")
	if not start then return nil end
	local buf, i = {}, start
	while i <= #tail do
		local c = tail:sub(i, i)
		if c == "'" then
			if tail:sub(i, i + 3) == "'\\''" then
				buf[#buf + 1] = "'"
				i = i + 4
			else
				local words = split_words(tail:sub(i + 1))
				for _, word in ipairs(words) do
					if word:match("^[><]") or word == "&" or word == "&&"
						or word == "||" or word == "|" or word == ";" then
						return nil
					end
				end
				return table.concat(buf), words
			end
		else
			buf[#buf + 1] = c
			i = i + 1
		end
	end
	return nil
end

--- POSIX single-quote for file content parsed by sh itself.
--- @param value string
--- @return string
local function sh_quote(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Routes `sh -c 'SCRIPT' args...` through a script file: cmd.exe cannot
--- carry the script's quotes and newlines on one command line, while a
--- file preserves them byte for byte. A `set --` preamble restores $1..$n
--- ($0-ignoring scripts only; the suite's single sh -c user never reads
--- $0). Returns nil when the shape does not fit, for inline fallback.
--- @param tail string Command tail after the sh head.
--- @return string|nil Routed command.
local function route_sh_c(tail)
	local script, words = split_sh_c(tail)
	if not script then return nil end
	tmp_counter = tmp_counter + 1
	local path = WIN_TMP .. "/sh-" .. tostring(tmp_counter) .. ".sh"
	-- `sh -s` cannot set $0, so the preamble replays the argument words and
	-- shifts the name away: afterwards $1..$n match the -c form exactly.
	local parts = { "set --" }
	for _, word in ipairs(words) do parts[#parts + 1] = " " .. sh_quote(word) end
	parts[#parts + 1] = "\n"
	if #words > 0 then parts[#parts + 1] = "shift\n" end
	parts[#parts + 1] = script
	parts[#parts + 1] = "\n"
	local handle = real_open(path, "w")
	if not handle then return nil end
	handle:write(table.concat(parts))
	handle:close()
	return tool_path_prefix() .. 'sh -s < "' .. to_win(path) .. '"'
end

--- Converts simply-quoted operands ('...') to double-quoted ones for a
--- direct tool call. cmd.exe and the MSVCRT splitter honour double quotes;
--- single quotes would reach the tool as literal characters.
--- Not applied to sh scripts: sh parses its own quoting.
--- @param tail string Command tail after the tool head.
--- @return string
local function double_quote_operands(tail)
	return (tail:gsub("'([^'\r\n]*)'", '"%1"'))
end

--- Rewrites one command for execution on this box. Returns the rewritten
--- command and whether its captured output needs path mapping back.
--- @param cmd string
--- @return string Command to hand to the real primitive.
--- @return boolean Whether stdout carries fixture paths to map back.
local function route_command(cmd)
	local mapped = rewrite_null(translate_tmp_abs(cmd))
	local tooled = rewrite_null(translate_tmp_tool(cmd))

	-- An existing script path up front runs through sh (installer smoke).
	-- The probe uses the cmd spelling Lua opens natively; the emitted
	-- operand uses the MSYS spelling the tool requires.
	local quoted_head, rest = mapped:match("^%s*'([^']+)'%s*(.*)$")
	if quoted_head then
		local probe = real_open(quoted_head, "r")
		if probe then
			local content = probe:read("*a")
			probe:close()
			if TOOL_DIR then
				local script_path = quoted_head
				-- A test-authored smoke script names its fixtures with
				-- literal /tmp paths, which sh would resolve to its own
				-- /tmp. Run a translated copy: same bytes, same files,
				-- only the namespace spelling differs. Scripts without
				-- fixture paths run untouched.
				if type(content) == "string"
					and content:find("/tmp/", 1, true) then
					tmp_counter = tmp_counter + 1
					local copy = WIN_TMP .. "/smoke-"
						.. tostring(tmp_counter) .. ".sh"
					local writer = real_open(copy, "w")
					if writer then
						writer:write(translate_tmp_tool(content))
						writer:close()
						script_path = copy
					end
				end
				return tool_path_prefix() .. 'sh "'
					.. translate_tmp_tool(script_path) .. '"'
					.. (rest ~= "" and " " .. translate_tmp_tool(rest) or ""), false
			end
		end
		return mapped, false
	end

	local head = tooled:match("^%s*([%w][%w%._%-]*)")
	if head and TOOL_HEADS[head] and TOOL_DIR then
		local tail = tooled:gsub("^%s*" .. head, "", 1)
		if head == "sh" then
			-- Prefer a script file: cmd.exe cannot carry the script's quotes
			-- and newlines on one command line. Fall back to newline folding
			-- when the shape does not fit.
			local via_file = route_sh_c(tail)
			if via_file then return via_file, false end
			tail = tail:gsub("[\r\n]+", "; ")
			return tool_path_prefix() .. "sh" .. tail, false
		end
		tail = double_quote_operands(tail)
		return tool_path_prefix() .. head .. tail, head == "mktemp"
	end
	return mapped, false
end

--- Captured stdout maps the drive-absolute fixture prefix back to the
--- literal spelling Lua file calls use, so mktemp-style outputs round-trip
--- through installer path normalisation unchanged.
--- @param output string|nil
--- @return string|nil
local function map_output_back(output)
	if type(output) ~= "string" then return output end
	return (output:gsub("/" .. msys_drive() .. "/tmp/", "/tmp/"))
end

--- True when a native fixture path exists, file or directory.
--- @param native_path string Backslash-native path.
--- @return boolean
local function fixture_exists(native_path)
	local probe = real_execute('cmd /c dir /b /a "' .. native_path .. '" >NUL 2>&1')
	return probe == true or probe == 0
end

--- Removes a fixture root, waiting out transient file locks (a scanner
--- holding a fresh archive makes rmdir report success while leaving the
--- tree). A surviving tree collides with the stable tmpname counter and
--- fails fixture creation with "Permission denied", so survival is loud.
--- @param native_path string Backslash-native path.
--- @return boolean True when the root is gone.
local function wipe_fixture(native_path)
	for _ = 1, 3 do
		real_execute('rmdir /S /Q "' .. native_path .. '" >NUL 2>&1')
		if not fixture_exists(native_path) then return true end
		real_execute('ping -n 2 127.0.0.1 >NUL 2>&1')
	end
	io.stderr:write(string.format(
		"win_compat: fixture root %s survived its wipe;"
			.. " stale fixtures collide with fresh ones."
			.. " Remove it by hand and re-run.\n",
		native_path))
	return false
end


-- =========================================
-- =========================================
-- ======= 6/ Installed wrappers ===========
-- =========================================
-- =========================================

--- Synthetic /dev/urandom handle. Production reads 18 bytes for the CSP
--- nonce; every read answers deterministic pseudo-random bytes.
--- @return table File-like handle.
local function urandom_handle()
	local function random_bytes(count)
		local parts = {}
		for i = 1, count do
			parts[i] = string.char(math.random(0, 255))
		end
		return table.concat(parts)
	end
	return {
		read = function(_, format)
			if format == "*a" then return random_bytes(64) end
			if format == "*l" then return nil end
			return random_bytes(tonumber(format) or 0)
		end,
		lines = function()
			return function() return nil end
		end,
		close = function() return true end,
	}
end

local ENV_MAP

--- Installs every wrapper. Idempotent; no-op off Windows.
--- @return boolean True when the mode is active.
function M.install()
	if _installed then return true end
	if not is_windows() then return false end

	-- Stamp every tmpname of this run (see RUN_TAG).
	RUN_TAG = tostring(os.time())

	-- Fixture drive follows the suite's own working directory.
	local drive_pipe = real_popen("cd", "r")
	if drive_pipe then
		local cwd = drive_pipe:read("*l")
		drive_pipe:close()
		local drive = type(cwd) == "string" and cwd:match("^([A-Za-z]:)")
		if drive then WIN_DRIVE = drive end
	end

	-- Git userland discovery: ProgramFiles variants, then fixed fallbacks.
	local pf = real_getenv("ProgramFiles") or "C:\\Program Files"
	local pf86 = real_getenv("ProgramFiles(x86)") or "C:\\Program Files (x86)"
	for _, candidate in ipairs({
		pf .. "\\Git\\usr\\bin",
		pf86 .. "\\Git\\usr\\bin",
		"C:\\Program Files\\Git\\usr\\bin",
		"C:\\Program Files (x86)\\Git\\usr\\bin",
	}) do
		local probe = real_open(candidate .. "\\sh.exe", "r")
		if probe then
			probe:close()
			TOOL_DIR = candidate
			break
		end
	end

	-- Fresh fixture tree, then the directories persistence needs.
	wipe_fixture("\\tmp\\ergopti-win-test")
	wipe_fixture("\\tmp\\ergopti-win-home")
	for _, dir in ipairs({ WIN_TMP, WIN_HOME, WIN_STORE_DIR, WIN_DATA }) do
		real_execute('mkdir "' .. to_win(dir) .. '" >NUL 2>&1')
		if not fixture_exists(to_win(dir)) then
			io.stderr:write(string.format(
				"win_compat: fixture directory %s could not be created;"
					.. " persistence tests cannot run green.\n",
				dir))
		end
	end

	-- Only HOME is redirected. XDG locators fall through to it on a box
	-- without XDG variables, exactly as on a Linux session that never
	-- exports them; mapping them here as well would shadow what the
	-- module under test actually reads (the crash reporter binds its
	-- directory from XDG_DATA_HOME-or-HOME at require time).
	ENV_MAP = {
		HOME = WIN_HOME,
	}

	os.getenv = function(name)
		if ENV_MAP[name] ~= nil then return ENV_MAP[name] end
		return real_getenv(name)
	end

	os.tmpname = function()
		tmp_counter = tmp_counter + 1
		return "/tmp/ergopti-win-test/" .. RUN_TAG .. "-" .. tostring(tmp_counter)
	end

	os.rename = function(old_path, new_path)
		if old_path == new_path then return true end
		real_remove(new_path)
		return real_rename(old_path, new_path)
	end

	local saved_open = real_open
	io.open = function(path, mode)
		if path == "/dev/urandom" then return urandom_handle() end
		return saved_open(path, mode)
	end

	os.execute = function(cmd)
		if type(cmd) ~= "string" then return real_execute(cmd) end
		if cmd:match("^%s*mkdir[%s]") then return emulate_mkdir(cmd) end
		return real_execute(route_command(cmd))
	end

	io.popen = function(cmd, mode)
		if type(cmd) ~= "string" then return real_popen(cmd, mode) end
		local routed, map_back = route_command(cmd)
		local handle = real_popen(routed, mode)
		if not handle or not map_back then return handle end
		local proxy = {}
		proxy.read = function(_, format)
			return map_output_back(handle:read(format))
		end
		proxy.lines = function(_, ...)
			local iterator = handle:lines(...)
			return function()
				return map_output_back(iterator())
			end
		end
		proxy.close = function()
			return handle:close()
		end
		return setmetatable(proxy, { __index = handle })
	end

	_installed = true
	print(string.format(
		"win_compat: windows test mode active (fixtures=%s HOME=%s posix-tools=%s)",
		WIN_TMP, WIN_HOME, TOOL_DIR or "MISSING"))
	return true
end

return M
