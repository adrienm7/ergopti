--- tests/meta/test_audit_v5_fixes.lua

--- ==============================================================================
--- MODULE: Audit V5 Regression Guards
--- DESCRIPTION:
--- Static-source regression guards for the four bugs fixed from the expert audit
--- report RAPPORT_AUDIT_EXPERT_HAMMERSPOON.md (macOS/Hammerspoon side):
---   1. gestures/engine.lua: diagonal detection used `adx >= diagMin and ady >=
---      diagMin`, requiring ~2x the intended total distance. Fixed to `dist >= diagMin`.
---   2. modules/llm/api_mlx.lua: `_server_pgid_pending` stayed true forever if the
---      MLX server crashed before emitting its PID line. Fixed with a 15s timeout.
---   3. modules/keymap/init.lua: timing, character equality, and process identity
---      were replaced by immutable SyntheticInput user-data tags. Keymap now
---      classifies once and filters owned events before physical-input mutation.
---   4. init.lua: `grep -c .` exit-code 1 on empty input is now silenced with
---      `|| true` to protect against future `set -e` shells.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end


--- Reads the single production unit that owns an ordering invariant.
--- @param selector string
--- @return string source
local function read_unit(selector)
	local src, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(src, err)
	return src
end


--- Removes line comments so explanatory prose cannot satisfy a code invariant.
--- @param source string
--- @return string code
local function strip_line_comments(source)
	return (source:gsub("%-%-[^\n]*", ""))
end


--- Counts literal occurrences without depending on Lua-pattern escaping.
--- @param source string
--- @param needle string
--- @return integer count
local function count_literal(source, needle)
	local count, cursor = 0, 1
	while true do
		local found = source:find(needle, cursor, true)
		if not found then return count end
		count = count + 1
		cursor = found + #needle
	end
end


--- Isolates the raw key handler and its eventtap wrapper from one source unit.
--- @param source string
--- @return string raw
--- @return string wrapper
local function keydown_slices(source)
	local raw_pos = source:find("local function onKeyDownRaw%(")
	local raw_end = raw_pos and source:find("\nlocal function merge_returned_events", raw_pos, true)
	local wrapper_pos = source:find("local function onKeyDown%(e%)")
	local wrapper_end = wrapper_pos and source:find(
		"\ntap = eventtap.new({ eventtap.event.types.keyDown }, onKeyDown)", wrapper_pos, true)
	helpers.assert_not_nil(raw_pos, "the raw keyDown handler must remain locatable")
	helpers.assert_not_nil(raw_end, "the raw keyDown handler must remain independently bounded")
	helpers.assert_not_nil(wrapper_pos, "the production keyDown wrapper must remain locatable")
	helpers.assert_not_nil(wrapper_end,
		"the production keyDown wrapper must end at its eventtap binding")
	return source:sub(raw_pos, raw_end - 1), source:sub(wrapper_pos, wrapper_end - 1)
end


--- Checks every raw-handler route in the wrapper, not one hand-picked call site.
--- @param wrapper string
--- @return boolean valid
local function wrapper_has_single_fenced_route(wrapper)
	local code = strip_line_comments(wrapper)
	if count_literal(code, "EventProvenance.classify_with_fence") ~= 1 then return false end
	if count_literal(code, "onKeyDownRaw") ~= 1 then return false end
	local classify_at = code:find(
		'pcall%s*%(%s*EventProvenance%.classify_with_fence%s*,%s*e%s*,%s*"keymap"%s*%)')
	local route_at = code:find(
		'pcall%s*%(%s*onKeyDownRaw%s*,%s*e%s*,%s*provenance%s*,%s*provenance_status%s*%)')
	return classify_at ~= nil and route_at ~= nil and classify_at < route_at
end


--- Checks that every ordinary owned/unreadable path exits before physical work.
--- A live internal loopback is the deliberate exception: it reaches key decoding
--- so the exact tagged F16 edge can be routed to the LLM.
--- @param raw string
--- @return boolean valid
local function raw_provenance_gates_precede_physical_work(raw)
	local code = strip_line_comments(raw)
	local epoch_at = code:find("SyntheticInput.current_action_epoch()", 1, true)
	local observe_at = code:find("observe_action_epoch(action_epoch)", 1, true)
	local stale_at = code:find(
		"if provenance and provenance.stale_loopback then return true end", 1, true)
	local unreadable_at = code:find(
		"if provenance_status == EventProvenance.STATUS_UNREADABLE then", 1, true)
	local ordinary_owned_at = code:find(
		"if provenance and not internal_loopback then return false end", 1, true)
	local decode_at = code:find("e:getKeyCode()", 1, true)
	local live_loopback_at = decode_at and code:find("if internal_loopback then", decode_at, true)
	if not (epoch_at and observe_at and stale_at and unreadable_at and ordinary_owned_at
		and decode_at and live_loopback_at) then
		return false
	end
	if not (epoch_at < observe_at and observe_at < stale_at and stale_at < unreadable_at
		and unreadable_at < ordinary_owned_at and ordinary_owned_at < decode_at
		and decode_at < live_loopback_at) then
		return false
	end
	local physical_routes = {
		"e:getKeyCode()",
		"e:getFlags()",
		"e:getCharacters(false)",
		"LLMBridge.handle_llm_keys",
		"CoreState.buffer = CoreState.buffer .. chars",
	}
	for _, route in ipairs(physical_routes) do
		local route_at = code:find(route, 1, true)
		if route_at == nil or route_at <= ordinary_owned_at then return false end
	end
	return true
