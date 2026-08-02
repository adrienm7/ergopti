--- tests/unit/meta/test_shell_quoting_call_sites.lua
---
--- Regression tests for the shell-quoting class bug: every Linux call site that
--- interpolated caller data into a shell command used string.format("%q").
---
--- %q is Lua's LITERAL quoter, not a shell quoter. It emits a DOUBLE-quoted
--- word, and inside double quotes the shell still expands $VAR, `cmd` and
--- $( cmd ). Every one of those sites therefore executed its own input: an
--- SSID, a window title, clipboard content, a config path, an app path. The
--- values are all user- or environment-authored, so this was arbitrary command
--- execution, and it also corrupted the results (sha256("$HOME") hashed the
--- expansion of HOME, not the four characters).
---
--- Two layers, because fixing seven sites and forgetting the eighth is the
--- dominant failure mode here:
---   1. Per-site: drive each entry point with a hostile payload through the
---      shell_runner test seam and assert the composed command carries the
---      POSIX-quoted form and NOT the %q form.
---   2. Class ratchet: scan the whole driver source (derived from the file
---      system, so a new file joins automatically) and refuse %q anywhere
---      outside a Logger call, where Lua-literal quoting is the correct tool.
---
--- The backend-detection cases cover the second half of the same routing: the
--- probes compared os.execute()'s result against 0, which is the Lua 5.1/LuaJIT
--- spelling only. From Lua 5.2 on the same success reads as `true`, so the
--- clipboard and the tooltip both decided their tool was absent and no-opped.

local helpers = require("tests.helpers")
local Shell   = helpers.load_module("adapters.shell_runner")

-- Every metacharacter class at once: command substitution (both spellings),
-- a command separator, and a quote that would close the word.
local PAYLOAD = "$(id)`date`;rm -rf / it's"

-- The exact broken form this test exists to keep out.
local BROKEN_FORM = string.format("%q", PAYLOAD)

--- Runs `fn` with the shell_runner seam installed and returns the commands it
--- composed. `responder` may return canned stdout for a given command.
--- @param fn        function 0-arg body that drives the adapter under test.
--- @param responder function|nil fn(cmd) -> string|nil, canned stdout.
--- @return table Array of composed command strings.
local function capture(fn, responder)
	local seen = {}
	Shell._set_runner(function(cmd)
		seen[#seen + 1] = cmd
		if responder then return responder(cmd) end
		return ""
	end)
	local ok, err = pcall(fn)
	Shell._reset_runner()
	if not ok then error(err, 0) end
	return seen
end

--- Returns the first captured command containing `marker`.
--- @param commands table Array of command strings.
--- @param marker   string Plain substring identifying the command of interest.
--- @return string|nil
local function find_command(commands, marker)
	for _, cmd in ipairs(commands) do
		if cmd:find(marker, 1, true) then return cmd end
	end
	return nil
end

--- Asserts one composed command quotes the payload the POSIX way.
--- @param cmd   string|nil The composed command.
--- @param label string     Call-site name for the failure message.
local function assert_posix_quoted(cmd, label)
	helpers.assert_true(cmd ~= nil, label .. ": no command was composed — the site was not exercised")
	helpers.assert_contains(cmd, Shell.quote(PAYLOAD),
		label .. ": the payload must reach the shell as one inert single-quoted word")
	helpers.assert_true(cmd:find(BROKEN_FORM, 1, true) == nil,
		label .. ": string.format('%q') leaves $( ) and backticks live inside the double quotes it emits")
end

helpers.describe("shell quoting at the call sites", function()

	helpers.describe("crypto.sha256()", function()
		helpers.it("quotes the data it pipes into openssl", function()
			local crypto = helpers.load_module("adapters.crypto")
			local cmds = capture(function() crypto.sha256(PAYLOAD) end)
			assert_posix_quoted(find_command(cmds, "openssl"), "crypto.sha256")
		end)
	end)


	-- ==================================================================
	-- Class ratchet — the seven sites above are today's sites, not the
	-- invariant. This scans the whole driver so the eighth cannot slip in.
	-- ==================================================================

	helpers.describe("no %q survives in a composed shell command", function()

		--- Decides whether a source line reintroduces the bug.
		--- Lua-literal quoting is correct in a log message, so a Logger line is
		--- allowed; a comment is not code. Everything else with %q in it is
		--- building a string, and in this driver strings become commands.
		--- @param line string One line of driver source.
		--- @return boolean
		local function violates(line)
			if not line:find("%q", 1, true) then return false end
			if line:match("^%s*%-%-") then return false end
			if line:find("Logger.", 1, true) then return false end
			return true
		end

		helpers.it("the detector actually fires on the shape it forbids", function()
			-- Without this the scan below could be green because it detects
			-- nothing at all, rather than because nothing is wrong.
			helpers.assert_true(violates([[local cmd = string.format("pgrep -x %q", name)]]),
				"a %q interpolation in code must be flagged")
			helpers.assert_true(not violates([[Logger.error(LOG, "failed %q", path)]]),
				"a %q in a log message is Lua-literal quoting, which is correct there")
			helpers.assert_true(not violates([[--- the previous string.format("%q") form]]),
				"a comment describing the bug is not the bug")
			helpers.assert_true(not violates([[local safe = Shell.quote(name)]]),
				"the fixed shape must not be flagged")
		end)

		helpers.it("no driver source file composes a command with %q", function()
			local root = helpers.driver_root()
			local is_windows = package.config:sub(1, 1) == "\\"
			local list_cmd
			if is_windows then
				list_cmd = string.format('cmd /c dir /b /s /a-d "%s"', root:gsub("/", "\\"))
			else
				list_cmd = string.format("find %s -type f -name '*.lua'", Shell.quote(root))
			end

			local files, listing = {}, Shell.exec(list_cmd)
			for line in listing:gmatch("[^\r\n]+") do
				local path = line:gsub("\\", "/")
				-- tests/ legitimately uses %q in assertion messages, and vendor/
				-- is third-party source this driver does not author.
				if path:match("%.lua$")
					and not path:find("/tests/", 1, true)
					and not path:find("/vendor/", 1, true)
				then
					files[#files + 1] = path
				end
			end

			helpers.assert_true(#files >= 20, string.format(
				"the scan found only %d driver file(s) — an empty file list would make this test unfalsifiable", #files))

			local offenders = {}
			for _, path in ipairs(files) do
				local fh = io.open(path, "r")
				if fh then
					local n = 0
					for line in fh:lines() do
						n = n + 1
						if violates(line) then
							offenders[#offenders + 1] = string.format("%s:%d  %s", path, n, line:match("^%s*(.-)%s*$"))
						end
					end
					fh:close()
				end
			end

			helpers.assert_eq(#offenders, 0, string.format(
				"string.format('%%q') is a Lua literal quoter — inside the double quotes it emits, $VAR, `cmd` and $( ) all still run. Use shell_runner.quote(). Offending line(s):\n    %s",
				table.concat(offenders, "\n    ")))
		end)
	end)

end)
