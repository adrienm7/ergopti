-- _shared/lua/llm/request_plan/info_bar.lua

--- ==============================================================================
--- MODULE: LLM Request Plan — Info Bar
--- DESCRIPTION:
--- Decides which pieces the line under the predictions carries and in which
--- order: the model, the backend, the prompt's short name and the position among
--- the candidates. Drivers join the pieces with their own separator and draw
--- them with their own tooltip renderer.
---
--- FEATURES & RATIONALE:
--- 1. Pure: strings and numbers in, an ordered list of strings out.
--- 2. One short-name rule for a prompt's label: the menu's long form
---    "Basic — Simple prediction" shows as "Basic" on every OS, and a label that
---    is only a dash suffix is blank rather than an odd fragment.
--- 3. Deliberate driver differences stay in the caller's options, never in
---    hidden branches: `require_model` (macOS hides the whole bar without a
---    model; Linux still names the prompt) and `position` (Linux cycles
---    candidates and shows i/n; macOS lists them all and passes none).
---
--- Pinned by _shared/tests/corpus/llm/request_plan_info_bar_vectors.json.
--- ==============================================================================

local TextUtils = require("text_utils")

local M = {}

local DASH = "\226\128\148"




-- =================================
-- =================================
-- ======= 1/ Public API ===========
-- =================================
-- =================================

--- Short name of a prompt label for the compact bar.
--- @param label string|nil The raw label as the menu shows it.
--- @return string|nil short The label up to its first em dash, or nil when blank.
function M.short_profile_label(label)
	if type(label) ~= "string" then return nil end
	local clean = TextUtils.trim(label)
	if clean == "" then return nil end
	local head = clean:match("^(.-)%s*" .. DASH)
	local picked = (head and head:match("%S")) and TextUtils.trim(head) or clean
	picked = TextUtils.trim((picked:gsub("%s*" .. DASH .. "%s*$", "")))
	if picked == "" then return nil end
	return picked
end

--- Pieces of the info bar, in display order.
--- @param spec table { model?, backend?, profile_label?, position? = { index, count }, require_model? }
--- @return table|nil parts Ordered strings, or nil when nothing is to be shown.
function M.parts(spec)
	if type(spec) ~= "table" then error("spec must be a table", 2) end
	local model = type(spec.model) == "string" and spec.model ~= "" and spec.model or nil
	if spec.require_model == true and not model then return nil end
	local parts = {}
	if model then parts[#parts + 1] = model end
	if type(spec.backend) == "string" and spec.backend ~= "" then parts[#parts + 1] = spec.backend end
	local short = M.short_profile_label(spec.profile_label)
	if short then parts[#parts + 1] = short end
	local position = spec.position
	if position ~= nil then
		if type(position) ~= "table" or type(position.index) ~= "number" or type(position.count) ~= "number" then
			error("position must be { index, count } numbers", 2)
		end
		if position.count > 1 then parts[#parts + 1] = string.format("%d/%d", position.index, position.count) end
	end
	if #parts == 0 then return nil end
	return parts
end

return M
