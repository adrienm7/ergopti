--- tests/meta/test_quit_teardown_never_blocks.lua

--- ==============================================================================
--- MODULE: Quit Teardown Step Bodies Never Block
--- DESCRIPTION:
--- Enumerates every step of init.lua's teardown_all_resources, resolves the
--- module function each step calls, and scans that function body for synchronous
--- process primitives (hs-quit-never-blocks).
---
--- ROOT CAUSE ENCODED:
--- Quit ran hs.execute(cmd, true) — a login and interactive shell with no
--- timeout — on the Hammerspoon main thread, plus synchronous lsof runs. A hung
--- shell profile froze the app until it was killed in Activity Monitor. The async
--- quit watchdog cannot fire while the main thread is blocked, so a new blocking
--- call in any step must fail here. Each step receiver must be mapped below; an
--- unmapped receiver fails, so a new step cannot silently escape the scan.
--- A mutant check proves the scanner detects each forbidden primitive.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Synchronous primitives that wait for a subprocess on the main thread. Any
-- reference counts: the original bug passed hs.execute to pcall uncalled.
local FORBIDDEN = {
	"hs%.execute%f[^%w_]",
	"os%.execute%f[^%w_]",
	"io%.popen%f[^%w_]",
	"ShellRunner%.exec%f[^%w_]",
	"waitUntilExit",
	"usleep",
}

-- Root-level receivers used by teardown steps, mapped to their module names.
-- Files are resolved through package.path, so a module move cannot break this.
local RECEIVER_MODULES = {
	LauncherGuard = "infra.launcher_guard",
	karabiner = "platform.remap",
	keymap = "modules.keymap",
	gestures = "modules.gestures",
	shortcuts = "modules.shortcuts",
	Storage = "adapters.storage",
}

