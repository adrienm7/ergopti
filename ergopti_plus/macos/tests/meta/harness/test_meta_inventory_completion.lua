--- tests/meta/harness/test_meta_inventory_completion.lua

--- ==============================================================================
--- MODULE: Meta-Test Inventory Completion Regressions
--- DESCRIPTION:
--- Replays each source-enumerating test helper with adversarial native command
--- receipts. A partial inventory cannot authorize an absence assertion. The
--- bounded real helper bodies keep the caller filters and fallback branch live.
--- ==============================================================================

local helpers = require("tests.helpers")
local CommandLines = require("tests.support.command_lines")
local SourceFile = require("tests.support.source_file")
local shell_quote = require("text_utils").shell_quote

--- Discovers source walkers themselves, so a new sibling cannot escape replay.
--- @return table Array of test source paths and local helper symbols.
local function source_scanners()
	local root = helpers.driver_root()
	local directory = root .. "tests/meta"
	local command = package.config:sub(1, 1) == "\\"
		and ('cmd /c dir /b /s /a-d "' .. directory:gsub("/", "\\") .. '"')
		or ("find " .. shell_quote(directory) .. " -type f -name '*.lua'")
	local entries = {}
	for _, raw_path in ipairs(CommandLines.read(command)) do
		local path = raw_path:gsub("\\", "/")
		if path:match("%.lua$") and path ~= root .. "tests/meta/harness/test_meta_inventory_completion.lua" then
			local source = SourceFile.read(path)
			local position = 1
			while true do
				local start, _, name = source:find("\nlocal function ([%w_]+)%(", position)
				if not start then break end
				local finish = assert(source:find("\nend", start, true), "a source helper must have a complete body")
				local body = source:sub(start + 1, finish + 3)
				if body:find(" -type f", 1, true) or body:find("/b /s /a-d", 1, true) then
					entries[#entries + 1] = { path:sub(#root + 1), name }
				end
				position = finish + 4
			end
		end
	end
	assert(#entries > 0, "source walker replay cannot accept an empty inventory")
	return entries
end

local SCANNERS = source_scanners()

--- Loads one complete real local helper, retaining its caller filtering logic.
--- @param entry table Test source and function name.
--- @return function scanner
local function load_scanner(entry)
	local source = SourceFile.read(helpers.driver_root() .. entry[1])
	local start = assert(source:find("local function " .. entry[2] .. "(", 1, true))
	local finish = assert(source:find("\nend", start, true))
	local environment = setmetatable({
		helpers = helpers, DRIVER_ROOT = helpers.driver_root(), CommandLines = CommandLines, shell_quote = shell_quote,
		require = function(name)
			if name == "lfs" then error("exercise the command fallback") end
			return require(name)
		end,
	}, { __index = _G })
	local body = source:sub(start, finish + 3)
	local bindings = ""
	if body:find("SCANNED_DIRS", 1, true) then
		bindings = assert(source:match("(local%s+SCANNED_DIRS%s*=%s*%b{})"), "retain the real source-root policy") .. "\n"
	end
	return assert(load(bindings .. body .. "\nreturn " .. entry[2], "@" .. entry[1], "t", environment))()
end

--- Replays an exact scanner with a controlled command and guaranteed restoration.
--- @param entry table Test source and function name.
--- @param failure string|nil Failure injected into the opened command receipt.
--- @return boolean accepted
--- @return any result
--- @return table facts
local function replay(entry, failure)
	local scanner = load_scanner(entry)
	local facts = { opens = 0, closes = 0 }
	local popen = io.popen
	io.popen = function()
		facts.opens = facts.opens + 1
		if failure == "open" then return nil, "controlled source walk refusal" end
		local emitted = false
		return {
			lines = function() return function()
				if failure == "iteration" then error("controlled source walk iteration") end
				if emitted or failure == "empty" then return nil end
				emitted = true
				if entry[2] == "discovered_modules" then
					return helpers.driver_root() .. (facts.opens == 1 and "tests/meta/test_probe.lua" or "tests/unit/test_probe.lua")
				end
				return helpers.driver_root() .. (failure == "unmatched" and "infra/readme.txt" or "infra/test_source_probe.lua")
			end end,
			close = function()
				facts.closes = facts.closes + 1
				if failure == "close" then error("controlled source walk close") end
				if failure == "exit" then return nil, "exit", 7 end
				return true, "exit", 0
			end,
		}
	end
	local accumulated = {}
	local outcome = table.pack(pcall(function()
		local name = entry[2]
		local result
		if name == "list_files" then result = scanner(helpers.driver_root(), "lua")
		elseif name == "collect" or name == "collect_lua_files" or name == "collect_test_files" then
			scanner(helpers.driver_root(), accumulated)
			result = accumulated
		elseif name == "lua_files_under" then result = scanner("infra")
		else result = scanner(helpers.driver_root()) end
		return result
	end))
	io.popen = popen
	return outcome[1], outcome[2], facts
end

helpers.describe("meta source inventory completion", function()
	for _, entry in ipairs(SCANNERS) do
		local failures = { "open", "exit", "iteration", "close", "empty" }
		if entry[2] == "list_files" or entry[2] == "list_lua_files" then failures[#failures + 1] = "unmatched" end
		for _, failure in ipairs(failures) do
			helpers.it("(meta-inventory-completion) " .. entry[1] .. " refuses " .. failure, function()
				local accepted, reason, facts = replay(entry, failure)
				helpers.assert_eq(accepted, false, "a source scanner cannot publish an incomplete command inventory")
				helpers.assert_type(reason, "string")
				helpers.assert_eq(facts.opens, 1, "exercise the real command fallback exactly once")
				helpers.assert_eq(facts.closes, failure == "open" and 0 or 1, "always retire the owned pipe")
			end)
		end
		helpers.it("(meta-inventory-completion) " .. entry[1] .. " admits complete output", function()
			local accepted, result, facts = replay(entry, nil)
			helpers.assert_true(accepted, tostring(result))
			helpers.assert_type(result, "table")
			local expected = entry[2] == "discovered_modules" and 2 or 1
			helpers.assert_eq(#result, expected, "retain the scanner's own output filtering")
			helpers.assert_eq(facts.opens, expected)
			helpers.assert_eq(facts.closes, expected)
		end)
	end
end)