end


local FORBIDDEN_SYNTHETIC_HEURISTICS = {
	"dt < 0.02",
	"eventSourceUnixProcessID",
	"hs.processInfo.processID",
	"SOURCE_PID_PROPERTY",
	"CURRENT_PROCESS_ID",
	"source_pid",
	"pid_matches",
	"event_is_ours",
	"expected_synthetic_",
}


--- @param source string
--- @return boolean valid
local function has_no_synthetic_heuristic(source)
	local code = strip_line_comments(source)
	for _, marker in ipairs(FORBIDDEN_SYNTHETIC_HEURISTICS) do
		if code:find(marker, 1, true) then return false end
	end
	return true
end





-- ===============================================================================
-- ===============================================================================
-- ======= 1/ gestures/engine.lua — diagonal uses dist (not and condition) =======
-- ===============================================================================
-- ===============================================================================

helpers.describe("gestures/engine.lua: diagonal detection uses total distance (audit-v5)", function()

	-- computeDir() (which owns the diagonal-distance guard) was extracted from
	-- gestures/engine.lua into the self-contained gestures/geometry.lua. Read
	-- both so the guard assertions survive that move (move-resilient).
	local function read_geometry_src()
		return (read_source("local function triggerLiveAxisIfNeeded") or "") ..
			"\n" .. (read_source("function M.slotForDir") or "")
	end

	helpers.it("old `adx >= diagMin and ady >= diagMin` pattern is gone", function()
		local src = read_geometry_src()
		helpers.assert_true(
			not src:find("adx >= diagMin and ady >= diagMin", 1, true),
			"engine/geometry must not use `adx >= diagMin and ady >= diagMin` (requires 2x distance)")
	end)

	helpers.it("diagonal check uses `dist >= diagMin`", function()
		local src = read_geometry_src()
		helpers.assert_true(
			src:find("dist >= diagMin", 1, true) ~= nil,
			"engine/geometry diagonal check must use `dist >= diagMin` (Manhattan total distance)")
	end)

end)





-- ================================================================================
-- ================================================================================
-- ======= 2/ api_mlx.lua — reset_endpoints arms a 15s PGID-pending timeout =======
-- ================================================================================
-- ================================================================================

helpers.describe("modules/llm/api_mlx.lua: PGID-pending safety timeout (audit-v5)", function()

	helpers.it("declares _pgid_pending_timeout variable", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		helpers.assert_true(
			src:find("_pgid_pending_timeout", 1, true) ~= nil,
			"api_mlx.lua must declare _pgid_pending_timeout for the safety-timeout handle")
	end)

	helpers.it("reset_endpoints arms a TimerScheduler.after(15", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		-- Find the reset_endpoints function body
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		helpers.assert_true(idx ~= nil, "reset_endpoints must exist in api_mlx.lua")
		-- Extract up to the closing `end` of that function
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("TimerScheduler%.after%(15", 1, false) ~= nil,
			"reset_endpoints must call TimerScheduler.after(15...) to arm the PGID-pending safety timeout")
	end)

	helpers.it("timeout callback clears _server_pgid_pending", function()
		local src = read_source("local function read_user_port_override") -- modules/llm/api_mlx.lua
		local idx = src:find("function M%.reset_endpoints%(", 1, false)
		local rest = src:sub(idx)
		local _, stop = rest:find("\nend\n")
		local body = stop and rest:sub(1, stop) or rest
		helpers.assert_true(
			body:find("_server_pgid_pending%s*=%s*false", 1, false) ~= nil,
			"reset_endpoints timeout must set _server_pgid_pending = false on expiry")
	end)

end)




-- ================================================================================
-- ================================================================================
-- ======= 3/ keymap/init.lua — synthetic ledger uses provenance ===================
-- ================================================================================
-- ================================================================================

