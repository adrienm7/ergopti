--- tests/meta/shutdown/test_no_broad_ollama_kill.lua

--- ==============================================================================
--- MODULE: No Broad Ollama Process Termination
--- DESCRIPTION:
--- Closes item 120: the macOS driver retires only the Ollama daemon it started
--- itself (api_ollama.stop_owned_server) and never signals Ollama processes by
--- name or by port. A user may run their own `ollama serve` (Ollama.app, a
--- terminal, a launch agent); a name or port sweep at quit or reload would kill
--- it and every model it holds.
---
--- FEATURES & RATIONALE:
--- 1. Every runtime translation unit (Lua, shell, Python, Swift, ...) is scanned
---    on its own, comments removed, so a sweep in a helper script cannot hide.
--- 2. Three shapes are refused: a command text that names a kill or process
---    lookup tool and Ollama (or its port 11434), an argument table that passes
---    a process pattern naming Ollama after `-f`, and a sweep record whose
---    `pattern` names Ollama.
--- 3. Mutant samples prove each shape is detected, so the guard can fail.
--- 4. The quit teardown is pinned to the owned retirement and to its two
---    non-Ollama helper sweeps.
--- ==============================================================================

local helpers = require("tests.helpers")
local RuntimeSources = require("tests.support.runtime_source_inventory")





-- ======================================
-- ======================================
-- ======= 1/ Broad Kill Detector =======
-- ======================================
-- ======================================

-- A command text that both names a process killer or lookup tool and Ollama.
local KILL_TOOL = "%f[%w_]([pk]?kill%w*)%f[^%w_]"
local LOOKUP_TOOL = { "pgrep", "lsof", "fuser" }

--- Drops line comments of the languages the inventory holds, keeping strings.
--- Only whole-line comments are removed: a trailing `--` or `#` may sit inside
--- a command string, and a false negative there is worse than a kept comment.
--- @param body string Translation unit text.
--- @return string code Text without whole-line comments.
local function without_line_comments(body)
	local kept = {}
	for line in (body .. "\n"):gmatch("([^\n]*)\n") do
		local trimmed = line:match("^%s*(.-)$")
		local comment = trimmed:sub(1, 2) == "--" or trimmed:sub(1, 2) == "//"
			or (trimmed:sub(1, 1) == "#" and trimmed:sub(1, 2) ~= "#!")
		kept[#kept + 1] = comment and "" or line
	end
	return table.concat(kept, "\n")
end

--- Whether one string literal is a command that signals or finds Ollama.
--- @param text string Literal content.
--- @return boolean broad
local function command_names_ollama(text)
	local lower = text:lower()
	if not (lower:find("ollama", 1, true) or lower:find("11434", 1, true)) then return false end
	for tool in lower:gmatch(KILL_TOOL) do
		if tool == "kill" or tool == "pkill" or tool == "killall" then return true end
	end
	for _, tool in ipairs(LOOKUP_TOOL) do
		if lower:find("%f[%w_]" .. tool .. "%f[^%w_]") then return true end
	end
	return false
end

--- Lists every broad Ollama termination shape found in one unit.
--- @param body string Translation unit text.
--- @return table offenders Short descriptions, empty when clean.
local function find_broad_kills(body)
	local code = without_line_comments(body)
	local offenders = {}
	for _, quote in ipairs({ '"', "'" }) do
		local pattern = quote .. "([^" .. quote .. "\n]*)" .. quote
		for literal in code:gmatch(pattern) do
			if command_names_ollama(literal) then offenders[#offenders + 1] = "command: " .. literal end
		end
	end
	-- An argument vector handing pkill/killall a full-command pattern.
	for vector in code:gmatch("%b{}") do
		if vector:find("[\"']%-%w*f[\"']") and vector:lower():find("[\"'][^\"']*ollama[^\"']*[\"']") then
			offenders[#offenders + 1] = "argument vector: " .. vector
		end
	end
	for vector in code:gmatch("%b[]") do
		local lower = vector:lower()
		if (lower:find("pkill", 1, true) or lower:find("killall", 1, true)) and lower:find("ollama", 1, true) then
			offenders[#offenders + 1] = "argument array: " .. vector
		end
	end
	for value in code:gmatch("pattern%s*=%s*[\"']([^\"']*)[\"']") do
		if value:lower():find("ollama", 1, true) then offenders[#offenders + 1] = "sweep pattern: " .. value end
	end
	return offenders
end





-- =============================
-- =============================
-- ======= 2/ Test Cases =======
-- =============================
-- =============================

helpers.describe("Item 120: no broad Ollama termination", function()
	helpers.it("the detector flags every broad shape and keeps owned and unrelated sweeps", function()
		local mutants = {
			'hs.execute("pkill -f ollama")',
			"run('/usr/bin/killall Ollama')",
			'cmd = "kill -9 $(pgrep -f \'ollama serve\')"',
			'cmd = "lsof -ti TCP:11434 | xargs kill -9"',
			'start_detached_sweep("x", PKILL_BIN, { "-9", "-f", "ollama serve" })',
			'{ label = "ollama", pattern = "ollama serve" },',
			'process.arguments = ["/usr/bin/pkill", "-f", "ollama"]',
		}
		for _, mutant in ipairs(mutants) do
			helpers.assert_true(#find_broad_kills(mutant) > 0, "the detector must flag: " .. mutant)
		end
		local clean = {
			'start_detached_sweep(sweep.label, PKILL_BIN, { "-f", "ergopti_plus_expander" })',
			'local ApiOllama = require("modules.llm.api_ollama")',
			'pcall_log("owned Ollama retirement", ApiOllama.stop_owned_server)',
			'-- pkill -f ollama would kill the user\'s own server',
			'"lsof -nP -tiTCP:8080 -sTCP:LISTEN | xargs kill -9"',
		}
		for _, sample in ipairs(clean) do
			helpers.assert_eq(#find_broad_kills(sample), 0, "the detector must accept: " .. sample)
		end
	end)

	helpers.it("no runtime source signals Ollama processes by name or by port", function()
		local units, unreadable = RuntimeSources.read(helpers.driver_root())
		helpers.assert_true(#units > 100, "the runtime scan must cover the whole macOS driver")
		helpers.assert_eq(#unreadable, 0, "every runtime source must be readable")
		local found = {}
		for _, unit in ipairs(units) do
			for _, offender in ipairs(find_broad_kills(unit.body)) do
				found[#found + 1] = unit.path .. ": " .. offender
			end
		end
		helpers.assert_eq(#found, 0, "broad Ollama termination found:\n" .. table.concat(found, "\n"))
	end)

	helpers.it("the quit teardown retires the owned daemon and sweeps only the two helpers", function()
		local source, err = helpers.read_driver_unit("function M.terminate_helper_processes()")
		helpers.assert_true(type(source) == "string", "the quit helper sweep must be uniquely readable: " .. tostring(err))
		local body = source:match("function M%.terminate_helper_processes%(%)(.-)\nend\n")
		helpers.assert_true(body ~= nil, "terminate_helper_processes must exist")
		helpers.assert_true(body:find("ApiOllama.stop_owned_server", 1, true) ~= nil,
			"quit must retire Ollama through the owned-daemon stop")
		local patterns = {}
		for value in body:gmatch("pattern%s*=%s*\"([^\"]*)\"") do patterns[#patterns + 1] = value end
		helpers.assert_eq(#patterns, 2, "the quit sweep pattern scan must find both helper patterns")
		helpers.assert_eq(table.concat(patterns, ","), "ergopti_plus_expander,ergopti_plus_http_server",
			"the quit sweeps name only Ergopti's own helpers")
	end)
end)
