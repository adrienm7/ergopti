--- _shared/lua/llm/agent.lua

--- ==============================================================================
--- MODULE: AI Agent — Shared Lua Implementation
--- DESCRIPTION:
--- The pure logic of the AI agent: System 1 (fast) tells whether a text
--- implies an action, System 2 (slow, smart) turns a text into actions of a
--- closed schema, and the connectors of each driver carry them out once the
--- user accepts one.
---
--- FEATURES & RATIONALE:
--- 1. Nothing a model writes is executed as is: every action is validated
---    field by field against _shared/modules/llm/agent.json, dates must be
---    real local times, addresses real addresses, and a shortcut must name one
---    of the user's own tools.
--- 2. The file formats the connectors hand to the system (an iCalendar event
---    or task, a mailto: link) are built here, so the three drivers write the
---    same bytes.
--- 3. System 1 has two backends: any chat model with the triage prompt, and
---    Jev (TypeSafe's System One model) through its choice question.
---
--- The AutoHotkey port is windows/modules/llm/agent.ahk. Both are pinned by
--- _shared/tests/corpus/llm/agent_vectors.json.
--- ==============================================================================

local M = {}

--- The agent's modes, the same on every driver: off, action (on request) and
--- auto (after a typing pause). A stored mode outside this set is outdated.
M.MODES = { off = true, action = true, auto = true }





-- ======================================
-- ======================================
-- ======= 1/ Prompt placeholders =======
-- ======================================
-- ======================================

--- Replaces every {name} of a template by its value, literally.
--- @param template string
--- @param values table name -> string
--- @return string
local function fill(template, values)
	return (template:gsub("{([%w_]+)}", function(name)
		local value = values[name]
		if value == nil then return nil end
		return tostring(value)
	end))
end

--- Returns the tools list as the prompts name it.
--- @param tools table|nil Array of tool names.
--- @return string
local function tools_text(tools)
	if type(tools) ~= "table" or #tools == 0 then return "(none)" end
	return table.concat(tools, ", ")
end

--- Returns the System 1 triage prompt.
--- @param config table Decoded agent.json.
--- @param ctx table { app, tools }
--- @return string
function M.system1_prompt(config, ctx)
	return fill(config.system1.prompt, { app = ctx.app or "", tools = tools_text(ctx.tools) })
end

--- Returns the System 2 prompt.
--- @param config table Decoded agent.json.
--- @param ctx table { source ("selection"|"command"|"typing"), app, window, now, weekday, timezone, language, tools }
--- @return string
function M.system2_prompt(config, ctx)
	local kind = config.source_kinds[ctx.source]
	if kind == nil then error("agent: unknown source " .. tostring(ctx.source), 2) end
	return fill(config.system2.prompt, {
		source_kind = kind, app = ctx.app or "", window = ctx.window or "", now = ctx.now,
		weekday = ctx.weekday, timezone = ctx.timezone, language = ctx.language,
		max_actions = config.system2.max_actions, tools = tools_text(ctx.tools),
	})
end

--- Returns the model a parsed backend setting runs: the model it names, else
--- the local default of agent.json for the local backend, else the provider's
--- default_model in api_providers.json.
--- @param parsed table|nil { backend, model } from llm.vision parse().
--- @param config table Decoded agent.json.
--- @param providers table Decoded api_providers.json.
--- @return string|nil model Nil when the setting is off, unknown or has no model.
function M.resolve_model(parsed, config, providers)
	if type(parsed) ~= "table" then return nil end
	if parsed.model then return parsed.model end
	if parsed.backend == "local" then return config.default_models["local"] end
	local provider = providers.providers[parsed.backend]
	if type(provider) ~= "table" or type(provider.default_model) ~= "string" or provider.default_model == "" then
		return nil
	end
	return provider.default_model
end

--- Returns the user turn of a System 2 request.
--- @param config table Decoded agent.json.
--- @param text string The source text.
--- @return string
function M.system2_user_text(config, text)
	return config.system2.user_prefix .. text
end





-- ===============================
-- ===============================
-- ======= 2/ System 1 ===========
-- ===============================
-- ===============================

--- Reads the triage a chat model wrote.
--- @param config table Decoded agent.json.
--- @param raw string The raw answer.
--- @return table|nil triage { intent, probability }, nil when unreadable.
function M.parse_system1(config, raw)
	if type(raw) ~= "string" then return nil end
	local intent = raw:match("[Ii][Nn][Tt][Ee][Nn][Tt]%s*:%s*([%a]+)")
	local probability = tonumber(raw:match("[Pp][Rr][Oo][Bb][Aa][Bb][Ii][Ll][Ii][Tt][Yy]%s*:%s*([%d%.]+)"))
	if intent == nil or probability == nil then return nil end
	intent = intent:lower()
	local known = false
	for _, id in ipairs(config.intents) do if id == intent then known = true end end
	if not known or probability < 0 or probability > 1 then return nil end
	return { intent = intent, probability = probability }
end

--- Returns the Jev choice question of the triage, in the TypeSafe decisions
--- shape: { [id] = { type = "choice", instructions, criteria = { label = description } } }.
--- @param config table Decoded agent.json.
--- @return table questions
function M.jev_questions(config)
	local jev = config.system1.jev
	local criteria = {}
	for _, id in ipairs(config.intents) do criteria[id] = jev.criteria[id] end
	return { [jev.question_id] = { type = "choice", instructions = jev.instructions, criteria = criteria } }
end

--- Reads the triage out of the decoded answers of a Jev decision. The chosen
--- label is the answer's `choice` when present, else the most probable one
--- (ties go to the earlier intent).
--- @param config table Decoded agent.json.
--- @param answers table|nil The `answers` object of the decision.
--- @return table|nil triage { intent, probability }, nil when unreadable.
function M.parse_jev_answers(config, answers)
	local answer = type(answers) == "table" and answers[config.system1.jev.question_id] or nil
	if type(answer) ~= "table" or (answer.type ~= nil and answer.type ~= "choice") then return nil end
	local probabilities = answer.probabilities
	if type(probabilities) ~= "table" then return nil end
	local choice = answer.choice
	if choice == nil then
		local best = -1
		for _, id in ipairs(config.intents) do
			local p = probabilities[id]
			if type(p) == "number" and p > best then choice, best = id, p end
		end
	end
	local known = false
	for _, id in ipairs(config.intents) do if id == choice then known = true end end
	if not known then return nil end
	local probability = probabilities[choice]
	if type(probability) ~= "number" or probability < 0 or probability > 1 then return nil end
	return { intent = choice, probability = probability }
end

--- Reads the triage out of a decoded Jev decision response.
--- @param config table Decoded agent.json.
--- @param response table The decoded response body.
--- @return table|nil triage { intent, probability }, nil when unreadable.
function M.parse_jev(config, response)
	return M.parse_jev_answers(config, type(response) == "table" and response.answers or nil)
end

--- Reports whether a triage should wake System 2.
--- @param triage table|nil { intent, probability }
--- @param threshold number
--- @return boolean
function M.should_act(triage, threshold)
	return type(triage) == "table" and triage.intent ~= "none" and triage.probability >= threshold
end





-- =======================================
-- =======================================
-- ======= 3/ Local date and time ========
-- =======================================
-- =======================================

--- Floor division that LuaJIT (Linux) and Lua 5.4 (macOS) both evaluate.
--- @return integer
local function idiv(a, b)
	return math.floor(a / b)
end

--- Days since 1970-01-01 of a civil date (proleptic Gregorian).
--- @return integer
local function days_from_civil(y, m, d)
	y = m <= 2 and y - 1 or y
	local era = idiv(y, 400)
	local yoe = y - era * 400
	local doy = idiv(153 * (m + (m > 2 and -3 or 9)) + 2, 5) + d - 1
	local doe = yoe * 365 + idiv(yoe, 4) - idiv(yoe, 100) + doy
	return era * 146097 + doe - 719468
end

--- Civil date of a day count since 1970-01-01.
--- @return integer y, integer m, integer d
local function civil_from_days(z)
	z = z + 719468
	local era = idiv(z, 146097)
	local doe = z - era * 146097
	local yoe = idiv(doe - idiv(doe, 1460) + idiv(doe, 36524) - idiv(doe, 146096), 365)
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + idiv(yoe, 4) - idiv(yoe, 100))
	local mp = idiv(5 * doy + 2, 153)
	local d = doy - idiv(153 * mp + 2, 5) + 1
	local m = mp + (mp < 10 and 3 or -9)
	return m <= 2 and y + 1 or y, m, d
