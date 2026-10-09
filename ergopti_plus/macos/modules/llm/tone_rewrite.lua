--- modules/llm/tone_rewrite.lua

--- ==============================================================================
--- MODULE: Tone Rewrite of the Selection
--- DESCRIPTION:
--- Runs the llm_tone_more_formal / llm_tone_more_familiar actions and their
--- _cycle variants: the selection is rewritten one register up or down the tone
--- ladder (_shared/lua/llm/tone.lua) and replaced at once, and the rewrite stays
--- selected so the next step applies to it.
---
--- FEATURES & RATIONALE:
--- 1. The selection is read and replaced through the clipboard pipeline of the
---    wrap_selection and case actions (modules/shortcuts/actions/text.lua), so
---    Electron apps, which expose no AXSelectedText, work too.
--- 2. Every step rewrites the ORIGINAL text: the memory of the last rewrite ties
---    the selected rewrite back to what the user wrote, so going back and forth
---    never drifts.
--- 3. One request is in flight: a new step supersedes the previous one, whose
---    answer is dropped by generation. An answer that arrives after the user
---    moved to another window, or changed the selection, is dropped too: text
---    is never typed where it was not asked for.
--- 4. One unparsed request to the current backend (modules/llm/init.lua
---    fetch_raw_completion), with no tooltip and no streaming: the answer
---    replaces the selection as soon as it arrives.
--- ==============================================================================

local M = {}

local Tone       = require("llm.tone")
local Logger     = require("infra.logger")
local i18n       = require("infra.i18n")
local WindowInfo = require("adapters.window_info")

local LOG = "llm.tone_rewrite"

-- The notice shown at each end of the ladder, by direction
local END_OF_LADDER_KEYS = {
	[Tone.MORE_FORMAL] = "llm.tone.most_formal",
	[Tone.MORE_FAMILIAR] = "llm.tone.most_familiar",
}

-- The last rewrite this module typed: { source, output, level }, or nil
local _memory = nil

-- Generation of the current step; a callback of an older step is stale
local _generation = 0




-- =====================================
-- =====================================
-- ======= 1/ Internal Helpers =========
-- =====================================
-- =====================================

--- Shows a notice explaining why a step did nothing.
--- @param key string Locale key of the notice.
local function show_notice(key)
	local ok_tooltip, tooltip = pcall(require, "ui.tooltip")
	local ok_show, shown = false, nil
	if ok_tooltip and type(tooltip) == "table" and type(tooltip.show) == "function" then
		ok_show, shown = pcall(tooltip.show, i18n.get(key), true, true)
	end
	if not ok_show or shown ~= true then
		Logger.warn(LOG, "Tone notice '%s' was not shown: %s.", key, tostring(shown))
	end
end

--- Loads a module the tone actions call at dispatch time.
--- @param name string Module name.
--- @param method string Function the module must expose.
--- @return table|nil module The module, or nil after logging why it is unavailable.
local function dependency(name, method)
	local ok, module = pcall(require, name)
	if not ok or type(module) ~= "table" or type(module[method]) ~= "function" then
		Logger.error(LOG, "Tone step impossible: '%s.%s' is unavailable (%s).", name, method, tostring(module))
		return nil
	end
	return module
end

