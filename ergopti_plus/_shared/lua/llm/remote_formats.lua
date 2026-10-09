--- _shared/lua/llm/remote_formats.lua

--- ==============================================================================
--- MODULE: Remote API Formats Beyond Chat Completions — Shared Lua Implementation
--- DESCRIPTION:
--- The request and answer shapes of the two provider formats of
--- _shared/modules/llm/api_providers.json that are not an OpenAI, Anthropic or
--- Gemini chat call:
--- - "backboard": Backboard's assistant/thread API (app.backboard.io). One
---   assistant is created once per key; each request is a message on a new
---   thread, with the provider and the model named per message
---   ("<llm_provider>/<model_name>", e.g. "openai/gpt-4o-mini"), and the answer
---   comes back in `content`.
--- - "decisions": TypeSafe's System One protocol (/v1/systemone, also served by
---   OpenRouter at /api/alpha/decisions): typed questions in, answers with
---   probabilities out. Jev, the model it serves, is not a chat model.
---
--- Also classify own root error fields in decoded chat responses, including
--- explicit null and false; nested and inherited metadata remain independent.
---
--- FEATURES & RATIONALE:
--- 1. The shapes come from the providers' own clients (Backboard-R-CLI,
---    the TypeSafe SDK wrapper pi-typesafe), since their documentation hosts are
---    not reachable from the build environment.
--- 2. Jev through Backboard is a Backboard message with `system_one.questions`.
---    Where Backboard returns Jev's answers is not documented in those clients:
---    backboard_decision_answers() reads each known location in a fixed order and
---    names the one it used, so the driver logs it and a wrong guess shows up at
---    the first real request instead of passing silently.
--- 3. Credentials never enter a body: the drivers put the key in the header
---    named by the provider's format.
---
--- The AutoHotkey port is windows/modules/llm/remote_formats.ahk. Both are
--- pinned by _shared/tests/corpus/llm/remote_formats_vectors.json.
--- ==============================================================================

local M = {}





-- =============================
-- =============================
-- ======= 1/ Backboard ========
-- =============================
-- =============================

-- Header carrying a Backboard key
M.BACKBOARD_KEY_HEADER = "X-API-Key"

-- Name of the one assistant the driver creates per key
M.BACKBOARD_ASSISTANT_NAME = "Ergopti+"

--- Splits a Backboard model id into the provider and the model it names.
--- @param model string "<llm_provider>/<model_name>".
--- @return string|nil provider, string|nil name Nil when the id has no provider.
function M.backboard_split_model(model)
	if type(model) ~= "string" then return nil end
	local provider, name = model:match("^([%w][%w%-_%.]*)/(.+)$")
	if provider == nil or name:match("^%s") or name:match("%s$") then return nil end
	return provider, name
end

--- Returns the request that creates the driver's assistant.
--- @param base_url string The provider's base_url.
--- @return table request { url, body }
function M.backboard_assistant_request(base_url)
	return {
		url = base_url .. "/assistants",
		body = { name = M.BACKBOARD_ASSISTANT_NAME, system_prompt = "" },
	}
end

--- Reads the assistant id out of a decoded creation answer.
--- @param response table
--- @return string|nil
function M.backboard_assistant_id(response)
	local id = type(response) == "table" and response.assistant_id or nil
	if type(id) ~= "string" or id == "" then return nil end
	return id
end

--- Returns the request that sends one message on a new thread.
--- @param base_url string The provider's base_url.
--- @param spec table { assistant_id, model, system, text, questions? }
--- @return table|nil request { url, body }, nil when the model names no provider.
function M.backboard_message_request(base_url, spec)
	local provider, name = M.backboard_split_model(spec.model)
	if provider == nil then return nil end
	local body = {
		content = spec.text,
		assistant_id = spec.assistant_id,
		llm_provider = provider,
		model_name = name,
		system_prompt = spec.system,
		memory = "off",
		stream = false,
	}
	if spec.questions ~= nil then body.system_one = { questions = spec.questions } end
	return { url = base_url .. "/threads/messages", body = body }
end

--- Reads the answer text of a decoded message answer.
--- @param response table
--- @return string|nil
function M.backboard_text(response)
	local content = type(response) == "table" and response.content or nil
	if type(content) ~= "string" then return nil end
	return content
end

--- Finds Jev's answers in a decoded Backboard message answer.
--- @param response table The decoded answer.
--- @param decode function Decodes a JSON text; may raise.
--- @return table|nil answers, string|nil where "system_one", "answers" or "content".
function M.backboard_decision_answers(response, decode)
	if type(response) ~= "table" then return nil end
	local system_one = response.system_one
	if type(system_one) == "table" and type(system_one.answers) == "table" then
		return system_one.answers, "system_one"
	end
	if type(response.answers) == "table" then return response.answers, "answers" end
	if type(response.content) == "string" then
		local ok, decoded = pcall(decode, response.content)
		if ok and type(decoded) == "table" and type(decoded.answers) == "table" then
			return decoded.answers, "content"
		end
	end
	return nil
end





-- ================================
-- ================================
-- ======= 2/ Decisions ===========
-- ================================
-- ================================

-- Header carrying a decisions key
M.DECISIONS_KEY_HEADER = "Authorization"

--- Returns the header value carrying a decisions key.
--- @param key string
--- @return string
function M.decisions_key_value(key)
	return "Bearer " .. key
end

--- Returns the body of a decisions request.
--- @param model string e.g. "jev-latest" or "typesafe/jev-1.13".
--- @param state string|table What the questions are about.
--- @param questions table { [id] = { type, instructions, criteria } }
--- @return table body
function M.decisions_body(model, state, questions)
	return { model = model, state = state, questions = questions }
end

--- Reads the answers of a decoded decisions answer.
--- @param response table
--- @return table|nil answers
function M.decisions_answers(response)
	local answers = type(response) == "table" and response.answers or nil
	if type(answers) ~= "table" then return nil end
	return answers
end






-- =========================================
-- =========================================
-- ======= 3/ Response error fields ========
-- =========================================
-- =========================================

--- Whether a decoded provider response owns a top-level error field.
--- An explicit null or false still names an error envelope; nested metadata
--- and inherited fields cannot invalidate an otherwise ordinary completion.
--- @param response any Decoded response root.
--- @return boolean
function M.response_has_error(response)
	return type(response) == "table" and rawget(response, "error") ~= nil
end

return M
