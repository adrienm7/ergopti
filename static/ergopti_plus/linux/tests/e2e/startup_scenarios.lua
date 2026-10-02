--- tests/e2e/startup_scenarios.lua

--- ==============================================================================
--- MODULE: Installed-Driver Start-Up Scenarios
--- DESCRIPTION:
--- Starts the REAL daemon (tests/e2e/startup_child.lua) from a copy laid out
--- the way install.sh publishes it (lib/ergopti/linux, lib/ergopti/_shared,
--- the layout registry below the driver, a build stamp), over the user states
--- that decide what a start does: a fresh install, the neutral defaults, the
--- recommended preset imported, and config.toml files older releases wrote.
--- Every start must log no ERROR, show no error dialog or error window, and
--- neither write nor look up user data inside the installed folder.
---
--- FEATURES & RATIONALE:
--- 1. hardening-a-startup-zero-error: no suite started the daemon with every
---    module loaded, so an ERROR on every start without luv reached users.
--- 2. hardening-b-installed-layout: the package folder is shared and replaced
---    by updates; the same file list before and after proves nothing wrote it.
--- 3. hardening-e-presets: after the recommended import the navigation layer
---    is bound and a tap-hold key enters it (db71c39bf).
--- ==============================================================================

local M = {}

local ON_WINDOWS = package.config:sub(1, 1) == "\\"

--- Quotes one value for /bin/sh.
--- @param value string
--- @return string
local function q(value)
	return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

--- Runs one POSIX command and raises on failure.
--- @param command string
local function run(command)
	local result = os.execute(command)
	if not (result == true or result == 0) then error("startup scenarios: command failed: " .. command, 2) end
end

--- Every file under one folder, as a set.
--- @param dir string
--- @return table
local function files_under(dir)
	local set = {}
	local listing = io.popen("cd " .. q(dir) .. " && find . -type f")
	for path in listing:lines() do set[path] = true end
	listing:close()
	return set
end

--- Lays the driver out as install.sh publishes it under <root>/lib/ergopti.
--- @param driver string Repository Linux driver folder.
--- @param root string Scenario root.
--- @return string installed Installed driver folder.
local function stage_install(driver, root)
	local lib = root .. "/lib/ergopti"
	local installed = lib .. "/linux"
	run("mkdir -p " .. q(installed .. "/static/layouts") .. " " .. q(lib .. "/_shared"))
	run("cp -r " .. q(driver .. "/.") .. " " .. q(installed .. "/"))
	run("cp -r " .. q(driver .. "/../_shared/.") .. " " .. q(lib .. "/_shared/"))
	run("cp -r " .. q(driver .. "/../../layouts/registry") .. " " .. q(installed .. "/static/layouts/"))
	local stamp = assert(io.open(lib .. "/_shared/build_stamp.txt", "w"))
	stamp:write("commit=0000000000000000000000000000000000e2e000\n")
	stamp:close()
	return installed
end

local CORPUS = "/../_shared/tests/corpus/config_migrations"

