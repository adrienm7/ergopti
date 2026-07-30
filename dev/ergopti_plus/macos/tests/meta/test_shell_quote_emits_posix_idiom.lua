--- tests/meta/test_shell_quote_emits_posix_idiom.lua

--- ==============================================================================
--- MODULE: Regression — shell_quote must emit the real POSIX idiom
---         (shell-quote-posix-idiom)
--- DESCRIPTION:
--- The canonical quoting helper produced `'a'''b'` for the input `a'b`. There is
--- no backslash anywhere in that: /bin/sh reads it as three adjacent quoted runs
--- and collapses it to `ab`. Worse, for `a'$(id)'b` it produced
--- `'a'''$(id)'''b'`, which places `$(id)` in an UNQUOTED command-substitution
--- context — the shell injection this helper exists to prevent.
---
--- ROOT CAUSE ENCODED: inside a Lua double-quoted literal `\'` is simply `'`, so
--- the source `"'\''"` is the 3-byte string `'''`, not the 4-byte
--- close-escape-reopen idiom `'\''` (which must be spelled `"'\\''"`). The
--- docstring above the function described the correct idiom; the code did not
--- implement it. Exactly three sites in the tree carried the one-backslash
--- spelling while about eighty-six carried the correct one — the sibling
--- karabiner/generator.lua being right is what proves the intent.
---
--- WHY IT SURVIVED: default paths contain no apostrophe, so every nominal boot
--- behaves perfectly. It takes a config directory or a username with an
--- apostrophe (`/Users/O'Brien/…`) to see it, and then it is a wrong directory
--- rather than an error. The existing guard, test_shell_quoting_not_lua_q, only
--- banned string.format("%q") and never asserted what shell_quote actually
--- returns — it was the widening commit that routed forty-one call sites into a
--- helper nobody had checked the output of.
---
--- The assertions below are therefore BYTE-LEVEL. A test that compared Lua
--- string literals could be written with the same one-backslash mistake and
--- would then agree with the bug; counting byte 92 cannot be fooled that way.
--- ==============================================================================

local helpers = require("tests.helpers")

local BACKSLASH = string.char(92)
local QUOTE = string.char(39)