end

--- Parses a local wall-clock time "YYYY-MM-DDTHH:MM".
--- @param text string
--- @return integer|nil minutes Minutes since 1970-01-01T00:00, nil when invalid.
function M.parse_datetime(text)
	if type(text) ~= "string" then return nil end
	local y, mo, d, h, mi = text:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d)$")
	if not y then return nil end
	y, mo, d, h, mi = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi)
	if mo < 1 or mo > 12 or h > 23 or mi > 59 or d < 1 then return nil end
	local next_y, next_m = mo == 12 and y + 1 or y, mo == 12 and 1 or mo + 1
	if d > days_from_civil(next_y, next_m, 1) - days_from_civil(y, mo, 1) then return nil end
	return days_from_civil(y, mo, d) * 1440 + h * 60 + mi
end

--- Formats minutes since the epoch as "YYYY-MM-DDTHH:MM".
--- @param minutes integer
--- @return string
function M.format_datetime(minutes)
	local days, rest = idiv(minutes, 1440), minutes % 1440
	local y, m, d = civil_from_days(days)
	return string.format("%04d-%02d-%02dT%02d:%02d", y, m, d, idiv(rest, 60), rest % 60)
end





-- =====================================
-- =====================================
-- ======= 4/ System 2 actions =========
-- =====================================
-- =====================================

