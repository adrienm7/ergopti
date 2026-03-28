-- modules/llm.lua

-- ===========================================================================
-- LLM Prediction Engine Module.
--
-- Manages communication with the local Ollama API.
-- Uses explicit structured output (TAIL_CORRECTED / NEXT_WORDS) to reliably
-- determine deletions and insertions, paired with a Wagner-Fischer diffing
-- engine for visual precision.
-- ===========================================================================

local M = {}
local utils = require("lib.text_utils")

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end





-- =======================================
-- =======================================
-- ======= 1/ Constants & Defaults =======
-- =======================================
-- =======================================

M.DEFAULT_LLM_ENABLED         = false
M.DEFAULT_LLM_MODEL           = "llama3.1"
M.DEFAULT_LLM_DEBOUNCE        = 0.5
M.DEFAULT_LLM_NUM_PREDICTIONS = 3
M.DEFAULT_LLM_SEQUENTIAL_MODE = false





-- =======================================
-- =======================================
-- ======= 2/ Built-in Profiles ========
-- =======================================
-- =======================================

local RAW_PROMPT_SINGLE = [[{context}]]

local BASIC_PROMPT_SINGLE = [[Tu es un assistant de frappe au clavier intelligent et ultra-concis.
Voici le texte saisi : {context}

Prédis UNIQUEMENT la suite directe (1 à 5 mots).
RÈGLES ABSOLUES :
- NE RÉPÈTE JAMAIS le contexte.
- NE FAIS AUCUN COMMENTAIRE. Pas de "Voici la suite", pas de salutations.
- N’utilise AUCUN guillemet. Donne juste les mots suivants nus.]]

local ADVANCED_PROMPT_SINGLE = [[Tu es un moteur strict de correction et de complétion de texte.
RÈGLES CRITIQUES :
1. Tu reçois un PREFIX (le contexte complet) et un TAIL (les ~5 à 7 derniers mots).
2. Format : Deux lignes commençant par "TAIL_CORRECTED:" et "NEXT_WORDS:".
3. TAIL_CORRECTED : Corrige l’orthographe, la grammaire et les accents UNIQUEMENT dans le TAIL. Ne modifie pas le sens. S’il n’y a pas de faute, recopie le TAIL EXACTEMENT à l’identique sans rien changer.
4. NEXT_WORDS : Prédis 1 à 5 mots pour continuer la phrase de façon logique. Laisse vide si la phrase est terminée.

EXEMPLES :

Exemple 1 (Correction Grammaticale) :
PREFIX: "Il est aller à Paris"
TAIL: "est aller à Paris"
TAIL_CORRECTED: est allé à Paris
NEXT_WORDS: 

Exemple 2 (Correction + Prédiction) :
PREFIX: "Je vous envoit ce mail pour vous dir"
TAIL: "envoit ce mail pour vous dir"
TAIL_CORRECTED: envoie ce mail pour vous dire
NEXT_WORDS: que tout est prêt.

Exemple 3 (Aucune Correction + Courte Prédiction) :
PREFIX: "Salut, comment ça"
TAIL: "Salut, comment ça"
TAIL_CORRECTED: Salut, comment ça
NEXT_WORDS: va ?

Exemple 4 (Aucune Correction + Longue Prédiction) :
PREFIX: "Je pense qu’il est important de"
TAIL: "qu’il est important de"
TAIL_CORRECTED: qu’il est important de
NEXT_WORDS: prendre une décision rapidement.

Exemple 5 (Code) :
PREFIX: "def calculate_total(price, tax):"
TAIL: "def calculate_total(price, tax):"
TAIL_CORRECTED: def calculate_total(price, tax):
NEXT_WORDS: return price * (1 + tax)
]]

--- Generates a batch prompt for multiple predictions.
--- @param n number The number of predictions required.
--- @return string The formatted prompt string.
local function BATCH_ADVANCED_PROMPT(n)
	return ADVANCED_PROMPT_SINGLE .. "\n\n" ..
