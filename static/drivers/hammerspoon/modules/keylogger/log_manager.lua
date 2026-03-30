--- modules/keylogger/log_manager.lua

--- ==============================================================================
--- MODULE: Keylogger Log Manager
--- DESCRIPTION:
--- Handles the heavy lifting of data aggregation, JSON encoding, and file rotation.
--- Compiles raw keystrokes into rich N-gram indexes and computes metrics.
---
--- FEATURES & RATIONALE:
--- 1. Math Offloading: Keeps the mathematical processing out of the fast loop.
--- 2. File Integrity: Manages temporary files and atomic moves to prevent corruption.
--- 3. Crypto Delegation: Contains all OpenSSL bash commands to isolate OS queries.
--- ==============================================================================

local hs   = hs
local fs   = require("hs.fs")
local json = require("hs.json")
local utf8 = utf8

local M = {}

local _state = nil





-- ====================================
-- ====================================
-- ======= 1/ Helper Functions ========
-- ====================================
-- ====================================

--- Removes the last UTF-8 character from a string.
--- @param input_string string The input string.
--- @return string The string without the last character.
local function pop_utf8(input_string)
    if #input_string == 0 then return input_string end
    local offset = utf8.offset(input_string, -1)
    return offset and input_string:sub(1, offset - 1) or ""
end

--- Adds a metric count to the dictionary.
--- @param dict table The target dictionary.
--- @param key string The sequence string.
--- @param delay number The delay in ms.
--- @param is_err boolean True if backspaced.
--- @param synth_type string The source generation type.
local function add_metric(dict, key, delay, is_err, synth_type)
    local item = dict[key]
    if not item then
        item = { c = 0, t = 0, hs = 0, llm = 0, o = 0, e = 0 }
        dict[key] = item
    end
    if is_err then
        item.e = item.e + 1
    else
        item.c = item.c + 1
        if synth_type == "hotstring" then item.hs = item.hs + 1
        elseif synth_type == "llm" then item.llm = item.llm + 1
        elseif synth_type ~= "none" then item.o = item.o + 1
        elseif delay > 0 then item.t = item.t + delay end
    end
end





-- ======================================
-- ======================================
-- ======= 2/ Core Aggregation ==========
-- ======================================
-- ======================================

