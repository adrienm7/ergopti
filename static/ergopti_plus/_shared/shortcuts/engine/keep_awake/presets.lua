--- _shared/shortcuts/engine/keep_awake/presets.lua

--- ==============================================================================
--- MODULE: Anti-Sleep Presets — Shared Lua Implementation
--- DESCRIPTION:
--- The presets of the anti-sleep mode (Ctrl+M): which preset is active, its
--- keep-awake and auto-click switches, its allowed apps and its targets, and
--- what one OS runs for it. The macOS and Linux drivers keep their presets
--- document through this module; the Windows driver runs a twin pinned by the
--- same corpus.
---
--- FEATURES & RATIONALE:
--- 1. Persisted, never rebuilt: the user's document (auto_click/presets.json
---    in the configuration folder) starts as a copy of the starters
---    (_shared/shortcuts/data/keep_awake_presets.json) and every change is an
---    edit of that document, so a Ctrl+M never resets a library. A starter
---    later removed from the starters file stays in the documents that copied
---    it, named after its id once its translated name is gone.
--- 2. Every edit validates first and changes nothing on a refusal, which it
---    returns as a reason; the caller writes the document only after a success.
--- 3. The last preset cannot be deleted, and deleting the active one makes the
---    first remaining preset active, so Ctrl+M always has a preset to run.
--- 4. plan() is the one place a preset becomes what a driver runs: the allowed
---    apps of its OS, its enabled image targets with their file paths and
---    thresholds, its enabled text targets.
---
--- Pinned by _shared/tests/corpus/keep_awake/keep_awake_presets_vectors.json.
--- ==============================================================================

local M = {}

-- The OS names a preset's allowed apps are keyed by.
M.OSES = { "macos", "windows", "linux" }

-- The switches a preset carries.
M.SWITCHES = { keep_awake = true, auto_click = true }




-- =============================================
-- =============================================
-- ======= 1/ Validation =======================
-- =============================================
-- =============================================

local copy = require("core.text.engine.table_util").deep_copy

local function valid_id(id)
	return type(id) == "string" and id:match("^[%w_%-]+$") ~= nil and #id <= 64
end

--- Why a preset is invalid, or nil when it is valid.
--- @param preset table
--- @return string|nil reason
function M.invalid(preset)
	if type(preset) ~= "table" or not valid_id(preset.id) then return "preset_invalid_id" end
	if type(preset.name) ~= "string" and type(preset.name_key) ~= "string" then return "preset_invalid_name" end
	if type(preset.keep_awake) ~= "boolean" or type(preset.auto_click) ~= "boolean" then
		return "preset_invalid_switch"
	end
	if type(preset.allowed_apps) ~= "table" then return "preset_invalid_apps" end
	for _, os_name in ipairs(M.OSES) do
		local apps = preset.allowed_apps[os_name]
		if type(apps) ~= "table" then return "preset_invalid_apps" end
		for _, app in ipairs(apps) do
			if type(app) ~= "string" or app == "" then return "preset_invalid_apps" end
		end
	end
	if type(preset.images) ~= "table" or type(preset.texts) ~= "table" then return "preset_invalid_targets" end
	local seen = {}
	for _, image in ipairs(preset.images) do
		if not valid_id(image.id) or seen[image.id] or type(image.file) ~= "string"
			or not image.file:match("^[%w_%-]+%.png$") or type(image.enabled) ~= "boolean"
			or (image.threshold ~= nil and (type(image.threshold) ~= "number" or image.threshold <= 0
				or image.threshold > 1)) then
			return "preset_invalid_targets"
		end
		seen[image.id] = true
	end
	for _, text in ipairs(preset.texts) do
		if not valid_id(text.id) or seen[text.id] or type(text.variants) ~= "table" or #text.variants == 0
			or type(text.max_distance) ~= "number" or text.max_distance < 0 or text.max_distance % 1 ~= 0
			or type(text.enabled) ~= "boolean" then
			return "preset_invalid_targets"
		end
		for _, variant in ipairs(text.variants) do
			if type(variant) ~= "string" or variant == "" then return "preset_invalid_targets" end
		end
		seen[text.id] = true
	end
	return nil
end

local function index_of(doc, id)
	for index, preset in ipairs(doc.presets) do
		if preset.id == id then return index end
	end
	return nil
end




-- =============================================
-- =============================================
-- ======= 2/ Document =========================
-- =============================================
-- =============================================

--- The user's document, or a copy of the starters when there is none yet.
--- @param starters table The decoded starters file.
--- @param saved table|nil The decoded user document.
--- @return table|nil doc { version, active, presets }; nil with a reason for a broken saved document.
--- @return string|nil reason
function M.load(starters, saved)
	assert(type(starters) == "table" and type(starters.presets) == "table", "the starter presets are required")
	for _, preset in ipairs(starters.presets) do
		assert(M.invalid(preset) == nil, "a starter preset is invalid: " .. tostring(preset.id))
	end
	if saved == nil then
		return { version = starters.version, active = starters.default_active, presets = copy(starters.presets) }
	end
	if type(saved) ~= "table" or saved.version ~= starters.version or type(saved.presets) ~= "table"
		or #saved.presets == 0 then
		return nil, "presets_document_invalid"
	end
	local seen = {}
	for _, preset in ipairs(saved.presets) do
		if M.invalid(preset) or seen[preset.id] then return nil, "presets_document_invalid" end
		seen[preset.id] = true
	end
	local doc = copy(saved)
	-- A copy of a starter the starters file no longer ships (« teams », removed
	-- 2026-11-26) is the user's data and stays, active or not; only its name
	-- pointed at shipped text, whose key is gone, so it takes its id as its name.
	local shipped = {}
	for _, preset in ipairs(starters.presets) do shipped[preset.name_key] = true end
	for _, preset in ipairs(doc.presets) do
		if preset.name == nil and not shipped[preset.name_key] then
			preset.name, preset.name_key = preset.id, nil
		end
	end
	if not index_of(doc, doc.active) then doc.active = doc.presets[1].id end
	return doc