[[=========================================
RÈGLE SPÉCIALE BATCH : Tu DOIS OBLIGATOIREMENT générer EXACTEMENT ]] .. tostring(n) .. [[ suites logiques différentes.
Ne t’arrête SURTOUT PAS avant d’avoir donné les ]] .. tostring(n) .. [[ propositions.
Sépare chaque proposition par `===`.

Format strict à respecter scrupuleusement :
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prédiction 1>
===
TAIL_CORRECTED: <tail>
NEXT_WORDS: <prédiction 2>
===
(Continue ainsi jusqu’à la proposition ]] .. tostring(n) .. [[)
===]]
end

M.BUILTIN_PROFILES = {
	{
		id            = "raw",
		label         = "Raw — Aucun prompt, juste le contexte",
		batch         = false,
		system_single = RAW_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "basic",
		label         = "Basique — Prédiction simple",
		batch         = false,
		system_single = BASIC_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "advanced",
		label         = "Avancé — Correction + Prédiction",
		batch         = false,
		system_single = ADVANCED_PROMPT_SINGLE,
		system_multi  = nil,
	},
	{
		id            = "batch_advanced",
		label         = "●●●● Batch Avancé — 1 req. avancée avec {n} prédiction{s}",
		batch         = true,
		system_single = ADVANCED_PROMPT_SINGLE,
		system_multi  = BATCH_ADVANCED_PROMPT,
	},
}

M.active_profile_id = "basic"
M.user_profiles = {}

--- Combines built-in profiles and user profiles into a single table.
--- @return table An array containing all available profiles.
local function get_all_profiles()
	local all = {}
	for _, p in ipairs(M.BUILTIN_PROFILES) do table.insert(all, p) end
	if type(M.user_profiles) == "table" then
		for _, p in ipairs(M.user_profiles) do table.insert(all, p) end
	end
	return all
end

--- Retrieves the currently active profile object, falling back to basic if invalid.
--- @return table The active profile object.
function M.get_active_profile()
	local id = tostring(M.active_profile_id)
	
	-- Auto-migrate legacy profiles to maintain compatibility
	if id == "parallel" or id == "parallel_simple" then id = "basic" end
	if id == "batch" or id == "batch_simple" then id = "batch_advanced" end
	if id == "parallel_advanced" then id = "advanced" end
	if id == "base_completion" then id = "raw" end
	
	for _, p in ipairs(get_all_profiles()) do
		if type(p) == "table" and p.id == id then return p end
	end
	return M.BUILTIN_PROFILES[2]  -- Fallback: basic
end

--- Updates the active profile ID and synchronizes sequential mode settings.
--- @param id string The ID of the profile to activate.
function M.set_active_profile(id)
	if type(id) == "string" then
		M.active_profile_id = id
		local p = M.get_active_profile()
		M.DEFAULT_LLM_SEQUENTIAL_MODE = (p and not p.batch) or false
	end
end





-- =======================================
-- =======================================
-- ======= 3/ Model Heuristics ===========
-- =======================================
-- =======================================

--- Determines if a model is categorized as a "thinking" model based on its name.
--- @param name string The model name to evaluate.
--- @return boolean True if it is a thinking model, false otherwise.
local function is_thinking_model(name)
	if type(name) ~= "string" then return false end
	name = name:lower()
	if name:match("qwen3") or name:match("deepseek") or name:match("%-r1") or name:match(":r1") or name:match("think") then return true end
	return false
end
M.is_thinking_model = is_thinking_model