--- Every scenario. A fresh install opens the first-use wizard; a configured
--- one never does. The config.toml files older Linux releases wrote are every
--- shipped case of the shared migration corpus, found by name so a new case
--- starts without an edit here.
--- @param driver string Repository Linux driver folder.
--- @return table scenarios
local function scenarios(driver)
	local list = {
		{ name = "a fresh install opens the first-use wizard", steps = { "boot" }, wizard = true },
		{ name = "the neutral defaults start", seed = "/_generated/config_template.toml", steps = { "boot" } },
		{ name = "the recommended preset imported from the menu starts", seed = "/_generated/config_template.toml",
			steps = { "restore_recommended", "boot" }, recommended = true },
		{ name = "a table-array delimiter list can be saved and read at the next start",
			seed = "/tests/e2e/fixtures/terminators_array.toml", steps = { "delimiters_add", "delimiters_verify" } },
	}
	local cases = {}
	local listing = io.popen("ls " .. q(driver .. CORPUS))
	for name in listing:lines() do
		if name:match("^shipped_.+_on_linux$") or name:match("^shipped_.+_on_windows_and_linux$") then
			cases[#cases + 1] = name
		end
	end
	listing:close()
	table.sort(cases)
	for _, name in ipairs(cases) do
		list[#list + 1] = { name = "an older release's config.toml starts (" .. name .. ")",
			seed = CORPUS .. "/" .. name .. "/input.toml", steps = { "boot" } }
	end
	if #cases < 2 then error("startup scenarios: the migration corpus holds fewer than two Linux releases") end
	return list
end

--- What one start showed the user or did to the package, as failure lines.
--- @param output string
--- @param action string
--- @param wizard boolean Whether this start must open the first-use wizard.
--- @return table problems, table facts
local function judge(output, action, wizard)
	local problems, facts = {}, {}
	local wizard_opened = ("\n" .. output):find("\nE2E_WINDOW onboarding\n", 1, true) ~= nil
	if wizard_opened ~= wizard then
		problems[#problems + 1] = wizard and "the first-use wizard never opened"
			or "the first-use wizard opened over an existing configuration"
	end
	for line in output:gmatch("[^\n]+") do
		if line:find("%[ERROR%]") or line:find("%[FATAL%]") then
			problems[#problems + 1] = "logged " .. line:gsub("^%S+ %S+ ", "")
		else
			local kind, detail = line:match("^E2E_([%u_]+) (.*)$")
			if kind == "DIALOG" or kind == "DRIVER_WRITE" or kind == "DRIVER_READ_MISSING"
				or kind == "SCENARIO_FAILED" or kind == "EMERGENCY_STOP" then
				problems[#problems + 1] = line
			elseif kind == "FACT" then
				local key, value = detail:match("^([%w_]+)=(.*)$")
				if key then facts[key] = value end
			end
		end
	end
	if not output:find("E2E_DONE " .. action, 1, true) then
		problems[#problems + 1] = "the " .. action .. " child never finished: " .. output:sub(-400)
	end
	if action == "delimiters_add" and (facts.delimiter_added ~= "true" or facts.delimiter_committed ~= "true") then
		problems[#problems + 1] = "the custom delimiter was not added and committed"
	end
	if (action == "delimiters_add" or action == "delimiters_verify") and facts.custom_list_verified ~= "true" then
		problems[#problems + 1] = "the saved delimiters, unknown fields or comment did not survive"
	end
	return problems, facts
end

--- The keys the shipped recommended layer binds on one OS: its `all` table
--- and that OS's table (_shared/keymap/layers.recommended.toml).
--- @param shared string The _shared folder.
--- @param os_name string "macos" or "linux".
--- @return integer keys
local function recommended_layer_keys(shared, os_name)
	local fh = assert(io.open(shared .. "/keymap/layers.recommended.toml", "rb"), "the shipped layer preset is missing")
	local keys, count, scope = {}, 0, nil
	for line in fh:lines() do
		local header = line:match("^%[layers%.[%w_]+%.([%w_]+)%]")
		if header then
			scope = header
		elseif line:match("^%[") then
			scope = nil
		elseif scope == "all" or scope == os_name then
			local key = line:match('^"([^"]+)"%s*=')
			if key and not keys[key] then
				keys[key] = true
				count = count + 1
			end
		end
	end
	fh:close()
	return count
end

--- Runs every scenario through `check`.
--- @param check table { pass(label), fail(label, expected, actual), skip(label) }
--- @param options table { driver, interpreter }
function M.run(check, options)
	if ON_WINDOWS then
		check.skip("installed-driver start-up scenarios need POSIX cp and find")
		return
	end
	local scratch = os.tmpname()
	os.remove(scratch)
	local installed = stage_install(options.driver, scratch)
	local device = scratch .. "/device"
	run(": > " .. q(device))
	local before = files_under(scratch .. "/lib")
	for index, scenario in ipairs(scenarios(options.driver)) do
		local home = scratch .. "/home" .. index
		run("mkdir -p " .. q(home) .. " " .. q(scratch .. "/tmp"))
		local problems, facts = {}, {}
		for _, action in ipairs(scenario.steps) do
			local command = table.concat({
				"cd " .. q(installed) .. " &&",
				"env -u XDG_CONFIG_HOME -u XDG_STATE_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME",
				"HOME=" .. q(home), "TMPDIR=" .. q(scratch .. "/tmp"),
				q(options.interpreter), "tests/e2e/startup_child.lua", q(device), q(action), q(installed),
				scenario.seed and q(options.driver .. scenario.seed) or "''",
				"2>&1",
			}, " ")
			local pipe = io.popen(command, "r")
			local output = pipe:read("*a")
			pipe:close()
			local step_problems
			step_problems, facts = judge(output, action, scenario.wizard == true)
			for _, problem in ipairs(step_problems) do problems[#problems + 1] = action .. ": " .. problem end
			-- The seed is the state before the first start only.
			scenario.seed = nil
		end
		local after = files_under(scratch .. "/lib")
		for path in pairs(after) do
			if not before[path] then problems[#problems + 1] = "created inside the installed folder: " .. path end
		end
		for path in pairs(before) do
			if not after[path] then problems[#problems + 1] = "deleted from the installed folder: " .. path end
		end
		if #problems == 0 then
			check.pass("hardening-a/b start: " .. scenario.name)
		else
			check.fail("hardening-a/b start: " .. scenario.name, "no ERROR, error dialog or package write",
				table.concat(problems, "\n        ", 1, math.min(#problems, 12)))
		end
		if scenario.recommended then
			-- Every key the preset binds on Linux is bound; the layer was empty
			-- before db71c39bf.
			local bindings = tonumber(facts.nav_layer_bindings) or 0
			local keys = tonumber(facts.nav_layer_keys) or 0
			local preset_keys = recommended_layer_keys(options.driver .. "/../_shared", "linux")
			if bindings >= preset_keys and preset_keys > 0 and keys > 0 then
				check.pass(string.format("hardening-e-presets: the recommended navigation layer binds %d key(s) "
					.. "of %d in the preset and %d tap-hold key(s) enter it", bindings, preset_keys, keys))
			else
				check.fail("hardening-e-presets: the recommended navigation layer is bound and entered",
					string.format("%d bindings and an entering key", preset_keys),
					string.format("%d bindings, %d entering", bindings, keys))
			end
		end
	end
	run("rm -rf " .. q(scratch))
end

return M
