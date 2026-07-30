--- tests/unit/meta/test_applescript_escape_whole_class.lua

--- ==============================================================================
--- MODULE: Regression — every AppleScript literal escapes through ONE helper
--- DESCRIPTION:
--- `text_utils.applescript_escape` doubles the backslash BEFORE escaping the
--- quote, and that order is the whole point: AppleScript reads `\` as an escape
--- introducer, so a hand-rolled `value:gsub('"', '\\"')` leaves every backslash
--- live. `/Users/x/My\Folder` reaches the interpreter as `/Users/x/MyFolder`, the
--- `as alias` coercion fails, and the `on error` branch returns "" — the action
--- silently does nothing. Worse, the quote-only pass can itself MANUFACTURE the
--- injection it was added to prevent: escaping `"` to `\"` on a value that
--- already ends in `\` produces `\\"`, which closes the literal.
---
--- ROOT CAUSE ENCODED:
--- Not "three files forgot to call the helper" but "the escape rule had no owner
--- the checker could see". The pre-existing guard
--- (tests/unit/lib/test_applescript_escaping.lua) enumerates its call sites BY
--- SYMBOL NAME — `pickConfigDir`, `_terminal_cmd` — and
--- `helpers.read_driver_source(symbol)` returns only the files whose body
--- contains that literal string. Those are exactly the two files that were
--- already fixed, so the checker's corpus was, by construction, the set of sites
--- that could not fail. This guard derives its corpus from BEHAVIOUR instead:
--- every production file that runs AppleScript at all.
---
--- GRANULARITY IS DELIBERATE: the rules below are per LINE, not per file. A
--- file-granular rule passes as soon as one site in the file is correct, which is
--- how this codebase has repeatedly shipped the one missed sibling
--- (project-ahk-invariant-incomplete-application).
--- ==============================================================================

local helpers = require("tests.helpers")

-- Directories that ship runtime code. `tests/` is excluded by the walker.
local SCANNED_DIRS = { "modules", "lib", "adapters", "ui" }

-- A file joins the corpus when it runs AppleScript at all — through
-- hs.osascript, through the /usr/bin/osascript binary, or through the
-- ShellRunner.applescript launcher. Anchored on behaviour rather than on a
-- symbol name, so a new AppleScript call site cannot opt itself out.
local CORPUS_MARKERS = { "osascript", "applescript" }

-- The blessed helper. Any line naming it is compliant by definition.
local HELPER = "applescript_escape"

