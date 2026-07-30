--- tests/meta/test_closure_before_local_nil_global.lua

--- ==============================================================================
--- MODULE: Closure-Binds-Nil-Global Ratchet Meta Test
--- DESCRIPTION:
--- Class-wide guard against the single bug class this driver has shipped THREE
--- separate times: a `local` whose initializer contains a closure that already
--- references that same `local`.
---
--- ROOT CAUSE ENCODED:
--- In Lua the scope of `local x = <expr>` begins AFTER the whole statement, so a
--- closure written inside `<expr>` does not capture `x` as an upvalue — the name
--- resolves to the global `_G.x`, which is nil. The code reads perfectly and the
--- value is nil at call time.
---
---     local task = hs.task.new(bin, function() _pinned[task] = nil end, args)
---
--- `_pinned[nil] = nil` then raises "table index is nil" INSIDE an async
--- callback, where hs.task's internal pcall swallows it and the file logger
--- never sees it: the rest of the callback body simply never runs. That is how
--- `api_ollama`'s temp-file cleanup, the F10 download fix and F-CRIT-2 (which
--- left self-update completely dead) all shipped green.
---
--- The only correct shape is the two-line split, forward-declaring the name so
--- the closure captures a real upvalue:
---
---     local task
---     task = hs.task.new(bin, function() if task then _pinned[task] = nil end end, args)
---
--- Every site is fixed today, so this guard is green on arrival: it exists purely
--- to make the FOURTH recurrence fail CI instead of failing a user silently. It
--- scans the whole driver rather than the two folders where the bug happened,
--- because the three known sites lived in three different subtrees.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Every subtree that ships in the driver. `adapters/` holds the hs.task GC pins,
-- `ui/` the models managers, `modules/` the API clients — the class has bitten in
-- all three, so none of them may be left out.
local SOURCE_DIRS = { "adapters", "lib", "modules", "ui" }

-- Root-level sources that no subtree walk would reach.
local ROOT_FILES = { "init.lua" }

-- The driver is ~190 Lua files; a walk returning far fewer means the enumeration
-- broke and the ratchet silently stopped guarding anything.
local MIN_EXPECTED_FILES = 100