--- Compiles raw events into aggregated dictionaries.
--- @param events table Raw key array.
--- @param app_name string Focus app.
--- @param date_str string Day identifier.
function M.aggregate_events(events, app_name, date_str)
    date_str = date_str or os.date("%Y-%m-%d")
    
    local a = _state.today_idx[app_name]
    if not a then
        a = { c = {}, bg = {}, tg = {}, qg = {}, pg = {}, hx = {}, hp = {}, w = {} }
        _state.today_idx[app_name] = a
    end

    local m_day = _state.manifest[date_str]
    if not m_day then m_day = {}; _state.manifest[date_str] = m_day end
    local m_app = m_day[app_name]
    if not m_app then m_app = { chars = 0, time = 0, sent = 0, sent_time = 0, sent_chars = 0 }; m_day[app_name] = m_app end

    local p1, p2, p3, p4, p5, p6 = nil, nil, nil, nil, nil, nil
    local cur_word = ""
    local word_err = false
    local hist = {}
    local MAX_DELAY = 5000

    for _, ev in ipairs(events) do
        local char = ev[1]
        local delay = ev[2]
        local meta = ev[3] or {}
        local is_bs = (char == "[BS]")
        local stype = meta.st or "none"
        local is_synth = meta.s or false

        if is_bs then
            if #hist > 0 then
                local l = table.remove(hist)
                if l.c then add_metric(a.c, l.c, 0, true) end
                if l.bg then add_metric(a.bg, l.bg, 0, true) end
                if l.tg then add_metric(a.tg, l.tg, 0, true) end
                if l.qg then add_metric(a.qg, l.qg, 0, true) end
                if l.pg then add_metric(a.pg, l.pg, 0, true) end
                if l.hx then add_metric(a.hx, l.hx, 0, true) end
                if l.hp then add_metric(a.hp, l.hp, 0, true) end
            end
            word_err = true
            cur_word = pop_utf8(cur_word)
        else
            local k_c = char
            local k_bg = p1 and (p1 .. k_c) or nil
            local k_tg = p2 and (p2 .. p1 .. k_c) or nil
            local k_qg = p3 and (p3 .. p2 .. p1 .. k_c) or nil
            local k_pg = p4 and (p4 .. p3 .. p2 .. p1 .. k_c) or nil
            local k_hx = p5 and (p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil
            local k_hp = p6 and (p6 .. p5 .. p4 .. p3 .. p2 .. p1 .. k_c) or nil

            local h_obj = {}
            if is_synth or delay < MAX_DELAY then
                add_metric(a.c, k_c, delay, false, stype); h_obj.c = k_c
                if k_bg then add_metric(a.bg, k_bg, delay, false, stype); h_obj.bg = k_bg end
                if k_tg then add_metric(a.tg, k_tg, delay, false, stype); h_obj.tg = k_tg end
                if k_qg then add_metric(a.qg, k_qg, delay, false, stype); h_obj.qg = k_qg end
                if k_pg then add_metric(a.pg, k_pg, delay, false, stype); h_obj.pg = k_pg end
                if k_hx then add_metric(a.hx, k_hx, delay, false, stype); h_obj.hx = k_hx end
                if k_hp then add_metric(a.hp, k_hp, delay, false, stype); h_obj.hp = k_hp end

                if not is_synth then
                    m_app.chars = m_app.chars + 1
                    m_app.time  = m_app.time + delay
                    m_app.sent_chars = (m_app.sent_chars or 0) + 1
                    m_app.sent_time = (m_app.sent_time or 0) + delay
                end
            end

            table.insert(hist, h_obj)
            p6 = p5; p5 = p4; p4 = p3; p3 = p2; p2 = p1; p1 = k_c
        end
    end
end





-- =====================================
-- =====================================
-- ======= 3/ File Management ==========
-- =====================================
-- =====================================

--- Compresses old log files retroactively.
function M.ensure_dir_and_rotate()
    if not fs.attributes(_state.LOG_DIR) then fs.mkdir(_state.LOG_DIR) end
    
    local today = os.date("%Y_%m_%d")
    for f in hs.fs.dir(_state.LOG_DIR) do
        if f:match("^%d%d%d%d_%d%d_%d%d%.log$") and not f:find(today) then
            local full_path = _state.LOG_DIR .. "/" .. f
            if _state.options.encrypt then
                local enc_path = full_path .. ".gz.enc"
                local safe_pwd = _state.get_mac_serial():gsub("\"", "\\\"")
                os.execute(string.format("gzip -c %q | openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" > %q && rm %q", full_path, safe_pwd, enc_path, full_path))
            else
                os.execute(string.format("gzip %q", full_path))
            end
        end
        
        if f:match("^%d%d%d%d_%d%d_%d%d%.idx$") and not f:find(today) then
            local full_path = _state.LOG_DIR .. "/" .. f
            os.execute(string.format("gzip %q", full_path))
        end
    end
end

--- Returns today's active plain log file.
--- @return string Filepath.
local function get_log_file() return _state.LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".log" end

--- Persists today's index into a dedicated file.
function M.save_today_index()
    local idx_file = _state.LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".idx"
    local ok, raw = pcall(json.encode, _state.today_idx)
    if not ok then return end

    local f = io.open(idx_file .. ".tmp", "w")
    if f then 
        f:write(raw)
        f:close() 
        os.execute(string.format("mv %q %q", idx_file .. ".tmp", idx_file))
    end
end

--- Persists the fast-load manifest.
function M.save_manifest()
    local manifest_file = _state.LOG_DIR .. "/manifest.json"
    local ok, raw = pcall(json.encode, _state.manifest)
    if not ok then return end

    local f = io.open(manifest_file .. ".tmp", "w")
    if f then 
        f:write(raw)
        f:close() 
        os.execute(string.format("mv %q %q", manifest_file .. ".tmp", manifest_file))
    end
end

--- Parses unindexed raw logs on boot to heal the state.
function M.rebuild_index_if_needed()
    local manifest_file = _state.LOG_DIR .. "/manifest.json"
    local f = io.open(manifest_file, "r")
    if f then
        local c = f:read("*a")
        f:close()
        pcall(function() _state.manifest = json.decode(c) or {} end)
    end

    local today_idx_file = _state.LOG_DIR .. "/" .. os.date("%Y_%m_%d") .. ".idx"
    local f_idx = io.open(today_idx_file, "r")
    if f_idx then
        local c = f_idx:read("*a")
        f_idx:close()
        pcall(function() _state.today_idx = json.decode(c) or {} end)
    end

    local changed = false
    
    for f_name in hs.fs.dir(_state.LOG_DIR) do
        local y, m, d = f_name:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.log")
        if not y then y, m, d = f_name:match("^(%d%d%d%d)_(%d%d)_(%d%d)%.log%.gz") end
        
        if y and m and d then
            local date_str = y .. "-" .. m .. "-" .. d
            local idx_file = string.format("%s/%s_%s_%s.idx", _state.LOG_DIR, y, m, d)
            local idx_gz_file = idx_file .. ".gz"
            
            if not fs.attributes(idx_file) and not fs.attributes(idx_gz_file) then
                local full_path = _state.LOG_DIR .. "/" .. f_name
                local content = ""
                
                if f_name:match("%.log%.gz%.enc$") then
                    local safe_pwd = _state.get_mac_serial():gsub("\"", "\\\"")
                    local p = io.popen(string.format("gzip -c -d %q | openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" 2>/dev/null", full_path, safe_pwd), "r")
                    if p then content = p:read("*a"); p:close() end
                elseif f_name:match("%.gz$") then
                    local p = io.popen(string.format("gzip -c -d %q 2>/dev/null", full_path), "r")
                    if p then content = p:read("*a"); p:close() end
                else
                    local file = io.open(full_path, "r")
                    if file then content = file:read("*a"); file:close() end
                end

                if content and content ~= "" then
                    local backup_today = _state.today_idx
                    _state.today_idx = {}
                    
                    for line in content:gmatch("[^\r\n]+") do
                        if _state.options.encrypt and not line:match("^{") then
                            local safe_line = line:gsub("\"", "\\\"")
                            local safe_pwd = _state.get_mac_serial():gsub("\"", "\\\"")
                            local dec = hs.execute(string.format("echo \"%s\" | openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" 2>/dev/null", safe_line, safe_pwd))
                            if dec and dec:match("^{") then line = dec end
                        end

                        if line:match("^{") then
                            local ok, entry = pcall(json.decode, line)
                            if ok and entry and entry.type == "typing" and entry.events then
                                M.aggregate_events(entry.events, entry.app or "Unknown", date_str)
                                changed = true
                            end
                        end
                    end
                    
                    if date_str ~= os.date("%Y-%m-%d") then
                        local tmp = idx_file .. ".tmp"
                        local tmp_f = io.open(tmp, "w")
                        if tmp_f then
                            tmp_f:write(json.encode(_state.today_idx))
                            tmp_f:close()
                            os.execute(string.format("gzip -c %q > %q && rm %q", tmp, idx_gz_file, tmp))
                        end
                    else
                        M.save_today_index()
                        backup_today = _state.today_idx
                    end
                    
                    _state.today_idx = backup_today
                end
            end
        end
    end
    
    if changed then M.save_manifest() end
end

--- Atomic log appender.
--- @param entry table Dictionary payload.
function M.append_log(entry)
    local filepath = get_log_file()
    local now_ms = hs.timer.absoluteTime() / 1000000
    local ms_part = math.floor(now_ms) % 1000
    entry.timestamp = string.format("%s.%03d", os.date("%Y-%m-%d %H:%M:%S"), ms_part)
    
    local ok, str = pcall(json.encode, entry)
    if not ok then return end
    str = str:gsub("\n", "")
    
    local tmp = filepath .. ".tmp." .. hs.timer.absoluteTime()
    local f = io.open(tmp, "w")
    if f then
        f:write(str .. "\n")
        f:close()
        os.execute(string.format("cat %q >> %q; rm %q", tmp, filepath, tmp))
    end
end

--- Writes buffer to disk and resets memory strings.
function M.flush_buffer()
    if #_state.buffer_events == 0 then return end
    
    local total_time_ms, total_chars = 0, 0
    for _, ev in ipairs(_state.buffer_events) do
        local meta = ev[3] or {}
        if not meta.s then
            local d = ev[2] or 0
            if d > 5000 then d = 5000 end
            total_time_ms = total_time_ms + d
            total_chars = total_chars + 1
        end
    end
    local wpm = total_time_ms > 0 and ((total_chars / 5) / (total_time_ms / 60000)) or 0

    local rich_str, cur_type, cur_text = "", nil, ""
    for _, chunk in ipairs(_state.rich_chunks) do
        if chunk.type == cur_type then cur_text = cur_text .. chunk.text
        else
            if cur_type then
                if cur_type == "text" then rich_str = rich_str .. cur_text
                elseif cur_type == "correction" then rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
                else rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>" end
            end
            cur_type = chunk.type; cur_text = chunk.text
        end
    end
    if cur_type then
        if cur_type == "text" then rich_str = rich_str .. cur_text
        elseif cur_type == "correction" then rich_str = rich_str .. "<correction><del>" .. cur_text .. "</del></correction>"
        else rich_str = rich_str .. "<autocomplete type=\"" .. cur_type .. "\">" .. cur_text .. "</autocomplete>" end
    end

    M.append_log({ 
        type = "typing", text = _state.buffer_text, rich_text = rich_str, 
        app = _state.session_app_name, title = _state.session_win_title, url = _state.session_url,
        field_role = _state.session_field_role, layout = _state.session_layout,
        pause_before_ms = _state.current_session_pause,
        wpm = tonumber(string.format("%.1f", wpm)), events = _state.buffer_events 
    })

    M.aggregate_events(_state.buffer_events, _state.session_app_name, os.date("%Y-%m-%d"))
    M.save_today_index()
    M.save_manifest()
    
    _state.buffer_events = {}
    _state.buffer_text = ""
    _state.rich_chunks = {}
    _state.last_time = 0
    _state.pending_keyup = {}
    _state.last_flush_time = hs.timer.absoluteTime() / 1000000
end





-- =====================================
-- =====================================
-- ======= 4/ OS Crypto Helpers ========
-- =====================================
-- =====================================

--- Exposes a helper to the UI to execute LaunchServices registration.
function M.register_encryptor_app()
    local app_path = hs.configdir .. "/utils/encryptor/Encryptor.app"
    if fs.attributes(app_path) then
        local lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        hs.execute(string.format("%s -f %q", lsregister, app_path))
    end
end

--- Retrieves a unique device serial key safely.
--- @return string The MAC serial or fallback identifier.
function M.get_mac_serial()
    return _state.get_mac_serial()
end

--- Processes file encryption asynchronously with UI feedback hooks.
--- @param files_to_process table Files list.
--- @param is_encrypt boolean Operation type.
--- @param password string Secret.
--- @param on_progress function Callback triggered per file.
--- @param on_complete function Callback triggered at end.
function M.process_files_async(files_to_process, is_encrypt, password, on_progress, on_complete)
    local total_files = #files_to_process
    local current_index = 0
    local success_count = 0
    local error_count = 0
    local has_bad_password = false

    local function process_next()
        if current_index >= total_files then
            if type(on_complete) == "function" then
                on_complete(success_count, error_count, has_bad_password)
            end
            return
        end

        current_index = current_index + 1
        local target_file = files_to_process[current_index]
        local safe_password = password:gsub("\"", "\\\"")

        if is_encrypt then
            local output_file = target_file .. ".enc"
            local shell_cmd = string.format("openssl enc -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>&1", safe_password, target_file, output_file)
            local output, status = hs.execute(shell_cmd)
            
            if status then
                os.remove(target_file)
                success_count = success_count + 1
            else
                os.remove(output_file)
                error_count = error_count + 1
            end
        else
            local output_file = target_file:gsub("%.enc$", "")
            local shell_cmd = string.format("openssl enc -d -aes-256-cbc -a -A -salt -pbkdf2 -pass pass:\"%s\" -in %q > %q 2>&1", safe_password, target_file, output_file)
            local output, status = hs.execute(shell_cmd)
            
            if status then
                os.remove(target_file)
                success_count = success_count + 1
            else
                os.remove(output_file)
                error_count = error_count + 1
                if output and output:match("bad decrypt") then
                    has_bad_password = true
                end
            end
        end

        if type(on_progress) == "function" then
            on_progress(current_index)
        end
        
        hs.timer.doAfter(0.01, process_next)
    end

    hs.timer.doAfter(0.05, process_next)
end





-- =============================
-- =============================
-- ======= 5/ Module API =======
-- =============================
-- =============================

--- Mounts the shared state.
--- @param core_state table The shared state object.
function M.init(core_state)
    _state = core_state
end

return M