end

--- The active preset.
function M.active(doc)
	return doc.presets[index_of(doc, doc.active)]
end

--- One preset by id, or nil.
function M.get(doc, id)
	local index = index_of(doc, id)
	return index and doc.presets[index] or nil
end

--- Makes a preset the active one.
--- @return boolean ok, string|nil reason
function M.set_active(doc, id)
	if not index_of(doc, id) then return false, "preset_unknown" end
	doc.active = id
	return true
end

--- Sets one switch (keep_awake or auto_click) of a preset.
--- @return boolean ok, string|nil reason
function M.set_switch(doc, id, switch, value)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	if not M.SWITCHES[switch] or type(value) ~= "boolean" then return false, "preset_invalid_switch" end
	preset[switch] = value
	return true
end

--- Copies a preset under a new id and name.
--- @return boolean ok, string|nil reason
function M.duplicate(doc, id, new_id, name)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	if not valid_id(new_id) then return false, "preset_invalid_id" end
	if index_of(doc, new_id) then return false, "preset_id_taken" end
	if type(name) ~= "string" or name == "" then return false, "preset_invalid_name" end
	local clone = copy(preset)
	clone.id, clone.name, clone.name_key = new_id, name, nil
	doc.presets[#doc.presets + 1] = clone
	return true
end

--- Adds a preset (an imported one), validated first.
--- @param preset table The whole preset, its targets included.
--- @return boolean ok, string|nil reason
function M.add(doc, preset)
	local reason = M.invalid(preset)
	if reason then return false, reason end
	if index_of(doc, preset.id) then return false, "preset_id_taken" end
	doc.presets[#doc.presets + 1] = copy(preset)
	return true
end

--- Renames a preset; a starter's translated name gives way to the user's.
--- @return boolean ok, string|nil reason
function M.rename(doc, id, name)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	if type(name) ~= "string" or name == "" then return false, "preset_invalid_name" end
	preset.name, preset.name_key = name, nil
	return true
end

--- Deletes a preset; the last one stays.
--- @return boolean ok, string|nil reason
function M.remove(doc, id)
	local index = index_of(doc, id)
	if not index then return false, "preset_unknown" end
	if #doc.presets == 1 then return false, "preset_last" end
	table.remove(doc.presets, index)
	if doc.active == id then doc.active = doc.presets[1].id end
	return true
end

--- Replaces a preset's allowed apps for one OS.
--- @return boolean ok, string|nil reason
function M.set_apps(doc, id, os_name, apps)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	local trial = copy(preset)
	if trial.allowed_apps[os_name] == nil then return false, "preset_invalid_apps" end
	trial.allowed_apps[os_name] = copy(apps)
	local reason = M.invalid(trial)
	if reason then return false, reason end
	preset.allowed_apps[os_name] = copy(apps)
	return true
end

--- Adds or replaces a target of a preset.
--- @param kind string "images" or "texts".
--- @param target table The image { id, file, threshold, enabled } or text { id, variants, max_distance, enabled }.
--- @return boolean ok, string|nil reason
function M.put_target(doc, id, kind, target)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	if kind ~= "images" and kind ~= "texts" then return false, "preset_invalid_targets" end
	local trial = copy(preset)
	local list, replaced = trial[kind], false
	for index, existing in ipairs(list) do
		if existing.id == target.id then list[index] = copy(target); replaced = true end
	end
	if not replaced then list[#list + 1] = copy(target) end
	local reason = M.invalid(trial)
	if reason then return false, reason end
	preset[kind] = trial[kind]
	return true
end

--- Removes a target of a preset.
--- @return boolean ok, string|nil reason
function M.remove_target(doc, id, target_id)
	local preset = M.get(doc, id)
	if not preset then return false, "preset_unknown" end
	for _, kind in ipairs({ "images", "texts" }) do
		for index, target in ipairs(preset[kind]) do
			if target.id == target_id then
				table.remove(preset[kind], index)
				return true
			end
		end
	end
	return false, "target_unknown"
end




-- =============================================
-- =============================================
-- ======= 3/ Plan =============================
-- =============================================
-- =============================================

--- What a driver runs for a preset on its OS.
--- @param preset table
--- @param os_name string "macos", "windows" or "linux".
--- @param images_dir string The library's image folder, without trailing separator.
--- @param separator string The OS path separator.
--- @param defaults table auto_click_defaults.json (threshold).
--- @return table plan { keep_awake, auto_click, allowed_apps, templates, text_targets }
function M.plan(preset, os_name, images_dir, separator, defaults)
	assert(M.invalid(preset) == nil, "a plan needs a valid preset")
	assert(preset.allowed_apps[os_name], "unknown OS " .. tostring(os_name))
	local templates, text_targets = {}, {}
	for _, image in ipairs(preset.images) do
		if image.enabled then
			templates[#templates + 1] = { id = image.id, path = images_dir .. separator .. image.file,
				threshold = image.threshold or defaults.threshold }
		end
	end
	for _, text in ipairs(preset.texts) do
		if text.enabled then
			text_targets[#text_targets + 1] = { id = text.id, variants = copy(text.variants),
				max_distance = text.max_distance }
		end
	end
	return {
		keep_awake = preset.keep_awake,
		auto_click = preset.auto_click,
		allowed_apps = copy(preset.allowed_apps[os_name]),
		templates = templates,
		text_targets = text_targets,
	}
end

return M