--- Asynchronously checks if a specific model is available in the local Ollama instance.
--- @param model_name string The name of the model to check.
--- @param on_available function Callback executed if the model is found.
--- @param on_missing function Callback executed if the model is missing or API is unreachable.
function M.check_availability(model_name, on_available, on_missing)
	if type(model_name) ~= "string" then return end
	hs.http.asyncGet("http://127.0.0.1:11434/api/tags", {}, function(status, body)
		if status ~= 200 then if type(on_missing) == "function" then pcall(on_missing, true) end return end
		local ok, tags = pcall(hs.json.decode, body)
		if ok and type(tags) == "table" and type(tags.models) == "table" then
			local found = false
			for _, m in ipairs(tags.models) do
				if type(m.name) == "string" and m.name:find(model_name, 1, true) then found = true break end
			end
			if found then if type(on_available) == "function" then pcall(on_available) end
			else if type(on_missing) == "function" then pcall(on_missing, false) end end
		else
			if type(on_missing) == "function" then pcall(on_missing, false) end
		end
	end)
end





-- =======================================
-- =======================================
-- ======= 4/ Robust Parsing Engine ======
-- =======================================
-- =======================================

--- Strips conversational filler and markdown from the model’s raw text.
--- @param text string The raw output from the LLM.
--- @return string The cleaned text.
local function clean_model_output(text)
	if type(text) ~= "string" then return "" end
	
	-- Unescape HTML entities and encoded unicode to avoid garbled text
	text = utils.unescape_text(text)
	
	-- Strip markdown to prevent hallucinated formatting
	text = text:gsub("%*%*", ""):gsub("`", ""):gsub("\"", "")
	
	-- Strip chatty intros to extract only the prediction
	text = text:gsub("^Voici la suite%s*:?%s*", "")
	text = text:gsub("^Je propose%s*:?%s*", "")
	
	-- Robust normalization for explicit tags (forces case-insensitivity manually)
	text = text:gsub("%[[Tt][Aa][Ii][Ll]_[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%]", "TAIL_CORRECTED:")
	text = text:gsub("%[[Nn][Ee][Xx][Tt]_[Ww][Oo][Rr][Dd][Ss]%]", "NEXT_WORDS:")
	text = text:gsub("[Tt][Aa][Ii][Ll]_[Cc][Oo][Rr][Rr][Ee][Cc][Tt][Ee][Dd]%s*:", "TAIL_CORRECTED:")
	text = text:gsub("[Nn][Ee][Xx][Tt]_[Ww][Oo][Rr][Dd][Ss]%s*:", "NEXT_WORDS:")
	
	return text
end

--- Splits batch output into individual prediction blocks based on separators.
--- @param raw string The concatenated batch output.
--- @return table An array of string blocks.
local function split_blocks(raw)
	local blocks = {}
	for block in (raw .. "==="):gmatch("(.-)===") do
		local clean = block:gsub("^%s+", ""):gsub("%s+$", "")
		if clean ~= "" then table.insert(blocks, clean) end
	end
	if #blocks == 0 then table.insert(blocks, raw) end
	return blocks
end

--- Removes XML-like thinking tags from the model’s response to isolate the final answer.
--- @param text string The raw response containing potential thinking blocks.
--- @return string The response without thinking tags.
local function strip_thinking(text)
	if type(text) ~= "string" then return "" end
	text = text:gsub("<think>.-</think>%s*", "")
	text = text:gsub("</think>%s*", "")
	return text
end