--- Counts the code points of a UTF-8 text without the utf8 library LuaJIT lacks.
--- @param text string
--- @return integer|nil count Nil when the text is not valid UTF-8.
local function utf8_length(text)
	local count, i, n = 0, 1, #text
	while i <= n do
		local b = text:byte(i)
		local len = b < 0x80 and 1 or (b >= 0xC2 and b <= 0xDF) and 2 or (b >= 0xE0 and b <= 0xEF) and 3
			or (b >= 0xF0 and b <= 0xF4) and 4 or nil
		if len == nil or i + len - 1 > n then return nil end
		for k = i + 1, i + len - 1 do
			local c = text:byte(k)
			if c < 0x80 or c > 0xBF then return nil end
		end
		count, i = count + 1, i + len
	end
	return count
end

--- Reports whether a value is an email address.
--- @param value any
--- @return boolean
local function is_email(value)
	return type(value) == "string" and #value <= 254
		and value:match("^[^@%s,;<>\"]+@[^@%s,;<>\"]+%.[^@%s,;<>\"]+$") ~= nil
end

--- Validates one field value against its rule.
--- @return boolean ok, any value, string|nil reason
local function check_field(name, rule, value, tools)
	if rule.type == "text" then
		if type(value) ~= "string" then return false, nil, name .. " is not text" end
		value = value:match("^%s*(.-)%s*$")
		if value == "" then return false, nil, name .. " is empty" end
		local length = utf8_length(value)
		if length == nil or length > rule.max then return false, nil, name .. " is too long" end
		return true, value
	elseif rule.type == "datetime" then
		if M.parse_datetime(value) == nil then return false, nil, name .. " is not a local time" end
		return true, value
	elseif rule.type == "emails" then
		if type(value) ~= "table" or #value > rule.max then return false, nil, name .. " is not a short list" end
		local list = {}
		for i, item in ipairs(value) do
			if not is_email(item) then return false, nil, name .. " holds a non-address" end
			list[i] = item
		end
		return true, list
	elseif rule.type == "tool" then
		if type(value) ~= "string" then return false, nil, name .. " is not text" end
		for _, tool in ipairs(tools or {}) do if tool == value then return true, value end end
		return false, nil, name .. " is not one of the user's tools"
	end
	error("agent: unknown field rule " .. tostring(rule.type))
end