helpers.describe("modules/keymap/init.lua: synthetic ledger is provenance-gated (audit-v5)", function()

	helpers.it("classifies exactly once with the physical fence before every raw route", function()
		local src = read_unit("local function invalidate_observed_context")
		local _, wrapper = keydown_slices(src)
		helpers.assert_true(wrapper_has_single_fenced_route(wrapper),
			"the wrapper must call classify_with_fence(e, keymap) exactly once, then pass "
				.. "that metadata and status to its only onKeyDownRaw route")

		local classifier_mutant, replacements = wrapper:gsub(
			"EventProvenance%.classify_with_fence", "EventProvenance.classify", 1)
		helpers.assert_eq(replacements, 1,
			"the sensitivity mutation must replace the one real fenced classifier")
		helpers.assert_true(not wrapper_has_single_fenced_route(classifier_mutant),
			"the guard must fail if classification loses the physical-ordering fence")

		local sibling_route_mutant = wrapper .. "\nlocal _ = onKeyDownRaw(e)"
		helpers.assert_true(not wrapper_has_single_fenced_route(sibling_route_mutant),
			"the guard must fail if a sibling raw route bypasses the classified metadata")
	end)

	helpers.it("reconciles the epoch, then filters stale/unreadable/ordinary owned events", function()
		local src = read_unit("local function invalidate_observed_context")
		local raw = keydown_slices(src)
		helpers.assert_true(raw_provenance_gates_precede_physical_work(raw),
			"epoch observation and all non-loopback provenance gates must precede key decode, "
				.. "LLM routing, interceptors, and buffer mutation")

		local gate = "if provenance and not internal_loopback then return false end"
		local gate_at = raw:find(gate, 1, true)
		local gate_end = gate_at and (gate_at + #gate - 1)
		helpers.assert_not_nil(gate_at,
			"the ordinary-owned sensitivity mutation needs the real gate")
		local without_gate = raw:sub(1, gate_at - 1) .. raw:sub(gate_end + 1)
		local decode = "local keyCode = e:getKeyCode()"
		local decode_at = without_gate:find(decode, 1, true)
		helpers.assert_not_nil(decode_at, "the key decode must remain locatable")
		local late_gate_mutant = without_gate:sub(1, decode_at + #decode - 1)
			.. "\n\t" .. gate .. without_gate:sub(decode_at + #decode)
		helpers.assert_true(not raw_provenance_gates_precede_physical_work(late_gate_mutant),
			"the guard must fail if ordinary owned echoes reach native key decoding")
	end)

	-- The purge used to be pinned to its position after an `elseif dt < 0.02`
	-- tolerance window, which made the WINDOW part of the protected contract. The
	-- window was itself a defect: it classified any keystroke arriving within
	-- 20 ms of the previous one as our own echo and dropped it from the buffer,
	-- so a fast typist's real characters stayed on screen but stopped being
	-- tracked — and the next expansion sized its backspaces against a buffer
	-- shorter than the line, erasing text the user had typed. The invariant worth
	-- protecting was never "a 20 ms window exists"; it is "ledger mutation is
	-- allowed only after provenance is proven". The behavioral interleaving tests
	-- additionally prove that foreign exact/mismatch events traverse the human path.
	helpers.it("timing, PID, and character-ledger heuristics cannot regain ownership", function()
		local src = read_unit("local function invalidate_observed_context")
		helpers.assert_true(has_no_synthetic_heuristic(src),
			"keymap synthetic identity must not use timing, source PID, character equality, "
				.. "or the removed expected_synthetic ledger")
		for _, marker in ipairs(FORBIDDEN_SYNTHETIC_HEURISTICS) do
			local mutant = src .. "\n" .. marker
			helpers.assert_true(not has_no_synthetic_heuristic(mutant),
				"the heuristic class guard must be sensitive to: " .. marker)
		end
	end)

end)




-- =========================================================================
-- =========================================================================
-- ======= 4/ init.lua — grep -c . uses || true for set -e safety ==========
-- =========================================================================
-- =========================================================================

helpers.describe("boot_cleanup.lua: grep -c . is guarded with || true (audit-v5)", function()

	helpers.it("grep -c . is followed by || true", function()
		-- The MLX boot kill_cmd was extracted from init.lua into the
		-- modules/llm/boot_cleanup.lua sibling; the set -e guard moved with it.
		-- Selected by a declaration unique to modules/llm/boot_cleanup.lua rather than by
		-- path, so moving or splitting the module cannot turn this invariant
		-- into a path error.
		local src = helpers.read_driver_source("function M.run_selective_cleanup")
		helpers.assert_true(src ~= nil, "modules/llm/boot_cleanup.lua source must be locatable")
		helpers.assert_true(
			src:find("grep -c . || true", 1, true) ~= nil,
			"boot_cleanup.lua kill_cmd must use `grep -c . || true` to survive set -e shells")
	end)

end)