-- Escapes of a double quote, in both spellings Lua allows for the pattern
-- argument. A positive-control case below proves each of these really fires, so a
-- form nobody wrote yet cannot make this guard silently vacuous.
local QUOTE_ESCAPE = {
	[[gsub('"']],
	[[gsub("\""]],
}

-- The backslash pass. Its PRESENCE is not enough — it has to come first, which is
-- why the check below compares positions rather than membership. An inline
-- `value:gsub("\\", "\\\\"):gsub('"', '\\"')` is exactly what the helper does, so
-- it is compliant; the driver has three such lines that escape for JavaScript
-- rather than AppleScript and they are correct code, not offenders.
local BACKSLASH_ESCAPE = {
	[[gsub("\\"]],
	[[gsub('\\']],
}

--- Reports whether a line escapes a double quote without doubling the backslash
--- FIRST — the shape that silently eats every backslash in the value.
--- @param line string A comment-stripped source line.
--- @return boolean
local function escapes_quote_before_backslash(line)
	if line:find(HELPER, 1, true) then return false end

	local q_pos
	for _, form in ipairs(QUOTE_ESCAPE) do
		local p = line:find(form, 1, true)
		if p and (not q_pos or p < q_pos) then q_pos = p end
	end
	if not q_pos then return false end

	local bs_pos
	for _, form in ipairs(BACKSLASH_ESCAPE) do
		local p = line:find(form, 1, true)
		if p and (not bs_pos or p < bs_pos) then bs_pos = p end
	end

	-- No backslash pass at all, or one that runs after the quote pass. Running it
	-- after is not merely incomplete: the quote pass has already introduced
	-- backslashes of its own, which the later pass then doubles, corrupting every
	-- escaped quote in the value.
	return (bs_pos == nil) or (bs_pos > q_pos)
end

-- Lua's %q escapes for a LUA literal. It happens to agree with AppleScript on
-- `"` and `\`, which is why these sites are not live defects — but it diverges on
-- control characters, emits `\ddd` decimal escapes AppleScript cannot read, and
-- supplies its own surrounding quotes. Using it here is a wrong-layer choice that
-- reads as deliberate and would mislead the next editor.
local APPLESCRIPT_LITERAL_WITH_Q = {
	"POSIX file %q",
	"display dialog %q",
	"tell application %q",
	"with title %q",
}




-- ==================================================================
-- ==================================================================
-- ======= 1/ Corpus: every file that runs AppleScript ==============
-- ==================================================================
-- ==================================================================

--- Collects every production `.lua` under the scanned directories.
--- @return table Array of paths relative to the driver root.
local function all_sources()
	local root = helpers.driver_root()
	local out  = {}

	local ok_lfs, lfs = pcall(require, "lfs")
	if ok_lfs then
		local function walk(dir)
			for entry in lfs.dir(root .. dir) do
				if entry ~= "." and entry ~= ".." then
					local rel  = dir .. entry
					local attr = lfs.attributes(root .. rel)
					if attr and attr.mode == "directory" then
						walk(rel .. "/")
					elseif entry:match("%.lua$") then
						out[#out + 1] = rel
					end
				end
			end
		end
		for _, d in ipairs(SCANNED_DIRS) do walk(d .. "/") end
		return out
	end

	-- Shell fallback. It must cover the SAME set as the lfs branch: a meta test on
	-- this driver was once green on machines without lfs and blind on machines
	-- with it, because only one branch reached part of the tree.
	local sep = package.config:sub(1, 1)
	local cmd = (sep == "\\")
		and ('cmd /c dir /b /s /a-d "' .. root:gsub("/", "\\") .. '*.lua"')
		or ("find '" .. root .. "' -type f -name '*.lua'")
	local pipe = io.popen(cmd)
	if not pipe then return out end
	for line in pipe:lines() do
		local rel = line:gsub("\\", "/"):gsub(".*/macos/", "")
		for _, d in ipairs(SCANNED_DIRS) do
			if rel:sub(1, #d + 1) == d .. "/" and not rel:find("/tests/", 1, true) then
				out[#out + 1] = rel
				break
			end
		end
	end
	pipe:close()
	return out
end


--- Reads a file and strips its comments.
--- @param abs_path string
--- @return string|nil
local function read_code(abs_path)
	local fh = io.open(abs_path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	-- Comments are stripped so prose about the broken shape is not mistaken for
	-- the broken shape. This test's own header names every pattern it forbids.
	return (src:gsub("%-%-[^\n]*", ""))
end


--- Builds the corpus: relative path → comment-stripped source.
--- @return table map, number count
local function applescript_corpus()
	local root = helpers.driver_root()
	local map, n = {}, 0
	for _, rel in ipairs(all_sources()) do
		local code = read_code(root .. rel)
		if code then
			local lowered = code:lower()
			for _, marker in ipairs(CORPUS_MARKERS) do
				if lowered:find(marker, 1, true) then
					map[rel] = code
					n = n + 1
					break
				end
			end
		end
	end
	return map, n
end


helpers.describe("AppleScript escaping: one helper owns the rule, driver-wide", function()

	helpers.it("no AppleScript-running file escapes a quote before doubling the backslash", function()
		local corpus, n = applescript_corpus()
		helpers.assert_true(n >= 10,
			"the corpus must actually find the driver's AppleScript call sites; a broken "
			.. "walker or marker would make every assertion below vacuous")

		local offenders = {}
		for rel, code in pairs(corpus) do
			local line_no = 0
			for line in (code .. "\n"):gmatch("([^\n]*)\n") do
				line_no = line_no + 1
				if escapes_quote_before_backslash(line) then
					table.insert(offenders, string.format("%s:%d", rel, line_no))
				end
			end
		end
		table.sort(offenders)

		helpers.assert_eq(#offenders, 0,
			"AppleScript reads `\\` as an escape introducer, so the backslash pass must run "
			.. "BEFORE the quote pass — which is exactly what applescript_escape does and "
			.. "what a quote-only gsub cannot. These sites drop every backslash in the value "
			.. "and can turn a trailing backslash into a literal-closing `\\\\\"`: "
			.. table.concat(offenders, ", "))
	end)

	helpers.it("no AppleScript literal is filled with Lua's %q", function()
		local corpus = applescript_corpus()
		local offenders = {}
		for rel, code in pairs(corpus) do
			local line_no = 0
			for line in (code .. "\n"):gmatch("([^\n]*)\n") do
				line_no = line_no + 1
				for _, form in ipairs(APPLESCRIPT_LITERAL_WITH_Q) do
					if line:find(form, 1, true) then
						table.insert(offenders, string.format("%s:%d", rel, line_no))
						break
					end
				end
			end
		end
		table.sort(offenders)

		helpers.assert_eq(#offenders, 0,
			"%q escapes for a LUA literal: it agrees with AppleScript on the quote and the "
			.. "backslash but not on control characters, it emits \\ddd decimal escapes "
			.. "AppleScript cannot read, and it brings its own surrounding quotes. Use "
			.. "\"%s\" with applescript_escape so the layer is stated rather than "
			.. "coincidental: " .. table.concat(offenders, ", "))
	end)

	helpers.it("no AppleScript is built with a bare string.format", function()
		-- The rule the two cases above cannot express, and the reason the fix is
		-- structural rather than another round of remembering. menu_paths built its
		-- folder picker with the PATH escaped and the PROMPT raw, inside ONE
		-- string.format call: nothing about that line's shape is wrong, the argument
		-- list is simply one escape short. No shape-based check can see that, and an
		-- earlier version of THIS case proved it — it looked for applescript_escape
		-- anywhere in the call, so reverting just the prompt left it green.
		--
		-- applescript_format escapes every string argument it receives, so the
		-- decision moves from "did each value get escaped?" (invisible) to "which
		-- formatter was used?" (a single token, right here).
		local corpus = applescript_corpus()
		local offenders, examined = {}, 0

		-- AppleScript keywords, so the same placeholder spellings appearing in shell
		-- strings, log messages and generated JavaScript are left alone: those have
		-- their own, different and correct, escaping rules.
		local AS_KEYWORDS = {
			"choose folder", "display dialog", "do shell script", "tell application",
			"POSIX file", "findSource", "with prompt", "TISPropertyInputSourceID",
		}

		for rel, code in pairs(corpus) do
			local from = 1
			while true do
				-- Deliberately anchored on "string.format(" preceded by a character
				-- that cannot be part of an identifier, so "applescript_format(" and
				-- any other *_format( wrapper is not mistaken for the bare call.
				local s_at = code:find("string%.format%(", from)
				if not s_at then break end
				local prev = (s_at > 1) and code:sub(s_at - 1, s_at - 1) or " "
				local is_bare = not prev:match("[%w_.]")

				-- Walk to the matching close paren so a multi-line long-bracket script
				-- is read as ONE call, which is how every one of them is written.
				local depth, i = 0, s_at + #"string.format" - 1
				while i <= #code do
					local c = code:sub(i, i)
					if c == "(" then depth = depth + 1
					elseif c == ")" then
						depth = depth - 1
						if depth == 0 then break end
					end
					i = i + 1
				end
				local call = code:sub(s_at, math.min(i, #code))

				local has_placeholder = call:find('"%s"', 1, true) ~= nil
					or call:find('\\"%s\\"', 1, true) ~= nil
				local has_keyword = false
				for _, kw in ipairs(AS_KEYWORDS) do
					if call:find(kw, 1, true) then has_keyword = true break end
				end

				-- A call whose text already contains applescript_format is compliant:
				-- the only AppleScript literal inside it is the one that formatter
				-- produces. This matters for the genuinely nested site in
				-- ui/download_window, where the OUTER string.format builds a /bin/sh
				-- command line (its %s filled by shell_quote) and the AppleScript
				-- literal belongs to the inner call. Scanning the balanced call text
				-- cannot tell the two apart, so the inner formatter is taken as proof.
				--
				-- Known limit, stated rather than hidden: a single call mixing a
				-- compliant inner applescript_format with a separate raw AppleScript
				-- literal would pass here. The two escaping rules above still apply to
				-- it line by line.
				local delegates = call:find("applescript_format", 1, true) ~= nil

				if is_bare and has_placeholder and has_keyword and not delegates then
					examined = examined + 1
					local line_no = select(2, code:sub(1, s_at):gsub("\n", "")) + 1
					table.insert(offenders, string.format("%s:%d", rel, line_no))
				end
				from = s_at + 1
			end
		end
		table.sort(offenders)

		helpers.assert_eq(#offenders, 0,
			"these build an AppleScript literal with a formatter that does not escape, so "
			.. "whether each interpolated value is safe depends on the caller remembering. "
			.. "Use text_utils.applescript_format: " .. table.concat(offenders, ", "))
	end)

	helpers.it("the bare-string.format detector really fires", function()
		-- Positive control for the case above, which asserts an ABSENCE and would
		-- otherwise be indistinguishable from a detector that matches nothing.
		local broken = 'local s = string.format([[choose folder with prompt "%s"]], p)'
		local fixed  = 'local s = text_utils.applescript_format([[choose folder with prompt "%s"]], p)'

		--- Mirrors the classifier above on a single-call snippet.
		--- @param code string
		--- @return boolean flagged
		local function flags(code)
			local s_at = code:find("string%.format%(")
			if not s_at then return false end
			local prev = (s_at > 1) and code:sub(s_at - 1, s_at - 1) or " "
			if prev:match("[%w_.]") then return false end
			return code:find('"%s"', 1, true) ~= nil and code:find("choose folder", 1, true) ~= nil
		end

		helpers.assert_true(flags(broken), "the bare call must be flagged")
		helpers.assert_true(not flags(fixed),
			"and applescript_format must NOT be, or the guard would forbid its own fix")
	end)

	helpers.it("the detectors fire on every shape they claim to catch", function()
		-- Positive control. Without it, a typo in any pattern above would make the
		-- two assertions pass over the very sites they exist to find — the vacuous
		-- absence assertion this suite tracks as a false-green class.
		local samples = {
			-- Quote escaped with no backslash pass: the live defect shape.
			{ line = [[	local escaped = path:gsub('"', '\\"')]],                  flag = true },
			{ line = [[	local escaped = path:gsub("\"", "\\\"")]],                flag = true },
			-- Backslash pass present but AFTER the quote pass: worse than missing,
			-- because it doubles the backslashes the quote pass just introduced.
			{ line = [[	local e = p:gsub('"', '\\"'):gsub("\\", "\\\\")]],       flag = true },
			-- Wrong layer for an AppleScript literal.
			{ line = [[		set targetPath to POSIX file %q as alias]],           flag = true },
			{ line = [[	"display dialog %q with title %q", a, b)]],               flag = true },
			-- Correct inline escape, backslash first. Three real driver lines have
			-- this shape (JavaScript, not AppleScript) and must stay green.
			{ line = [[	local safe = line:gsub("\\", "\\\\"):gsub("\"", "\\\"")]], flag = false },
			{ line = [[	local escaped = text_utils.applescript_escape(p)]],       flag = false },
			{ line = [[	local safe = value:gsub("%s+", "")]],                     flag = false },
		}
		for _, sample in ipairs(samples) do
			local flagged = escapes_quote_before_backslash(sample.line)
			if not flagged then
				for _, form in ipairs(APPLESCRIPT_LITERAL_WITH_Q) do
					if sample.line:find(form, 1, true) then flagged = true break end
				end
			end
			helpers.assert_eq(flagged, sample.flag,
				"detector disagreed on: " .. sample.line)
		end
	end)

end)
