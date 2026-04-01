--- modules/llm/api_mlx.lua

--- ==============================================================================
--- MODULE: LLM API Controller (Apple MLX)
--- DESCRIPTION:
--- Manages communication with the local MLX server via its OpenAI-compatible endpoint.
--- ==============================================================================

local M = {}
local hs = hs
local Parser = require("modules.llm.parser")
local Profiles = require("modules.llm.profiles")

local ok_kl, keylogger = pcall(require, "modules.keylogger")
if not ok_kl then keylogger = nil end

-- M.is_thinking_model is injected by init.lua

--- Asynchronously checks if the MLX server is reachable and loaded.
function M.check_availability(model_name, on_available, on_missing)
    hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(status, body)
        if status == 200 then
            if type(on_available) == "function" then pcall(on_available) end
        else
            if type(on_missing) == "function" then pcall(on_missing, false) end
        end
    end)
end

--- Builds the options payload for the OpenAI API format (MLX Server).
local function build_options(temperature, num_predict_tokens, is_batch)
    local opts = {
        temperature = tonumber(temperature) or 0.1,
        max_tokens  = tonumber(num_predict_tokens),
        stop        = { "<|eot_id|>", "<|im_end|>", "[/INST]", "PREFIX:" },
    }
    
    if not is_batch then
        table.insert(opts.stop, "\n\n")
        -- Note: max 4 stop sequences typically allowed in some OpenAI endpoints,
        -- MLX can support more, but keeping it safe.
    end
    
    return opts
end

--- Posts data to the local MLX LLM and parses the response.
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

    local opts = build_options(temperature, num_predict_tokens, is_batch)
    local payload = {
        -- Le serveur MLX identifie le modèle chargé via "default_model" si le champ est absent ;
        -- envoyer le nom Ollama (ex. "llama3.2:3b") provoque une validation HF → HTTP 404
        messages    = messages,
        stream      = false,
        temperature = opts.temperature,
        max_tokens  = opts.max_tokens,
        stop        = opts.stop
    }

    local ok, encoded = pcall(hs.json.encode, payload)
    if not ok or not encoded then if type(on_fail) == "function" then pcall(on_fail) end return end

    hs.http.asyncPost("http://127.0.0.1:8080/v1/chat/completions", encoded, { ["Content-Type"] = "application/json" },
        function(status, body, _)
            if status ~= 200 then
                print("MLX chat/completions HTTP " .. tostring(status) .. " :: " .. tostring((body or ""):sub(1, 260)))
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end
            
            local ok_dec, resp = pcall(hs.json.decode, body)
            if not ok_dec or type(resp) ~= "table" or type(resp.choices) ~= "table" or not resp.choices[1] then
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end

            local choice = resp.choices[1]
            local content = nil

            -- OpenAI-like format
            if type(choice.message) == "table" then
                if type(choice.message.content) == "string" then
                    content = choice.message.content
                elseif type(choice.message.content) == "table" then
                    local chunks = {}
                    for _, item in ipairs(choice.message.content) do
                        if type(item) == "table" and type(item.text) == "string" then
                            table.insert(chunks, item.text)
                        elseif type(item) == "string" then
                            table.insert(chunks, item)
                        end
                    end
                    if #chunks > 0 then content = table.concat(chunks, "") end
                end
            end

            -- Legacy completion fallback
            if not content and type(choice.text) == "string" then
                content = choice.text
            end

            if type(content) ~= "string" or content == "" then
                if type(on_fail) == "function" then pcall(on_fail) end
                return
            end

            local raw     = Parser.strip_thinking(content)
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

            if #results == 0 then
                if type(on_fail) == "function" then pcall(on_fail) end return
            end
            if keylogger and type(keylogger.log_llm) == "function" then pcall(keylogger.log_llm, full_text, results) end
            if type(on_success) == "function" then pcall(on_success, results) end
        end
    )
end

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