--- Parses explicit prompt tags to determine insertions and deletions securely.
--- @param full_text string The full user context provided to the LLM.
--- @param tail_text string The current end of the user’s input.
--- @param block string The raw block of text generated by the model.
--- @return table|nil A table containing prediction data or nil if invalid.
local function process_prediction(full_text, tail_text, block)
	block = clean_model_output(block)
	
	local is_advanced = block:find("TAIL_CORRECTED") or block:find("NEXT_WORDS")
	
	if is_advanced then
		-- Surgical extraction
		local tc = block:match("TAIL_CORRECTED%s*:%s*(.-)[\r\n]+") or block:match("TAIL_CORRECTED%s*:%s*(.-)$") or ""
		local nw = block:match("NEXT_WORDS%s*:%s*(.-)[\r\n]+") or block:match("NEXT_WORDS%s*:%s*(.-)$") or ""

		local function trim(s)
			return s:match("^%s*(.-)%s*$") or ""
		end

		-- Aggressive cleanup of hallucinated residual quotes and brackets
		tc = trim(tc:gsub("%s*%]$", ""):gsub('^"', ""):gsub('"$', ""))
		nw = trim(nw:gsub("%s*%]$", ""):gsub('^"', ""):gsub('"$', ""))

		-- Élimination stricte des points de suspension, espaces et ponctuations parasites aux extrémités
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")

		-- Fix lazy LLMs in batch mode that forget TAIL_CORRECTED
		if tc == "" and nw ~= "" then
			tc = trim((tail_text or ""):gsub('^"', ""):gsub('"$', ""))
		end

		if tc == "" and nw == "" then return nil end

		-- Sliding window alignment logic: We find where the LLM’s correction seamlessly aligns with the user’s full context
		local normalized_full = (full_text or ""):gsub("'", "’")
		local tc_norm = tc:gsub("'", "’")
		
		-- Restore trailing spaces (including unicode non-breaking spaces) entered by the user
		local tail_trailing_space = normalized_full:match("([%s\194\160\226\128\175]+)$")
		if tail_trailing_space and not tc_norm:match("[%s\194\160\226\128\175]$") then
			tc_norm = tc_norm .. tail_trailing_space
		end
		
		-- Search in the last 300 characters to ensure speed while accounting for verbose hallucinations
		local search_start = math.max(1, #normalized_full - 300)
		local best_c_len = -1
		local best_suffix = ""
		
		for i = search_start, #normalized_full do
			local b = normalized_full:byte(i)
			-- Ensure alignment search only starts on valid UTF-8 character boundaries
			if b < 0x80 or b >= 0xC0 then
				local suffix = normalized_full:sub(i)
				local c_len = utils.get_common_prefix_utf8(suffix, tc_norm)
				if c_len > best_c_len then
					best_c_len = c_len
					best_suffix = suffix
				end
			end
		end
		
		-- Fallback: If alignment failed (LLM hallucinated a completely disconnected word), default to strictly substituting the tail
		if best_c_len < 2 and #tc_norm > 5 then
			best_suffix = (tail_text or ""):gsub("'", "’")
			best_c_len = utils.get_common_prefix_utf8(best_suffix, tc_norm)
		end

		-- Smart spacing check between corrected context and prediction
		local last_char = utils.utf8_sub(tc_norm, -1)
		local first_char = utils.utf8_sub(nw, 1, 1)
		local needs_space = not (last_char:match("[%s'’%-]") or last_char == "\194\160" or last_char == "\226\128\175" or first_char:match("[%s.,;)%}%%%]]") or nw == "")
		
		local display_nw = nw
		if needs_space then 
			nw = " " .. nw 
			display_nw = " " .. display_nw
		end

		-- Critical security: cancel if AI did not copy a reasonable amount of the tail
		local tail_len = utils.utf8_len(tail_text)
		local tc_len = utils.utf8_len(tc)
		if best_c_len < tail_len * 0.4 and tc_len < tail_len * 0.4 then return nil end

		-- The exact mathematical calculation of deletes ensuring zero UI artifacts
		local deletes = utils.utf8_len(best_suffix) - best_c_len
		local to_type = utils.utf8_sub(tc_norm, best_c_len + 1) .. nw

		-- Rejet ultime : si la chaîne à taper ne contient plus rien après avoir retiré espaces et points
		if to_type:gsub("[%s%.…]", "") == "" then return nil end

		local has_corr = (deletes > 0 or utils.utf8_sub(tc_norm, best_c_len + 1) ~= "")

		-- Generates clean diff chunks for the visual interface
		local chunks = utils.diff_strings(best_suffix, tc_norm)

		return { 
			deletes = deletes, 
			to_type = to_type, 
			nw = display_nw, 
			has_corrections = has_corr, 
			chunks = chunks 
		}
		
	else
		-- Basic / Raw Mode: Grab only the first line to truncate chatty paragraphs
		local nw = block:gsub("^%s+", ""):gsub("%s+$", "")
		nw = nw:match("([^\n\r]+)") or nw
		
		-- Strip any residual tag just in case it completely failed parsing
		nw = nw:gsub("^%[?[Nn][Ee][Xx][Tt]%]?%s*:?%s*", "")
		
		-- Élimination stricte des points de suspension, espaces et ponctuations parasites aux extrémités
		nw = nw:gsub("^[%s%.…]+", ""):gsub("[%s%.…]+$", "")
		
		-- Robust overlap mitigation using word-by-word comparison for basic models
		local full_words = {}
		for w in (full_text or ""):gmatch("%S+") do table.insert(full_words, w) end
		
		local nw_words = {}
		for w in nw:gmatch("%S+") do table.insert(nw_words, w) end
		
		local start_idx = math.max(1, #full_words - 20)
		for i = start_idx, #full_words do
			local buf_suffix_count = #full_words - i + 1
			if buf_suffix_count <= #nw_words then
				local match = true
				for j = 1, buf_suffix_count do
					local bw = full_words[i + j - 1]:lower():gsub("[%p%c]", "")
					local pw = nw_words[j]:lower():gsub("[%p%c]", "")
					if bw ~= pw or bw == "" then
						match = false
						break
					end
				end
				
				if match then
					local remaining = {}
					for j = buf_suffix_count + 1, #nw_words do
						table.insert(remaining, nw_words[j])
					end
					nw = table.concat(remaining, " ")
					break
				end
			end
		end
		
		nw = nw:gsub("%s*%]$", ""):gsub("%s+$", "")
		local to_type = nw
		local deletes = 0
		
		-- Smart spacing taking UTF-8 apostrophes and raw bytes into account for basic mode
		if to_type ~= "" and tail_text ~= "" then
			local t_last = utils.utf8_sub(tail_text, -1)
			local is_space = t_last:match("[%s]") or t_last == "\194\160" or t_last == "\226\128\175"
			local is_apos  = t_last:match("['’]")
			local type_start = utils.utf8_sub(to_type, 1, 1)
			
			if not is_space and not is_apos and not type_start:match("[%s.,;?!]") then
				to_type = " " .. to_type
				nw = " " .. nw
			end
		end

		-- Rejet ultime : si la chaîne à taper ne contient plus rien après avoir retiré espaces et points
		if to_type:gsub("[%s%.…]", "") == "" then return nil end
		return { deletes = deletes, to_type = to_type, nw = nw, has_corrections = false, chunks = {} }
	end
end





-- =======================================
-- =======================================
-- ======= 5/ API Communication ==========
-- =======================================
-- =======================================

--- Builds the options payload for the Ollama API.
--- @param temperature number The creativity parameter.
--- @param num_predict_tokens number Max tokens to predict.
--- @param model_name string Name of the target model.
--- @param is_batch boolean Whether this request is a batch prompt expecting multiple outputs.
--- @return table The options configuration table.
local function build_options(temperature, num_predict_tokens, model_name, is_batch)
	local opts = {
		temperature = tonumber(temperature) or 0.1,
		num_predict = tonumber(num_predict_tokens),
		-- Enforce strict stop tokens to prevent runaway generations
		stop        = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:", "TAIL:" },
	}
	
	if not is_batch then
		table.insert(opts.stop, "\n\n")
		table.insert(opts.stop, "===")
	end
	
	if is_thinking_model(model_name) then
		opts.think           = false
		opts.thinking_budget = 0
		opts.num_predict = math.max(opts.num_predict, 400)
	end
	
	return opts
end

--- Resolves the appropriate system prompt logic based on the current profile.
--- @param profile table The active profile data.
--- @param n number The number of predictions expected.
--- @return string The resolved system prompt.
local function resolve_system_prompt(profile, n)
	if type(profile) ~= "table" then return BASIC_PROMPT_SINGLE end
	
	-- Support for custom profiles built from the Prompt Editor
	if type(profile.raw_prompt) == "string" and profile.raw_prompt ~= "" then
		return profile.raw_prompt
	end

	if n == 1 then
		return type(profile.system_single) == "string" and profile.system_single or BASIC_PROMPT_SINGLE
	else
		if type(profile.system_multi) == "function" then return profile.system_multi(n) end
		if type(profile.system_multi) == "string"   then return profile.system_multi    end
	end
	return BASIC_PROMPT_SINGLE
end

--- Posts data to the local LLM and parses the response.
--- @param model_name string The LLM model name.
--- @param system_prompt string The resolved instructions.
--- @param full_text string The complete preceding document text.
--- @param tail_text string The immediate trailing text.
--- @param temperature number Model temperature.
--- @param num_predict_tokens number Token limits.
--- @param num_predictions number Total predictions to process from batch.
--- @param is_batch boolean Flag to determine batch parsing strategy.
--- @param on_success function Callback triggering on successful parse.
--- @param on_fail function Callback triggering on failure.
local function post_and_parse(model_name, system_prompt, full_text, tail_text,
							   temperature, num_predict_tokens, num_predictions, is_batch,
							   on_success, on_fail)
	
	local messages = {}

	local final_sys = system_prompt
	if type(final_sys) == "string" then
		final_sys = final_sys:gsub("%{n%}", tostring(num_predictions))
	end

	local user_prompt = ""
	-- Surgical formatting into PREFIX and TAIL if the System Prompt mentions them
	if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
		user_prompt = string.format('PREFIX: "%s"\nTAIL: "%s"', full_text or "", tail_text or "")
	else
		-- Fix context duplication: full_text inherently contains tail_text.
		local context_str = type(full_text) == "string" and full_text or ""
		
		-- Resolve string substitutions for raw or base contexts
		if type(final_sys) == "string" and final_sys:find("{context}", 1, true) then
			final_sys = final_sys:gsub("%{context%}", function() return context_str end)
			user_prompt = final_sys
			final_sys = nil
		else
			user_prompt = context_str
		end
	end

	if final_sys and final_sys ~= "" then
		table.insert(messages, { role = "system", content = final_sys })
	end
	table.insert(messages, { role = "user", content = user_prompt })

	local payload = {
		model    = tostring(model_name),
		messages = messages,
		stream   = false,
		options  = build_options(temperature, num_predict_tokens, model_name, is_batch),
	}

	local ok, encoded = pcall(hs.json.encode, payload)
	if not ok or not encoded then if type(on_fail) == "function" then pcall(on_fail) end return end

	hs.http.asyncPost("http://127.0.0.1:11434/api/chat", encoded, { ["Content-Type"] = "application/json" },
		function(status, body, _)
			if status ~= 200 then if type(on_fail) == "function" then pcall(on_fail) end return end
			
			local ok_dec, resp = pcall(hs.json.decode, body)
			if not ok_dec or type(resp) ~= "table" or type(resp.message) ~= "table" or type(resp.message.content) ~= "string" then
				if type(on_fail) == "function" then pcall(on_fail) end
				return
			end

			local raw     = strip_thinking(resp.message.content)
			local results = {}

			if not is_batch then
				local pred = process_prediction(full_text, tail_text, raw)
				if pred then table.insert(results, pred) end
			else
				for _, block in ipairs(split_blocks(raw)) do
					if #results >= num_predictions then break end
					local pred = process_prediction(full_text, tail_text, block)
					if pred then 
						-- Déduplication à la volée pour éviter 5 propositions identiques
						local dup = false
						for _, ex in ipairs(results) do
							if ex.to_type == pred.to_type then dup = true; break end
						end
						if not dup then table.insert(results, pred) end
					end
				end
			end

			if #results == 0 then if type(on_fail) == "function" then pcall(on_fail) end return end
			if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
			if type(on_success) == "function" then pcall(on_success, results) end
		end
	)
end





-- =======================================
-- =======================================
-- ======= 6/ Fetch Strategies ===========
-- =======================================
-- =======================================

--- Dispatches a single API request asking for N clustered predictions.
--- @param full_text string Preceding text.
--- @param tail_text string Immediate preceding text.
--- @param model_name string Target LLM.
--- @param temperature number Base temperature.
--- @param max_predict number Max tokens per prediction.
--- @param num_predictions number Quantity to predict.
--- @param profile table Selected active profile.
--- @param on_success function Success callback.
--- @param on_fail function Failure callback.
local function fetch_batch(full_text, tail_text, model_name, temperature,
							 max_predict, num_predictions, profile,
							 on_success, on_fail)
							 
	local effective_temp = tonumber(temperature) or 0.1
	local system_prompt  = resolve_system_prompt(profile, num_predictions)
	-- Augmentation forte de la limite de tokens pour permettre 5 blocs entiers
	local tokens         = tonumber(max_predict) * num_predictions + 150
	local is_batch       = profile.batch

	local t0 = hs.timer.secondsSinceEpoch()
	post_and_parse(model_name, system_prompt, full_text, tail_text,
				   effective_temp, tokens, num_predictions, is_batch,
				   function(results)
					   local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
					   if type(on_success) == "function" then pcall(on_success, results, ms) end
				   end,
				   on_fail)
end

--- Dispatches multiple parallel API requests incrementing the temperature to aggregate predictions.
--- @param full_text string Preceding text.
--- @param tail_text string Immediate preceding text.
--- @param model_name string Target LLM.
--- @param temperature number Base starting temperature.
--- @param max_predict number Max tokens per prediction.
--- @param num_predictions number Total individual requests to fire.
--- @param profile table Selected active profile.
--- @param on_success function Success callback.
--- @param on_fail function Failure callback.
local function fetch_parallel(full_text, tail_text, model_name, temperature,
								max_predict, num_predictions, profile,
								on_success, on_fail)
								
	local system_prompt = resolve_system_prompt(profile, 1)
	local t0            = hs.timer.secondsSinceEpoch()
	local results       = {}
	local done_count    = 0
	local finished      = false
	local base_temp     = tonumber(temperature) or 0.1

	--- Closes the async loop once all requests return or error out.
	local function finish()
		if finished then return end
		finished = true
		if #results == 0 then if type(on_fail) == "function" then pcall(on_fail) end return end
		local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
		if type(on_success) == "function" then pcall(on_success, results, ms) end
	end

	for i = 1, num_predictions do
		post_and_parse(model_name, system_prompt, full_text, tail_text,
					   base_temp, tonumber(max_predict) + 10, 1, false,
					   function(preds)
						   if finished then return end
						   if type(preds) == "table" and type(preds[1]) == "table" then
							   -- Deduplicate answers returned by parallel requests
							   local dup = false
							   for _, ex in ipairs(results) do
								   if ex.to_type == preds[1].to_type then dup = true; break end
							   end
							   if not dup then table.insert(results, preds[1]) end
						   end
						   done_count = done_count + 1
						   if done_count >= num_predictions then finish() end
					   end,
					   function()
						   if finished then return end
						   done_count = done_count + 1
						   if done_count >= num_predictions then finish() end
					   end)
	end
end

--- Dispatches multiple sequential API requests to avoid parallel connection dropping.
--- @param full_text string Preceding text.
--- @param tail_text string Immediate preceding text.
--- @param model_name string Target LLM.
--- @param temperature number Base starting temperature.
--- @param max_predict number Max tokens per prediction.
--- @param num_predictions number Total individual requests to fire.
--- @param profile table Selected active profile.
--- @param on_success function Success callback.
--- @param on_fail function Failure callback.
local function fetch_sequential(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, profile,
                                  on_success, on_fail)
                                
    local system_prompt = resolve_system_prompt(profile, 1)
    local t0            = hs.timer.secondsSinceEpoch()
    local results       = {}
    local base_temp     = tonumber(temperature) or 0.1
    local current_req   = 1

    local function do_next()
        if current_req > num_predictions then
            if #results == 0 then if type(on_fail) == "function" then pcall(on_fail) end return end
            local ms = math.floor((hs.timer.secondsSinceEpoch() - t0) * 1000)
            if type(on_success) == "function" then pcall(on_success, results, ms) end
            return
        end

        post_and_parse(model_name, system_prompt, full_text, tail_text,
                       base_temp, tonumber(max_predict) + 10, 1, false,
                       function(preds)
                           if type(preds) == "table" and type(preds[1]) == "table" then
                               -- Deduplicate answers returned by sequential requests
                               local dup = false
                               for _, ex in ipairs(results) do
                                   if ex.to_type == preds[1].to_type then dup = true; break end
                               end
                               if not dup then table.insert(results, preds[1]) end
                           end
                           current_req = current_req + 1
                           do_next()
                       end,
                       function()
                           current_req = current_req + 1
                           do_next()
                       end)
    end

    do_next()
end





-- =======================================
-- =======================================
-- ======= 7/ Public API =================
-- =======================================
-- =======================================

--- Initiates a new LLM prediction request, selecting the optimal fetch strategy based on profile state.
--- @param full_text string The complete tracked context string.
--- @param tail_text string The most recent segment of the context.
--- @param model_name string Name of the targeted local model.
--- @param temperature number Base sampling temperature.
--- @param max_predict number Maximum allowed output tokens.
--- @param num_predictions number Request quantity for prediction arrays.
--- @param on_success function Function to execute when successfully parsed payload returns.
--- @param on_fail function Function to execute on timeout, error, or empty output.
--- @param sequential_mode boolean Flag to enforce sequential API requests instead of parallel.
--- @param force boolean If true, bypasses application exclusions.
function M.fetch_llm_prediction(full_text, tail_text, model_name, temperature,
								  max_predict, num_predictions, on_success, on_fail, sequential_mode, force)

	-- Prevent firing requests if the active application is blacklisted by user settings
	if not force then
		local ok_front, front = pcall(hs.application.frontmostApplication)
		if ok_front and front then
			local disabled = hs.settings.get("llm_disabled_apps")
			if type(disabled) == "table" then
				local bid  = type(front.bundleID) == "function" and front:bundleID() or ""
				local path = type(front.path) == "function" and front:path() or ""
				for _, app in ipairs(disabled) do
					if type(app) == "table" and ((app.bundleID and app.bundleID == bid) or (app.appPath and app.appPath == path)) then
						if type(on_fail) == "function" then pcall(on_fail) end
						return
					end
				end
			end
		end
	end

	num_predictions = math.max(1, math.floor(tonumber(num_predictions) or 1))
	local profile = M.get_active_profile()

	if type(profile) == "table" and (not profile.batch) and num_predictions > 1 then
        if sequential_mode then
            fetch_sequential(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
        else
            fetch_parallel(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
        end
	else
		fetch_batch(full_text, tail_text, model_name, temperature, max_predict, num_predictions, profile, on_success, on_fail)
	end
end

--- Validates keystroke event modifiers against an expected explicit modifier set.
--- @param eventFlags table The flags object emitted by the keystroke event.
--- @param targetMods table A list of expected modifier keys (e.g., {"cmd", "shift"}).
--- @return boolean True if the flags exactly match the target criteria, false otherwise.
function M.check_modifiers(eventFlags, targetMods)
	if type(targetMods) ~= "table" then return false end
	if #targetMods == 1 and targetMods[1] == "none" then return false end
	
	local target_map = { cmd = false, alt = false, shift = false, ctrl = false }
	for _, mod in ipairs(targetMods) do if target_map[mod] ~= nil then target_map[mod] = true end end
	
	if (eventFlags.cmd or false)   ~= target_map.cmd   then return false end
	if (eventFlags.alt or false)   ~= target_map.alt   then return false end
	if (eventFlags.shift or false) ~= target_map.shift then return false end
	if (eventFlags.ctrl or false)  ~= target_map.ctrl  then return false end
	
	return true
end

return M