--- Validates and normalizes one action a model proposed.
--- @param config table Decoded agent.json.
--- @param action table The decoded action.
--- @param opts table { tools, is_null } is_null(value) tells the decoder's JSON null.
--- @return table|nil action Normalized action, nil when refused.
--- @return string|nil reason Why it was refused.
function M.validate_action(config, action, opts)
	if type(action) ~= "table" then return nil, "not an object" end
	local schema = config.actions[action.type]
	if schema == nil then return nil, "unknown type " .. tostring(action.type) end
	local out = { type = action.type }
	for name, value in pairs(action) do
		if name ~= "type" and schema[name] == nil then return nil, "unknown field " .. tostring(name) end
	end
	for name, rule in pairs(schema) do
		local value = action[name]
		if value ~= nil and opts.is_null and opts.is_null(value) then value = nil end
		if value == nil then
			if rule.required then return nil, name .. " is missing" end
		else
			local ok, normalized, reason = check_field(name, rule, value, opts.tools)
			if not ok then return nil, reason end
			out[name] = normalized
		end
	end
	if out.type == "calendar" then
		local start = M.parse_datetime(out.start)
		if out["end"] == nil then
			out["end"] = M.format_datetime(start + config.default_duration_minutes)
		elseif M.parse_datetime(out["end"]) <= start then
			return nil, "end is not after start"
		end
	end
	return out
end

