--- _shared/lua/test/runner_replay_contract.lua

--- ==============================================================================
--- MODULE: Shared Lua Runner Replay Regression Contract
--- DESCRIPTION:
--- Executes each runner's real failure-emission block with recording output and
--- exit ports. Literal shell words preserve authored names and replay selection.
--- ==============================================================================

local M = {}

M.vectors = {
	{ label = "dollar variable", name = "literal $XDG_STATE_HOME", word = "'literal $XDG_STATE_HOME'" },
	{ label = "backticks", name = "literal `replay-sentinel`", word = "'literal `replay-sentinel`'" },
	{ label = "apostrophe", name = "it's a case", word = "'it'\\''s a case'" },
	{ label = "double quotes", name = 'literal "quoted" case', word = "'literal \"quoted\" case'" },
	{ label = "spaces", name = "several spaced words", word = "'several spaced words'" },
	{ label = "newline", name = "line\nname", word = "'line\nname'" },
}

local function compile(source, environment)
	if type(loadstring) == "function" then
		local chunk = assert(loadstring(source, "@runner-replay-emission"))
		return setfenv(chunk, environment)
	end
	return assert(load(source, "@runner-replay-emission", "t", environment))
end

--- Receives actual runner replay output without loading tests or exiting Lua.
--- @param source string Actual unit runner source.
--- @param failures table Actual failure-record shape.
--- @return table replay Commands emitted by the original failure block.
function M.emit(source, failures)
	local first = assert(source:find("if r.failed > 0 then\n", 1, true))
	local last = assert(source:find("if helpers.timing_failed() then", first, true))
	local declaration = source:match('local shell_quote[^\n]*\n') or ""
	local lines, exit = {}, {}
	local environment = {
		r = { failed = #failures, failures = failures },
		ipairs = ipairs,
		string = string,
		require = require,
		print = function(line) lines[#lines + 1] = line end,
		os = { exit = function(code) exit.code = code; error(exit, 0) end },
	}
	local ok, err = pcall(compile(declaration .. source:sub(first, last - 1), environment))
	assert(not ok and rawequal(err, exit) and exit.code == 1, "failure emission must retain exit 1")
	local replays = {}
	for _, line in ipairs(lines) do
		local replay = line:match("\n    replay: (.*)")
		if replay then replays[#replays + 1] = replay:gsub("\n$", "") end
	end
	assert(#replays == #failures, "every failure must have one replay")
	return replays
end

--- Registers literal replay and unchanged case/module/suite selection controls.
--- @param helpers table Actual driver's assertion and registration functions.
--- @param driver string Linux or macOS runner identity.
function M.run(helpers, driver)
	local file = assert(io.open("tests/run.lua", "rb"))
	local source = file:read("*a")
	assert(file:close())
	local prefix = driver == "linux" and "luajit tests/run.lua" or "lua tests/run.lua"
	helpers.describe("Lua runner literal replay", function()
		for _, vector in ipairs(M.vectors) do
			helpers.it("Lua replay: preserves " .. vector.label .. " in the actual case command", function()
				local replay = M.emit(source, {{ kind = "case", name = vector.name, err = "sentinel" }})
				helpers.assert_eq(replay[1], prefix .. " --only " .. vector.word)
			end)
		end
		for _, kind in ipairs({ "module", "suite" }) do
			helpers.it("Lua replay: retains " .. kind .. " selection", function()
				local replay = M.emit(source, {{ kind = kind, name = "suite failure", module = "tests.unit.owner", err = "sentinel" }})
				local expected = driver == "linux" and prefix or prefix .. " --only 'tests.unit.owner'"
				helpers.assert_eq(replay[1], expected)
			end)
		end
		helpers.it("Lua replay: retains every failure in original order", function()
			local replay = M.emit(source, {
				{ kind = "case", name = "first case", err = "first error" },
				{ kind = "case", name = "second case", err = "second error" },
			})
			helpers.assert_eq(replay, { prefix .. " --only 'first case'", prefix .. " --only 'second case'" })
		end)
	end)
end

return M