--- Replaces the selection with the rewrite once the model answered.
--- @param generation number The step the answer belongs to.
--- @param plan table The step's plan (tone.plan).
--- @param selection string The selection the plan was made from.
--- @param focus string The focused window identity when the request was sent.
--- @param block string The model's answer.
--- @param parent string|nil Stable action parent.
local function apply_answer(generation, plan, selection, focus, block, parent)
	if generation ~= _generation then
		Logger.info(LOG, "Tone answer ignored: a newer step superseded it.")
		return
	end
	local text = Tone.extract(block)
	if not text then
		Logger.warn(LOG, "Tone answer ignored: it holds no rewrite ('%s').", tostring(block):sub(1, 120))
		return
	end
	local current_focus = WindowInfo.focused_identity()
	if current_focus == nil or current_focus ~= focus then
		Logger.info(LOG, "Tone answer ignored: the focus moved to another window (%s → %s).",
			tostring(focus), tostring(current_focus))
		return
	end
	local Text = dependency("modules.shortcuts.actions.text", "replace_copied_selection")
	if not Text then return end
	local started = Text.replace_copied_selection(selection, text, parent, function(matched)
		if not matched then
			Logger.info(LOG, "Tone answer ignored: the selection changed while the model answered.")
			return
		end
		-- Remembered as the paste starts: a paste that fails leaves a selection
		-- that does not match the memory, which then restarts at neutral
		_memory = Tone.remember(plan, text)
		Logger.info(LOG, "Selection rewritten to '%s' (%d byte(s)).", plan.profile_id, #text)
	end)
	if not started then
		Logger.warn(LOG, "Tone answer not typed: another text action still owns the clipboard.")
	end
end

--- Plans and requests one step once the selection was read.
--- @param generation number The step.
--- @param direction number Tone.MORE_FORMAL or Tone.MORE_FAMILIAR.
--- @param cycle boolean Whether to wrap around at the ends of the ladder.
--- @param selection string The selected text.
--- @param parent string|nil Stable action parent.
local function request_step(generation, direction, cycle, selection, parent)
	if generation ~= _generation then
		Logger.info(LOG, "Tone step dropped: a newer step superseded it.")
		return
	end
	local plan, reason = Tone.plan(selection, _memory, direction, cycle)
	if not plan then
		if reason == "end_of_ladder" then
			Logger.info(LOG, "Tone step refused: the selection is already at the end of the ladder.")
			show_notice(END_OF_LADDER_KEYS[direction])
		else
			Logger.info(LOG, "Tone step skipped: the selection holds no text (%s).", tostring(reason))
		end
		return
	end
	local engine = dependency("modules.llm.prediction_engine", "request_selection_rewrite")
	if not engine then return end
	local focus = WindowInfo.focused_identity()
	if focus == nil then
		Logger.warn(LOG, "Tone step refused: the focused window cannot be identified.")
		return
	end
	engine.request_selection_rewrite(plan.profile_id, plan.source,
		function(block)
			apply_answer(generation, plan, selection, focus, block, parent)
		end,
		function()
			if generation ~= _generation then return end
			Logger.warn(LOG, "Tone rewrite to '%s' failed: the model gave no answer.", plan.profile_id)
		end)
end




-- =====================================
-- =====================================
-- ======= 2/ Public API ===============
-- =====================================
-- =====================================

--- Rewrites the selection one step along the tone ladder.
--- @param direction number Tone.MORE_FORMAL or Tone.MORE_FAMILIAR.
--- @param cycle boolean Whether to wrap around at the ends of the ladder.
--- @param parent string|nil Stable action parent of the text actions.
--- @return boolean started True when the selection is being read.
function M.step(direction, cycle, parent)
	if direction ~= Tone.MORE_FORMAL and direction ~= Tone.MORE_FAMILIAR then
		error("tone_rewrite.step: direction must be Tone.MORE_FORMAL or Tone.MORE_FAMILIAR")
	end
	if type(cycle) ~= "boolean" then error("tone_rewrite.step: cycle must be a boolean") end
	local Text = dependency("modules.shortcuts.actions.text", "read_copied_selection")
	if not Text then return false end
	local previous = _generation
	_generation = previous + 1
	local generation = _generation
	local started = Text.read_copied_selection(parent, function(selection)
		request_step(generation, direction, cycle, selection, parent)
	end)
	if not started then
		-- Nothing was read: the step in flight, if any, stays the current one
		if _generation == generation then _generation = previous end
		Logger.info(LOG, "Tone step ignored: the selection cannot be read now.")
		return false
	end
	Logger.debug(LOG, "Tone step %d started (direction %d, cycle: %s).", generation, direction, tostring(cycle))
	return true
end

--- Forgets the last rewrite, for tests and a fresh start.
function M.reset()
	_memory = nil
	_generation = _generation + 1
	Logger.debug(LOG, "Tone memory cleared.")
end

--- Returns the memory of the last rewrite, for tests.
--- @return table|nil memory { source, output, level }.
function M.get_memory()
	return _memory
end

return M