-- Receivers that are not module facades (local objects or the step's own guard)
local IGNORED_RECEIVERS = { captured = true, Logger = true }

-- Functions reached one level below a step that do the step's real work
local TRANSITIVE_BODIES = {
	{ module = "modules.keylogger", header = "local function teardown_runtime(" },
	{ module = "modules.keylogger.log_manager", header = "function M.stop(" },
	{ module = "ui.menu.menu_llm", header = "local function start_detached_sweep(" },
	-- The MLX stop runs ahead of the step list, awaiting the exact task callback
	{ module = "ui.menu.menu_llm", header = "function M.stop_mlx_server(" },
}



--- Reads the source of one driver module, resolved through package.path.
--- @param module_name string Dotted Lua module name.
--- @return string source
local function read_module(module_name)
	local path = assert(package.searchpath(module_name, package.path),
		"module source not found for " .. module_name)
	local handle = assert(io.open(path, "rb"))
	local source = handle:read("*a")
	handle:close()
	return source
end

--- Extracts a top-level function body starting at its exact header.
--- @param source string File source.
--- @param header string Function header prefix, e.g. "function M.stop(".
--- @return string|nil body
local function function_body(source, header)
	local start = source:find("\n" .. header, 1, true)
	if not start then return nil end
	start = start + 1
	local line_end = source:find("\n", start, true) or #source
	local first_line = source:sub(start, line_end)
	if first_line:match("%send%s*$") then return first_line end
	local finish = source:find("\nend%f[%W]", start, false)
	return source:sub(start, finish and finish + 4 or #source)
end

--- Removes Lua line comments so documentation naming a primitive is not a hit.
--- @param body string Lua source.
--- @return string code
local function strip_comments(body)
	return (body:gsub("%-%-[^\n]*", ""))
end

--- Returns the forbidden primitives found in one body.
--- @param body string Lua source.
--- @return string[] hits
local function blocking_hits(body)
	local code = strip_comments(body)
	local hits = {}
	for _, pattern in ipairs(FORBIDDEN) do
		if code:find(pattern) then hits[#hits + 1] = pattern end
	end
	return hits
end

--- Enumerates `{ module, header, step }` targets for every teardown step call.
--- @return table[] targets
--- @return string teardown Complete teardown_all_resources source.
local function teardown_targets()
	local init = assert(helpers.read_driver_unit("local function teardown_all_resources("))
	local teardown = assert(function_body(init, "local function teardown_all_resources("),
		"teardown_all_resources must be locatable")
	local targets = {}
	local steps = 0
	for step_name, step_body in teardown:gmatch('name%s*=%s*"([^"]+)"(.-)\n%s*}') do
		steps = steps + 1
		local loaded = step_body:match('package%.loaded%["([^"]+)"%]')
		for receiver, method in step_body:gmatch("([%a_][%w_]*)[%.:]([%a_][%w_]*)%s*%(") do
			local module_name
			if receiver == "module" then
				module_name = loaded
				assert(module_name, "step '" .. step_name .. "' uses module without package.loaded")
			elseif not IGNORED_RECEIVERS[receiver] then
				module_name = RECEIVER_MODULES[receiver]
				assert(module_name, "teardown step '" .. step_name .. "' calls unmapped receiver '"
					.. receiver .. "'; map it in RECEIVER_MODULES so the scan covers it")
			end
			if module_name then
				targets[#targets + 1] = {
					module = module_name, header = "function M." .. method .. "(", step = step_name,
				}
			end
		end
	end
	return targets, teardown, steps
end

helpers.describe("quit teardown step bodies never block (hs-quit-never-blocks)", function()
	helpers.it("(hs-quit-never-blocks) every teardown step callee is free of blocking primitives", function()
		local targets, teardown, steps = teardown_targets()
		helpers.assert_true(steps >= 10, "the step enumeration must see the teardown steps")
		helpers.assert_eq(blocking_hits(teardown), {},
			"teardown_all_resources itself must not block")
		local scanned = {}
		for _, target in ipairs(targets) do
			local body = function_body(read_module(target.module), target.header)
			helpers.assert_true(body ~= nil,
				target.module .. " must define " .. target.header .. " for step " .. target.step)
			helpers.assert_eq(blocking_hits(body), {},
				"teardown step '" .. target.step .. "' blocks in " .. target.module .. " " .. target.header)
			scanned[target.header] = true
		end
		for _, required in ipairs({
			"function M.terminate_helper_processes(", "function M.terminate_orphan_mlx_server(",
			"function M.shutdown(", "function M.teardown_local(", "function M.stop_server(",
		}) do
			helpers.assert_true(scanned[required], "the scan must cover " .. required)
		end
		for _, target in ipairs(TRANSITIVE_BODIES) do
			local body = function_body(read_module(target.module), target.header)
			helpers.assert_true(body ~= nil, target.module .. " must define " .. target.header)
			helpers.assert_eq(blocking_hits(body), {},
				"transitive teardown body blocks: " .. target.module .. " " .. target.header)
		end
	end)

	helpers.it("(hs-quit-never-blocks) the process-exit log-manager stop does not ingest", function()
		local body = function_body(read_module("modules.keylogger.log_manager"), "function M.stop(")
		local code = strip_comments(body)
		local branch = code:match("if process_exit then(.-)\n\telse\n")
		helpers.assert_true(branch ~= nil, "LogManager.stop must branch on process_exit")
		helpers.assert_true(branch:find("ingest_once", 1, true) == nil,
			"the process-exit stop must not run the heavy final ingest")
	end)

	helpers.it("(hs-quit-never-blocks) mutant: the scanner detects each primitive", function()
		local clean = function_body(read_module("ui.menu.menu_llm"),
			"function M.terminate_helper_processes(")
		helpers.assert_eq(blocking_hits(clean), {})
		for _, mutation in ipairs({
			'pcall(hs.execute, "pkill -f x", true)',
			'hs.execute("pkill -f x", true)',
			'os.execute("lsof -tiTCP:1")',
			'io.popen("pgrep x")',
			'ShellRunner.exec("pkill x")',
			"task:waitUntilExit()",
			"hs.timer.usleep(1000)",
		}) do
			-- Insert the mutation right after the function header line
			local header_end = assert(clean:find("\n", 1, true))
			local mutant = clean:sub(1, header_end) .. "\t" .. mutation .. "\n"
				.. clean:sub(header_end + 1)
			helpers.assert_true(#blocking_hits(mutant) > 0, "scanner missed mutant: " .. mutation)
		end
		helpers.assert_eq(blocking_hits("-- hs.execute(\"documented\")\nreturn true"), {},
			"a comment naming a primitive is not a call")
	end)
end)