-- Reserved words can never be a declared local name, so they terminate the
-- comma-separated name list of a `local` statement.
local LUA_KEYWORDS = {
	["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
	["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
	["function"] = true, ["goto"] = true, ["if"] = true, ["in"] = true,
	["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
	["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true,
	["until"] = true, ["while"] = true,
}

-- Keywords that open a block and are therefore balanced by `end` / `until`.
-- `elseif` closes the block its preceding `then` opened and its own `then`
-- reopens one, so the pair nets out to zero.
local BLOCK_OPENERS = { ["function"] = true, ["do"] = true, ["then"] = true, ["repeat"] = true }
local BLOCK_CLOSERS = { ["end"] = true, ["until"] = true, ["elseif"] = true }





-- ====================================
-- ====================================
-- ======= 1/ Source Collection =======
-- ====================================
-- ====================================

--- Recursively lists every driver .lua file under a subtree.
--- @param dir string Absolute directory to walk.
--- @param out table Accumulator of absolute paths.
local function collect(dir, out)
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /s /a-d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("find '%s' -type f -name '*.lua'", dir)
	end
	local pipe = io.popen(cmd)
	if not pipe then return end
	for raw_line in pipe:lines() do
		local line = raw_line:gsub("%s+$", ""):gsub("\\", "/")
		-- Vendored code is not ours to fix, and tests/ is not shipped.
		if line:match("%.lua$") and not line:match("/vendor/") and not line:match("/tests/") then
			out[#out + 1] = line
		end
	end
	pipe:close()
end

--- Reads a whole file, returning nil when it cannot be opened.
--- @param path string Absolute path.
--- @return string|nil
local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local src = fh:read("*a")
	fh:close()
	return src
end





-- ===================================
-- ===================================
-- ======= 2/ Pattern Detector =======
-- ===================================
-- ===================================

--- Blanks out comments and string literals while preserving the exact byte
--- length and every newline, so positions and line numbers stay valid.
--- Without this, a docstring or a `"local x = function() x end"` literal would
--- be indistinguishable from real code — the trap that already made one guard on
--- this driver report phantom sites.
--- @param src string Raw Lua source.
--- @return string Source with comments and string bodies replaced by spaces.
local function mask(src)
	local out, i, n = {}, 1, #src
	while i <= n do
		local c = src:sub(i, i)
		if c == "-" and src:sub(i + 1, i + 1) == "-" then
			local eqs = src:match("^%-%-%[(=*)%[", i)
			if eqs then
				local close = "]" .. eqs .. "]"
				local found = src:find(close, i, true)
				local stop = found and (found + #close - 1) or n
				for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
				i = stop + 1
			else
				local eol = src:find("\n", i, true) or (n + 1)
				for _ = i, eol - 1 do out[#out + 1] = " " end
				i = eol
			end
		elseif c == '"' or c == "'" then
			local quote = c
			out[#out + 1] = " "
			i = i + 1
			while i <= n do
				local ch = src:sub(i, i)
				if ch == "\\" then
					out[#out + 1] = " "
					local nxt = src:sub(i + 1, i + 1)
					if nxt ~= "" then out[#out + 1] = (nxt == "\n") and "\n" or " " end
					i = i + 2
				elseif ch == quote then
					out[#out + 1] = " "
					i = i + 1
					break
				elseif ch == "\n" then
					out[#out + 1] = "\n"
					i = i + 1
					break
				else
					out[#out + 1] = " "
					i = i + 1
				end
			end
		elseif c == "[" and src:match("^%[=*%[", i) then
			local eqs = src:match("^%[(=*)%[", i)
			local close = "]" .. eqs .. "]"
			local found = src:find(close, i, true)
			local stop = found and (found + #close - 1) or n
			for k = i, stop do out[#out + 1] = (src:sub(k, k) == "\n") and "\n" or " " end
			i = stop + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return table.concat(out)
end

--- Finds the last byte of the statement whose initializer starts at `from`.
--- Walks brackets and block keywords; a statement can only continue past a
--- newline while something is still open, which is exactly what lets a closure
--- span lines.
--- @param masked string Comment- and string-masked source.
--- @param from number Index of the `=` opening the initializer.
--- @return number Index of the last byte belonging to the statement.
local function statement_end(masked, from)
	local depth, i, n = 0, from, #masked
	while i <= n do
		local c = masked:sub(i, i)
		if c:match("[%a_]") then
			local word = masked:match("^[%a_][%w_]*", i)
			if BLOCK_OPENERS[word] then depth = depth + 1
			elseif BLOCK_CLOSERS[word] then depth = depth - 1 end
			i = i + #word
			if depth < 0 then return i - 1 end
		elseif c == "(" or c == "[" or c == "{" then
			depth = depth + 1
			i = i + 1
		elseif c == ")" or c == "]" or c == "}" then
			depth = depth - 1
			i = i + 1
			if depth < 0 then return i - 1 end
		elseif c == "\n" then
			if depth <= 0 then return i - 1 end
			i = i + 1
		else
			i = i + 1
		end
	end
	return n
end

--- Reports whether `name` is read as a VARIABLE anywhere in `body`.
--- A hit preceded by "." or ":" is a field or method name (`win:title()` next to
--- a `local ok, title` binding) and carries none of the hazard — treating those
--- as references is what made a first cut of this scan report 21 phantom sites.
--- @param body string Masked source fragment.
--- @param name string Identifier to look for.
--- @return boolean
local function references_variable(body, name)
	local init = 1
	while true do
		local s, e = body:find("%f[%w_]" .. name .. "%f[^%w_]", init)
		if not s then return false end
		local prev = body:sub(s - 1, s - 1)
		if prev ~= "." and prev ~= ":" then
			return true
		end
		init = e + 1
	end
end

--- Scans one Lua source for `local NAME = <expr containing a closure using NAME>`.
--- @param src string Raw Lua source.
--- @return table List of { line = number, name = string }.
local function scan_source(src)
	local masked = mask(src)
	local hits = {}
	local pos = 1
	while true do
		local decl_s, decl_e = masked:find("%f[%w]local%s+", pos)
		if not decl_s then break end
		pos = decl_e + 1

		-- Collect the comma-separated name list. `local function f` is sugar for
		-- `local f; f = function`, so it is already correctly scoped and stops here.
		local names, p = {}, decl_e + 1
		while true do
			local word = masked:match("^[%a_][%w_]*", p)
			if not word or LUA_KEYWORDS[word] then break end
			names[#names + 1] = word
			p = p + #word
			local after_comma = masked:match("^%s*,%s*()", p)
			if after_comma then p = after_comma else break end
		end
		if #names > 0 then
			local eq_pos = masked:match("^%s*=()", p)
			-- "==" would be a comparison, not an assignment.
			if eq_pos and masked:sub(eq_pos, eq_pos) ~= "=" then
				local extent = masked:sub(eq_pos, statement_end(masked, eq_pos))

				-- Locate the first closure and collect every closure's parameter
				-- names: a parameter of the same name shadows the outer binding and
				-- makes the reference harmless.
				local first_body_at, params, q = nil, {}, 1
				while true do
					local fn_s, fn_e = extent:find("%f[%w]function%f[%W]", q)
					if not fn_s then break end
					local plist_s, plist_e = extent:find("^%s*[%w_%.:]*%s*%b()", fn_e + 1)
					if not first_body_at then first_body_at = plist_e or fn_e end
					if plist_s then
						for param in extent:sub(plist_s, plist_e):gmatch("[%a_][%w_]*") do
							params[param] = true
						end
					end
					q = fn_e + 1
				end

				if first_body_at then
					local body = extent:sub(first_body_at + 1)
					for _, name in ipairs(names) do
						if not params[name] and references_variable(body, name) then
							local _, newlines = masked:sub(1, eq_pos):gsub("\n", "")
							hits[#hits + 1] = { line = newlines + 1, name = name }
						end
					end
				end
			end
		end
	end
	return hits
end





-- ======================================
-- ======================================
-- ======= 3/ Detector Self-Check =======
-- ======================================
-- ======================================

-- A ratchet that is green because it detects nothing is worse than no ratchet at
-- all, so the detector is first proved sensitive against the exact shapes that
-- shipped, and blind to the shapes that are correct.

local FIXTURE_TASK_PIN_BUGGY = [==[
local function spawn(bin, args)
	local task = hs.task.new(bin, function(code)
		M._active_tasks[task] = nil
		return code
	end, args)
	task:start()
end
]==]

local FIXTURE_TASK_PIN_FIXED = [==[
local function spawn(bin, args)
	local task
	task = hs.task.new(bin, function(code)
		if task then M._active_tasks[task] = nil end
		return code
	end, args)
	task:start()
end
]==]

local FIXTURE_TIMER_HANDLE_BUGGY = [==[
local handle = TimerScheduler.after(WARMUP_TIMEOUT_SEC, function()
	handle = nil
	warmup_finished()
end)
]==]

local FIXTURE_METHOD_NAME_COLLISION = [==[
local ok_t, title = pcall(function() return win:title() end)
local ok_m, map = pcall(function() return hs.keycodes.map end)
]==]

local FIXTURE_SHADOWED_PARAMETER = [==[
local entry = registry.wrap(function(entry)
	return entry.value
end)
]==]

local FIXTURE_MENTIONED_IN_TEXT = [==[
-- local task = hs.task.new(bin, function() pins[task] = nil end, args)
local warning = "local task = fn(function() pins[task] = nil end)"
]==]

helpers.describe("closure-before-local detector is sensitive", function()

	helpers.it("flags the hs.task GC-pin shape that shipped three times", function()
		local hits = scan_source(FIXTURE_TASK_PIN_BUGGY)
		helpers.assert_eq(#hits, 1,
			"the detector must flag `local task = hs.task.new(…, function() …[task]… end)`")
		helpers.assert_eq(hits[1].name, "task", "the flagged name must be the mis-scoped local")
	end)

	helpers.it("flags a multi-line timer handle cleared from its own callback", function()
		helpers.assert_eq(#scan_source(FIXTURE_TIMER_HANDLE_BUGGY), 1,
			"a closure spanning several lines must still be attributed to its own statement")
	end)

	helpers.it("accepts the forward-declared two-line split", function()
		helpers.assert_eq(#scan_source(FIXTURE_TASK_PIN_FIXED), 0,
			"`local task` followed by `task = …` is the correct shape and must stay green")
	end)

	helpers.it("ignores a method or field that merely shares the local's name", function()
		helpers.assert_eq(#scan_source(FIXTURE_METHOD_NAME_COLLISION), 0,
			"`win:title()` next to `local ok, title` is a method name, not a reference")
	end)

	helpers.it("ignores a closure parameter that shadows the local", function()
		helpers.assert_eq(#scan_source(FIXTURE_SHADOWED_PARAMETER), 0,
			"a parameter of the same name shadows the outer binding and is harmless")
	end)

	helpers.it("ignores the pattern when it appears in a comment or a string", function()
		helpers.assert_eq(#scan_source(FIXTURE_MENTIONED_IN_TEXT), 0,
			"documenting the foot-gun must not fail CI — comments and literals are masked")
	end)

end)





-- ======================================
-- ======================================
-- ======= 4/ Driver-Wide Ratchet =======
-- ======================================
-- ======================================

helpers.describe("no driver local is captured by a closure in its own initializer", function()

	helpers.it("every driver .lua file is free of the closure-binds-nil-global shape", function()
		local root  = helpers.driver_root()
		local files = {}
		for _, dir in ipairs(SOURCE_DIRS) do collect(root .. dir, files) end
		for _, rel in ipairs(ROOT_FILES) do
			if read_file(root .. rel) then files[#files + 1] = root .. rel end
		end

		helpers.assert_true(#files >= MIN_EXPECTED_FILES, string.format(
			"the source walk found only %d file(s) — under %d the ratchet guards nothing, "
			.. "so the enumeration itself is broken", #files, MIN_EXPECTED_FILES))

		local offenders = {}
		for _, path in ipairs(files) do
			local src = read_file(path)
			if src then
				for _, hit in ipairs(scan_source(src)) do
					offenders[#offenders + 1] = string.format("%s:%d (local %s)",
						path:gsub("^.*/macos/", ""), hit.line, hit.name)
				end
			end
		end

		helpers.assert_true(#offenders == 0, string.format(
			"%d local(s) are referenced by a closure inside their own initializer. In Lua that "
			.. "reference resolves to the nil GLOBAL, and the resulting error is swallowed by "
			.. "the async pcall around the callback, so the rest of the callback body never "
			.. "runs and nothing is logged. Split the declaration in two — `local x` then "
			.. "`x = …` — and nil-guard the use inside the closure: %s",
			#offenders, table.concat(offenders, ", ")))
	end)

end)
