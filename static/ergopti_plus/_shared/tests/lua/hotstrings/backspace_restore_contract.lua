--- _shared/tests/lua/hotstrings/backspace_restore_contract.lua

--- ==============================================================================
--- MODULE: Backspace Restore Vectors Contract
--- DESCRIPTION:
--- Replays _shared/tests/corpus/hotstrings/backspace_restore_vectors.json
--- through the shared rule (_shared/hotstrings/engine/backspace_restore.lua)
--- and, when the driver gives one, through its own undo path, so the macOS and
--- Linux Backspace undos leave the same text as the AutoHotkey port.
--- ==============================================================================

local M = {}

--- What the vector's line reads after its Backspace, by the shared rule.
--- @param Rule table The shared backspace_restore module.
--- @param vector table One corpus vector.
--- @return string screen_after
local function expected_by_rule(Rule, vector)
	local replayed = (vector.terminator ~= nil and vector.terminator_consumed ~= true) and vector.terminator or nil
	local undoes = vector.enabled == true and vector.key_between ~= true
		and Rule.within_window(0, vector.elapsed_ms, vector.window_ms)
	if undoes then return Rule.restored_text(vector.trigger, vector.magic_key, replayed), true end
	local screen = vector.output .. (replayed or "")
	-- The corpus texts end with one-byte or three-byte characters only.
	local last = screen:match("[%z\1-\127\194-\244][\128-\191]*$") or ""
	return screen:sub(1, #screen - #last), false
end

--- Registers the contract cases.
--- @param helpers table The driver's test helpers.
--- @param corpus_path string Absolute path of backspace_restore_vectors.json.
--- @param driver string The driver's name, for the case title.
--- @param replay function|nil vector -> screen_after through the driver's own undo.
function M.register(helpers, corpus_path, driver, replay)
	local Json = require("core.text.engine.json")
	local Rule = require("hotstrings.engine.backspace_restore")
	local handle = assert(io.open(corpus_path, "rb"))
	local corpus = Json.decode(handle:read("*a"))
	handle:close()

	helpers.describe("backspace restore vectors (backspace-restore-vectors)", function()
		helpers.it("(backspace-restore-vectors) the shared rule leaves every vector's text", function()
			helpers.assert_true(#corpus.vectors >= 10, "the corpus lists its vectors")
			for _, vector in ipairs(corpus.vectors) do
				local screen, undoes = expected_by_rule(Rule, vector)
				helpers.assert_eq(undoes, vector.undoes, vector.id .. ": undoes")
				helpers.assert_eq(screen, vector.screen_after, vector.id .. ": " .. vector.description)
			end
		end)
		if replay then
			helpers.it("(backspace-restore-vectors) " .. driver .. " replays every vector through its undo", function()
				for _, vector in ipairs(corpus.vectors) do
					helpers.assert_eq(replay(vector), vector.screen_after, vector.id .. ": " .. vector.description)
				end
			end)
		end
	end)
end

return M
