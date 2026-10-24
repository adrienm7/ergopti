--- tests/meta/corpus/test_corpus_metrics_collection_session.lua

--- ==============================================================================
--- MODULE: Metrics Suspend And Session Reset Corpus Consumer (Linux)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/metrics/collection_session_vectors.json through
--- the Linux keystats module. The macOS and Windows suites replay the same
--- sequences, so the pause and the session reset mean one thing on all three.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local it = require("tests.support.metrics_preferences_fixture").it
local keystats = helpers.load_module("modules.keystats.keystats")

local path = helpers.driver_root() .. "/../_shared/tests/corpus/metrics/collection_session_vectors.json"
local handle = assert(io.open(path, "rb"), "cannot open " .. path)
local corpus = Json.decode_lossless(handle:read("*a"))
handle:close()

local SQLITE_PATH = (os.getenv("TMPDIR") or "/tmp") .. "/ergopti_test_collection_session.sqlite"

--- Applies one corpus operation to the Linux keystats module.
--- @param op table The operation and its assertions.
--- @param clock table Mutable key timestamp.
--- @param label string Vector id, for messages.
local function apply(op, clock, label)
	if op.op == "type" then
		local before = keystats.get_session_stats().keystrokes
		clock.now = clock.now + 100
		keystats.on_keydown("x", clock.now, "code")
		local counted = keystats.get_session_stats().keystrokes > before
		if op.recorded ~= nil then helpers.assert_eq(counted, op.recorded, label .. ": type recorded") end
	elseif op.op == "suspend" then
		keystats.suspend_collection()
	elseif op.op == "resume" then
		keystats.resume_collection()
	elseif op.op == "secure_on" then
		keystats.set_secure_field(true)
	elseif op.op == "secure_off" then
		keystats.set_secure_field(false)
	elseif op.op == "reset" then
		local applied = keystats.reset_session()
		helpers.assert_eq(applied ~= false, op.reset_applied, label .. ": reset applied")
	else
		error(label .. ": unknown operation " .. tostring(op.op))
	end
	if op.suspended ~= nil then
		helpers.assert_eq(keystats.is_collection_suspended(), op.suspended, label .. ": suspended")
	end
	if op.session_keystrokes ~= nil then
		helpers.assert_eq(keystats.get_session_stats().keystrokes, op.session_keystrokes, label .. ": session keystrokes")
	end
end

helpers.describe("metrics suspend and session reset corpus: the shared contract on Linux", function()
	it("the corpus is readable", function()
		helpers.assert_true(type(corpus) == "table" and #corpus.vectors >= 8, "the vectors must be present")
	end)

	for _, vector in ipairs(corpus.vectors) do
		it("vector " .. vector.id, function()
			os.remove(SQLITE_PATH)
			keystats.init({ sqlite_path = SQLITE_PATH })
			require("tests.support.metrics_consent_fixture").enable(keystats)
			local clock = { now = 1000 }
			for _, op in ipairs(vector.ops) do apply(op, clock, vector.id) end
			keystats.resume_collection()
			keystats.set_secure_field(false)
		end)
	end
end)