--- Reads the actions System 2 wrote.
--- @param config table Decoded agent.json.
--- @param raw string The raw answer.
--- @param decode function Decodes a JSON text; may raise.
--- @param opts table { tools, is_null }
--- @return table|nil actions Valid actions, most likely first; nil when unreadable.
--- @return table rejected Reasons for each refused action.
function M.parse_actions(config, raw, decode, opts)
	local rejected = {}
	if type(raw) ~= "string" then return nil, rejected end
	local tag = config.system2.tag
	local at = raw:upper():find(tag:upper(), 1, true)
	if not at then return nil, rejected end
	local body = raw:sub(at + #tag)
	local first, last = body:find("%["), nil
	for i = #body, 1, -1 do if body:sub(i, i) == "]" then last = i break end end
	if not first or not last or last < first then return nil, rejected end
	local ok, list = pcall(decode, body:sub(first, last))
	if not ok or type(list) ~= "table" then return nil, rejected end
	local actions = {}
	for _, item in ipairs(list) do
		local action, reason = M.validate_action(config, item, opts)
		if action then
			if #actions < config.system2.max_actions then actions[#actions + 1] = action end
		else
			rejected[#rejected + 1] = reason
		end
	end
	return actions, rejected
end

-- Longest topic, in code points, a mail label shows before an ellipsis
local LABEL_TOPIC_MAX = 60

--- Returns the locale key and arguments of an action's tooltip label.
--- @param action table A validated action.
--- @return string key, table args
function M.label(action)
	local function when(value) return (value:gsub("T", " ")) end
	if action.type == "calendar" then
		return "llm.agent.label.calendar", { action.title, when(action.start) }
	elseif action.type == "reminder" then
		if action.due then return "llm.agent.label.reminder_due", { action.title, when(action.due) } end
		return "llm.agent.label.reminder", { action.title }
	elseif action.type == "mail" then
		-- A draft without a subject is named by the start of its body
		local topic = action.subject or action.body:match("^[^\r\n]*")
		if utf8_length(topic) > LABEL_TOPIC_MAX then
			topic = topic:match("^" .. ("[%z\1-\127\194-\244][\128-\191]*"):rep(LABEL_TOPIC_MAX)) .. "…"
		end
		if action.to and #action.to > 0 then
			return "llm.agent.label.mail_to", { topic, table.concat(action.to, ", ") }
		end
		return "llm.agent.label.mail", { topic }
	end
	return "llm.agent.label.shortcut", { action.name }
end





-- ======================================
-- ======================================
-- ======= 5/ Connector payloads ========
-- ======================================
-- ======================================

--- Escapes an iCalendar TEXT value.
--- @param text string
--- @return string
local function ics_text(text)
	return (text:gsub("\\", "\\\\"):gsub(";", "\\;"):gsub(",", "\\,"):gsub("\r?\n", "\\n"))
end

--- Folds one content line at 75 octets without splitting a UTF-8 sequence.
--- @param line string
--- @return string
local function ics_fold(line)
	local parts, current = {}, ""
	for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
		local limit = #parts == 0 and 75 or 74
		if #current + #char > limit then
			parts[#parts + 1] = current
			current = ""
		end
		current = current .. char
	end
	parts[#parts + 1] = current
	return table.concat(parts, "\r\n ")
end

--- Formats a local time as an iCalendar floating DATE-TIME.
--- @param value string "YYYY-MM-DDTHH:MM"
--- @return string
local function ics_time(value)
	return value:gsub("[-:]", "") .. "00"
end

--- Builds the iCalendar file of a calendar or reminder action.
--- @param config table Decoded agent.json.
--- @param action table A validated calendar or reminder action.
--- @param uid string Unique id of the entry.
--- @param stamp string Creation time, UTC, "YYYYMMDDTHHMMSSZ".
--- @return string ics CRLF-terminated content.
function M.ics(config, action, uid, stamp)
	local lines = { "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:" .. config.ics.prodid }
	local component = action.type == "calendar" and "VEVENT" or "VTODO"
	lines[#lines + 1] = "BEGIN:" .. component
	lines[#lines + 1] = "UID:" .. uid
	lines[#lines + 1] = "DTSTAMP:" .. stamp
	if action.type == "calendar" then
		lines[#lines + 1] = "DTSTART:" .. ics_time(action.start)
		lines[#lines + 1] = "DTEND:" .. ics_time(action["end"])
	elseif action.due then
		lines[#lines + 1] = "DUE:" .. ics_time(action.due)
	end
	lines[#lines + 1] = "SUMMARY:" .. ics_text(action.title)
	if action.location then lines[#lines + 1] = "LOCATION:" .. ics_text(action.location) end
	if action.notes then lines[#lines + 1] = "DESCRIPTION:" .. ics_text(action.notes) end
	for _, address in ipairs(action.attendees or {}) do lines[#lines + 1] = "ATTENDEE:mailto:" .. address end
	lines[#lines + 1] = "END:" .. component
	lines[#lines + 1] = "END:VCALENDAR"
	for i, line in ipairs(lines) do lines[i] = ics_fold(line) end
	return table.concat(lines, "\r\n") .. "\r\n"
end

--- Percent-encodes a mailto: header value (RFC 6068): only unreserved
--- characters stay literal, and a line break is CRLF.
--- @param text string
--- @return string
local function mailto_encode(text)
	text = text:gsub("\r?\n", "\r\n")
	return (text:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

--- Builds the mailto: link of a mail action. The "@" of an address stays
--- literal, as RFC 6068 writes addr-spec; everything else is encoded.
--- @param action table A validated mail action.
--- @return string url
function M.mailto(action)
	local to = {}
	for i, address in ipairs(action.to or {}) do to[i] = (mailto_encode(address):gsub("%%40", "@")) end
	local query = {}
	if action.subject then query[#query + 1] = "subject=" .. mailto_encode(action.subject) end
	query[#query + 1] = "body=" .. mailto_encode(action.body)
	return "mailto:" .. table.concat(to, ",") .. "?" .. table.concat(query, "&")
end

--- Quotes a text as an AppleScript string literal.
--- @param text string
--- @return string
function M.applescript_string(text)
	return '"' .. text:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end





-- ==============================
-- ==============================
-- ======= 6/ Learning ==========
-- ==============================
-- ==============================

--- Moves an intent's threshold after the user accepted or dismissed a suggestion.
--- @param config table Decoded agent.json.
--- @param threshold number The current threshold.
--- @param accepted boolean
--- @return number threshold
function M.learn(config, threshold, accepted)
	local learning = config.learning
	local next_value = accepted and threshold - learning.step or threshold + learning.step
	next_value = math.floor(next_value * 1000 + 0.5) / 1000
	if next_value < learning.min_threshold then return learning.min_threshold end
	if next_value > learning.max_threshold then return learning.max_threshold end
	return next_value
end

return M
