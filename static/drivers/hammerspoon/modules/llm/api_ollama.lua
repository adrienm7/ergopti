--- modules/llm/api_ollama.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Ollama)
--- DESCRIPTION:
--- Manages communication with the local Ollama API.
--- ==============================================================================

local M = {}
local hs = hs
local Parser = require("modules.llm.parser")
local Profiles = require("modules.llm.profiles")

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end





-- =======================================
-- =======================================
-- ======= 1/ Model Heuristics ===========
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
-- ======= 2/ Core Request Engine ========
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
    if type(final_sys) == "string" and final_sys:find("PREFIX") and final_sys:find("TAIL") then
        user_prompt = string.format('PREFIX: "%s"\nTAIL: "%s"', full_text or "", tail_text or "")
    else
        local context_str = type(full_text) == "string" and full_text or ""
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

            local raw     = Parser.strip_thinking(resp.message.content)
            local results = {}

            if not is_batch then
                local pred = Parser.process_prediction(full_text, tail_text, raw)
                if pred then table.insert(results, pred) end
            else
                for _, block in ipairs(Parser.split_blocks(raw)) do
                    if #results >= num_predictions then break end
                    local pred = Parser.process_prediction(full_text, tail_text, block)
                    if pred then 
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





-- =========================================
-- =========================================
-- ======= 3/ Fetch Strategies =======
-- =========================================
-- =========================================

--- Dispatches a single API request asking for N clustered predictions.
function M.fetch_batch(full_text, tail_text, model_name, temperature,
                             max_predict, num_predictions, profile,
                             on_success, on_fail)
                             
    local effective_temp = tonumber(temperature) or 0.1
    local system_prompt  = Profiles.resolve_system_prompt(profile, num_predictions)
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
function M.fetch_parallel(full_text, tail_text, model_name, temperature,
                                max_predict, num_predictions, profile,
                                on_success, on_fail)
                                
    local system_prompt = Profiles.resolve_system_prompt(profile, 1)
    local t0            = hs.timer.secondsSinceEpoch()
    local results       = {}
    local done_count    = 0
    local finished      = false
    local base_temp     = tonumber(temperature) or 0.1

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
function M.fetch_sequential(full_text, tail_text, model_name, temperature,
                                  max_predict, num_predictions, profile,
                                  on_success, on_fail)
                                
    local system_prompt = Profiles.resolve_system_prompt(profile, 1)
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

return M