--- Renders a string as space-separated hex bytes, so a failure message shows
--- exactly what was produced rather than something a terminal may re-render.
local function hex(s)
	local out = {}
	for i = 1, #s do
		out[#out + 1] = string.format("%02x", s:byte(i))
	end
	return table.concat(out, " ")
end




-- =========================================================================
-- =========================================================================
-- ======= 1/ The helper emits a real escaped quote ========================
-- =========================================================================
-- =========================================================================

helpers.describe("shell_quote: emits the POSIX close-escape-reopen idiom", function()
	helpers.it("an embedded quote produces a backslash (byte 92)", function()
		local tu = require("text_utils")
		local got = tu.shell_quote("a" .. QUOTE .. "b")

		helpers.assert_true(
			got:find(BACKSLASH, 1, true) ~= nil,
			"shell_quote produced no backslash at all: " .. got .. " (bytes: " .. hex(got) .. "). "
				.. "Without one the embedded quote merely closes and reopens the quoted run, so /bin/sh "
				.. "collapses the value and any $(...) inside it lands in an unquoted, EXECUTED context"
		)

		-- The exact expected bytes:  ' a ' \ ' ' b '
		local expected = QUOTE .. "a" .. QUOTE .. BACKSLASH .. QUOTE .. QUOTE .. "b" .. QUOTE
		helpers.assert_eq(
			got,
			expected,
			"shell_quote must emit the 4-byte close-escape-reopen idiom around an embedded quote. "
				.. "expected bytes: " .. hex(expected) .. " | got: " .. hex(got)
		)
	end)

	helpers.it("a command substitution stays inside the quoted run", function()
		local tu = require("text_utils")
		local payload = "a" .. QUOTE .. "$(id)" .. QUOTE .. "b"
		local got = tu.shell_quote(payload)

		-- Walk the result and track whether we are inside a single-quoted run.
		-- The "$" of the substitution must be found while quoted; if it is not,
		-- the shell would execute it.
		local quoted, i, dollar_is_quoted = false, 1, nil
		while i <= #got do
			local c = got:sub(i, i)
			if c == BACKSLASH then
				i = i + 2 -- an escaped character, outside any quoted run
			else
				if c == QUOTE then
					quoted = not quoted
				elseif c == "$" and dollar_is_quoted == nil then
					dollar_is_quoted = quoted
				end
				i = i + 1
			end
		end

		helpers.assert_true(
			dollar_is_quoted == true,
			"the $ of a command substitution must remain inside a quoted run. Got: "
				.. got .. " (bytes: " .. hex(got) .. "). Outside one, /bin/sh executes it — "
				.. "which is exactly the injection this helper exists to prevent"
		)
	end)

	helpers.it("a value with no quote is simply wrapped", function()
		local tu = require("text_utils")
		local got = tu.shell_quote("plain/path")
		helpers.assert_eq(
			got,
			QUOTE .. "plain/path" .. QUOTE,
			"the common case must stay a plain single-quoted wrap — this is what makes the bug invisible on default paths"
		)
	end)

	helpers.it("a non-string value is coerced, not rejected", function()
		local tu = require("text_utils")
		helpers.assert_eq(
			tu.shell_quote(42),
			QUOTE .. "42" .. QUOTE,
			"callers pass numbers (ports, sizes); the helper coerces with tostring by contract"
		)
	end)
end)




-- =========================================================================
-- =========================================================================
-- ======= 2/ No site in the tree carries the broken spelling ==============
-- =========================================================================
-- =========================================================================

--- Scans driver Lua source for a gsub whose replacement escapes a quote with
--- exactly ONE backslash byte. Counting bytes on the SOURCE LINE is the whole
--- point: a check written as a Lua string comparison would itself be subject to
--- the same escaping mistake, and would then match the bug rather than catch it.
helpers.describe("shell_quote: the broken spelling exists nowhere in the tree", function()
	helpers.it("no quote-escaping gsub uses a single backslash", function()
		local src_path = debug.getinfo(1, "S").source:match("^@(.+)$")
		local driver_root = src_path:match("^(.+)[/\\]tests[/\\]") or "."
		local shared_root = driver_root .. "/../_shared/lua"

		-- Directories that ship shell-invoking code for this driver.
		local roots = {
			driver_root .. "/adapters",
			driver_root .. "/lib",
			driver_root .. "/modules",
			driver_root .. "/ui",
			shared_root,
		}

		local offenders = {}
		local scanned = 0

		local function scan_file(path)
			local fh = io.open(path, "r")
			if not fh then
				return
			end
			local src = fh:read("*a")
			fh:close()
			scanned = scanned + 1
			local lineno = 0
			for line in (src .. "\n"):gmatch("([^\n]*)\n") do
				lineno = lineno + 1
				-- A gsub replacing a single quote, in either quoting style.
				if line:find("gsub", 1, true) and line:find(QUOTE, 1, true) then
					-- Extract the replacement argument's raw source text.
					local repl = line:match("gsub%b()")
					if repl and repl:find(QUOTE .. BACKSLASH, 1, true) then
						-- Count backslash BYTES in the replacement text. One is
						-- the bug; two is the correct escaped form.
						local n = select(2, repl:gsub(BACKSLASH, ""))
						if n == 1 then
							offenders[#offenders + 1] = path .. ":" .. lineno .. "  " .. line:gsub("^%s+", "")
						end
					end
				end
			end
		end

		local function scan_dir(dir)
			-- Portable directory walk: `lfs` when present, else shell out.
			local ok, lfs = pcall(require, "lfs")
			if ok and lfs and lfs.dir then
				local ok2 = pcall(function()
					for entry in lfs.dir(dir) do
						if entry ~= "." and entry ~= ".." then
							local full = dir .. "/" .. entry
							local attr = lfs.attributes(full)
							if attr and attr.mode == "directory" then
								scan_dir(full)
							elseif entry:sub(-4) == ".lua" then
								scan_file(full)
							end
						end
					end
				end)
				if ok2 then
					return
				end
			end
			local sep = package.config:sub(1, 1)
			local cmd = (sep == "\\")
					and ('dir /b /s "' .. dir:gsub("/", "\\") .. '\\*.lua" 2>nul')
				or ('find "' .. dir .. '" -name "*.lua" -type f 2>/dev/null')
			local pipe = io.popen(cmd)
			if not pipe then
				return
			end
			for line in pipe:lines() do
				scan_file((line:gsub("\r$", "")))
			end
			pipe:close()
		end

		for _, dir in ipairs(roots) do
			scan_dir(dir)
		end

		-- Non-vacuity floor: this driver has hundreds of Lua files. A scan that
		-- reached none of them would report the whole tree clean.
		helpers.assert_true(
			scanned >= 50,
			"the scan must reach the driver sources (only " .. scanned .. " file(s) read) — a scan that opens nothing cannot fail"
		)

		helpers.assert_eq(
			#offenders,
			0,
			"a quote-escaping gsub is written with ONE backslash, which produces "
				.. QUOTE .. QUOTE .. QUOTE
				.. " rather than the POSIX idiom and re-opens shell injection:\n  "
				.. table.concat(offenders, "\n  ")
		)
	end)
end)
