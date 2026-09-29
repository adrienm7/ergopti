--- _shared/lua/llm/vision.lua

--- ==============================================================================
--- MODULE: Screen Reading — Shared Lua Implementation
--- DESCRIPTION:
--- The pure logic behind the llm_screen_region and llm_screen_full actions: a
--- vision model transcribes a screenshot, then the AI menu's text backend
--- drafts the answers offered in the prediction tooltip.
---
--- FEATURES & RATIONALE:
--- 1. The binding names the vision backend: "local" (the local Ollama server)
---    or a provider of _shared/modules/llm/api_providers.json, optionally
---    followed by |model. Without a model the default of vision.json applies;
---    a backend without one needs the model in the binding, never a guess.
--- 2. Each API dialect carries an image differently; build_request() writes
---    the request body for all four (openai, anthropic, gemini, ollama), so the
---    drivers only add the address and the credentials.
--- 3. Prompts, tags, token budgets and defaults live in vision.json, read by
---    every driver.
---
--- The AutoHotkey port is windows/modules/llm/vision.ahk. Both are pinned by
--- _shared/tests/corpus/llm/vision_vectors.json.
--- ==============================================================================

local M = {}




-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Backend id of the local server; every other id is an API provider
M.LOCAL_BACKEND = "local"

-- Longest model name a binding may carry
M.MAX_MODEL_LENGTH = 200

-- Request formats build_request() writes
M.FORMATS = { openai = true, anthropic = true, gemini = true, ollama = true }

-- The user turn that goes with the screenshot of the reading request
M.READ_USER_TEXT = "Transcribe this screenshot."




-- =====================================
-- =====================================
-- ======= 2/ Binding parameter ========
-- =====================================
-- =====================================

--- Parses a binding value: "<backend>" or "<backend>|<model>".
--- @param value string The stored parameter.
--- @return table|nil parsed { backend = string, model = string|nil }.
--- @return string|nil err Reason the value is invalid.
function M.parse(value)
	if type(value) ~= "string" then return nil, "not a string" end
	local backend, model = value:match("^([^|]*)|(.*)$")
	if not backend then backend, model = value, nil end
	if not backend:match("^[a-z][a-z0-9_]*$") then return nil, "invalid backend id" end
	if model == nil then return { backend = backend }, nil end
	if model == "" or #model > M.MAX_MODEL_LENGTH then return nil, "invalid model length" end
	if model:find("[%c|]") or model:match("^%s") or model:match("%s$") then
		return nil, "invalid model name"
	end
	return { backend = backend, model = model }, nil
end

--- Tells whether a binding value is syntactically valid.
--- @param value string The stored parameter.
--- @return boolean ok
function M.is_valid(value)
	return M.parse(value) ~= nil
end

--- Resolves the vision model a parsed binding runs.
--- @param parsed table parse() output.
--- @param config table The decoded vision.json.
--- @return string|nil model The model, nil when the backend has no default.
function M.resolve_model(parsed, config)
	if parsed.model then return parsed.model end
	local defaults = type(config) == "table" and config.default_models or nil
	return type(defaults) == "table" and defaults[parsed.backend] or nil
end




-- =====================================
-- =====================================
-- ======= 3/ Requests =================
-- =====================================
-- =====================================

--- Builds the request body of one vision or text call.
--- @param format string "openai", "anthropic", "gemini" or "ollama".
--- @param spec table { model, system, text, image (base64 or nil), mime, max_tokens }.
--- @return table body The JSON body, without address or credentials.
function M.build_request(format, spec)
	if not M.FORMATS[format] then error("vision.build_request: unknown format " .. tostring(format)) end
	local image, mime = spec.image, spec.mime
	if image ~= nil and (type(image) ~= "string" or image == "" or type(mime) ~= "string") then
		error("vision.build_request: an image needs base64 data and a mime type")
	end
	if format == "openai" then
		local content = spec.text
		if image then
			content = {
				{ type = "text", text = spec.text },
				{ type = "image_url", image_url = { url = "data:" .. mime .. ";base64," .. image } },
			}
		end
		return {
			model = spec.model,
			max_tokens = spec.max_tokens,
			stream = false,
			messages = { { role = "system", content = spec.system }, { role = "user", content = content } },
		}
	elseif format == "anthropic" then
		local content = { { type = "text", text = spec.text } }
		if image then
			table.insert(content, 1,
				{ type = "image", source = { type = "base64", media_type = mime, data = image } })
		end
		return {
			model = spec.model,
			max_tokens = spec.max_tokens,
			system = spec.system,
			messages = { { role = "user", content = content } },
		}
	elseif format == "gemini" then
		local parts = { { text = spec.text } }
		if image then table.insert(parts, 1, { inline_data = { mime_type = mime, data = image } }) end
		return {
			system_instruction = { parts = { { text = spec.system } } },
			contents = { { role = "user", parts = parts } },
			generationConfig = { maxOutputTokens = spec.max_tokens },
		}
	end
	local user = { role = "user", content = spec.text }
	if image then user.images = { image } end
	return {
		model = spec.model,
		stream = false,
		messages = { { role = "system", content = spec.system }, user },
		options = { num_predict = spec.max_tokens },
	}
end

--- Returns an answer prompt with the interface language filled in.
--- @param prompt string A prompt of vision.json.
--- @param language string The interface language name.
--- @return string prompt
function M.fill_language(prompt, language)
	return (prompt:gsub("{language}", function() return language end))
end

--- Returns the user turn of an answer request.
--- @param screen string The transcription.
--- @return string text
function M.answer_user_text(screen)
	return "SCREEN:\n" .. screen
end

--- Extracts the text a model wrote after a tag, over any number of lines.
--- @param block string The raw model answer.
--- @param tag string The tag, e.g. "SCREEN:" or "ANSWER:".
--- @return string|nil text Trimmed text, nil when the tag is absent or nothing follows it.
function M.extract(block, tag)
	if type(block) ~= "string" or type(tag) ~= "string" or tag == "" then return nil end
	local at = block:upper():find(tag:upper(), 1, true)
	if not at then return nil end
	local text = block:sub(at + #tag):gsub("%*%*", "")
	text = text:match("^%s*(.-)%s*$")
	if text == "" then return nil end
	return text
end

return M
