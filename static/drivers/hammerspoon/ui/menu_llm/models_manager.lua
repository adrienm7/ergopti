-- ui/menu_llm/models_manager.lua

-- ===========================================================================
-- LLM Models Manager Sub-module.
--
-- Logic for detecting Ollama, checking system requirements (RAM & Disk),
-- parsing model metadata, and managing the full installation pipeline
-- (pulling models or installing Ollama itself).
-- ===========================================================================

local M = {}

local notifications = require("lib.notifications")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local _model_ram_cache = nil





-- ====================================
-- ====================================
-- ======= 2/ System Detection ========
-- ====================================
-- ====================================

--- Detects the absolute path to the Ollama binary on the system
--- @return string|nil The path to the binary or nil if not found
local function get_ollama_path()
    local ok, p = pcall(hs.execute, "which ollama 2>/dev/null")
    if ok and type(p) == "string" and p ~= "" then 
        return p:gsub("%s+", "") 
    end
    
    local candidates = {"/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"}
    for _, c in ipairs(candidates) do
        local attr_ok, attr = pcall(hs.fs.attributes, c)
        if attr_ok and attr then return c end
    end
    return nil
end





-- =======================================
-- =======================================
-- ======= 3/ Model Metadata Logic =======
-- =======================================
-- =======================================

--- Extracts type and parameter count from a model name or JSON definition
--- @param model_name string Name of the model
--- @param presets table The list of provider presets
--- @return table { type: string, params: number }
local function get_model_info(model_name, presets)
    local m_type = "chat"
    local p_count = 0

    if type(presets) == "table" then
        for _, group in ipairs(presets) do
            if type(group.models) == "table" then
                for _, m in ipairs(group.models) do
                    if type(m) == "table" and (m.name == model_name or m.name .. ":latest" == model_name) then
                        if m.type then m_type = m.type end
                        if type(m.params) == "string" then
                            local num = m.params:match("([%d%.]+)")
                            if num then p_count = tonumber(num) or 0 end
                        end
                        return { type = m_type, params = p_count }
                    end
                end
            end
        end
    end

    if model_name:match("%-base$") or model_name:match("coder") then
        m_type = "completion"
    end
    local num = model_name:match("([%d%.]+)b")
    if num then p_count = tonumber(num) or 0 end

    return { type = m_type, params = p_count }
end

--- Ensures the RAM requirements cache is populated from presets
--- @param presets table The list of provider presets
local function ensure_ram_cache(presets)
    if _model_ram_cache or type(presets) ~= "table" then return end
    _model_ram_cache = {}
    for _, group in ipairs(presets) do
        if type(group.models) == "table" then
            for _, m in ipairs(group.models) do
                if type(m) == "table" and type(m.name) == "string" and type(m.ram_gb) == "number" then
                    _model_ram_cache[m.name] = m.ram_gb
                    local base = m.name:match("^(.-):")
                    if base and not _model_ram_cache[base] then
                        _model_ram_cache[base] = m.ram_gb
                    end
                end
            end
        end
    end
end

--- Calculates estimated RAM required for a specific model
--- @param model_name string Name of the model
--- @param presets table The list of provider presets
--- @return number Estimated GB of RAM required
local function get_model_ram(model_name, presets)
    if type(model_name) ~= "string" then return 8 end
    
    ensure_ram_cache(presets)
    if _model_ram_cache and _model_ram_cache[model_name] then
        return _model_ram_cache[model_name]
    end
    
    local info = get_model_info(model_name, presets)
    local total_b = info.params
    if total_b == 0 then
        local name = model_name:lower()
        local experts, size = name:match("(%d+)x([%d%.]+)b")
        if experts and size then
            total_b = tonumber(experts) * tonumber(size)
        else
            total_b = 8
        end
    end
    return math.ceil(total_b * 0.7 + 2.0)
end





-- ==========================================
-- ==========================================
-- ======= 4/ Installation Pipeline =========
-- ==========================================
-- ==========================================



-- ========================================
-- ===== 4.1) Download Orchestration ======
-- ========================================

--- Pulls a model from Ollama and updates the UI progress
--- @param target_model string The model identifier
--- @param deps table Global dependencies
function M.pull_model(target_model, deps)
    local ollama_bin = get_ollama_path()
    if not ollama_bin then return end
    
    local function do_cancel()
        local t = deps.active_tasks["download"]
        if t and type(t) == "userdata" and type(t.terminate) == "function" then 
            pcall(function() t:terminate() end) 
        end
    end
    
    if download_window then pcall(download_window.show, target_model, do_cancel) end
    pcall(deps.update_icon, "📥 0%")
    pcall(deps.update_menu)

    local _bytes_done, _bytes_total = 0, 0
    
    local ok_task, task = pcall(hs.task.new,
        ollama_bin,
        function(exit_code, stdout, stderr)
            deps.active_tasks["download"] = nil
            pcall(deps.update_icon)
            pcall(deps.update_menu)
            
            if exit_code == 15 then
                pcall(notifications.notify, "🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
                if download_window then pcall(download_window.complete, false, target_model) end
                return
            end
            
            local output = (stdout or "") .. (stderr or "")
            local has_err = output:lower():find("not found") or output:lower():find("error")
            
            if exit_code == 0 and not has_err then
                deps.state.llm_model = target_model
                if deps.keymap and type(deps.keymap.set_llm_model) == "function" then 
                    pcall(deps.keymap.set_llm_model, target_model) 
                end
                pcall(deps.save_prefs)
                if download_window then pcall(download_window.complete, true, target_model) end
                pcall(notifications.notify, "🟢  MODÈLE INSTALLÉ", target_model .. " est prêt !")
                hs.timer.doAfter(2, function() pcall(hs.reload) end)
            else
                local detail = output:sub(1, 120)
                if download_window then pcall(download_window.complete, false, target_model) end
                pcall(notifications.notify, "❌ Échec téléchargement", target_model .. " : " .. detail)
            end
        end,
        function(_, stdout, stderr)
            local out = (stdout or "") .. (stderr or "")
            local percent = out:match("(%d+)%%")
            local done_s, total_s = out:match("(%d+%.?%d*%s*%a+)/(%d+%.?%d*%s*%a+)")
            
            local function parse_size(s)
                if type(s) ~= "string" then return nil end
                s = s:match("^%s*(.-)%s*$"):lower()
                local n, unit = s:match("^([%d%.]+)%s*(%a+)")
                n = tonumber(n)
                if not n then return nil end
                if unit == "gb" or unit == "g" then return n * 1e9
                elseif unit == "mb" or unit == "m" then return n * 1e6
                elseif unit == "kb" or unit == "k" then return n * 1e3 end
                return n
            end
            
            if done_s  then _bytes_done  = parse_size(done_s)  or _bytes_done  end
            if total_s then _bytes_total = parse_size(total_s) or _bytes_total end
            
            if percent then
                pcall(deps.update_icon, "📥 " .. percent .. "%")
                if download_window then
                    pcall(download_window.update, percent, _bytes_done, _bytes_total, out:match("([^\13\10]+)") or "")
                end
            end
            return true
        end,
        { "pull", target_model }
    )
    
    if ok_task and task then
        deps.active_tasks["download"] = task
        pcall(function() task:start() end)
    end
end



-- ========================================
-- ===== 4.2) System Software Check =======
-- ========================================

--- Installs the Ollama Application binary, then proceeds to pull the model
--- @param target_model string The model to pull after installation
--- @param deps table Global dependencies
function M.install_ollama_then_pull(target_model, deps)
    pcall(notifications.notify, "Étape 1/2 : Installation", "Téléchargement de l’application Ollama…")
    
    local ok, task = pcall(hs.task.new, "/bin/bash", function(code)
        deps.active_tasks["install"] = nil
        if code == 0 then
            pcall(notifications.notify, "🟢 Ollama installé", "Lancement du téléchargement du modèle…")
            M.pull_model(target_model, deps)
        else
            pcall(notifications.notify, "❌ Échec installation", "L’installation d’Ollama a échoué.")
        end
    end, { "-c", [[
        curl -L https://ollama.com/download/ollama-darwin-universal.zip -o /tmp/ollama.zip
        unzip -o /tmp/ollama.zip -d /tmp/ollama_app
        cp -R /tmp/ollama_app/Ollama.app /Applications/
    ]] })
    
    if ok and task then
        deps.active_tasks["install"] = task
        pcall(function() task:start() end)
    end
end



-- ========================================
-- ===== 4.3) Resource Verification =======
-- ========================================

--- Checks RAM and Disk space before allowing a model download
--- @param target_model string The model name
--- @param presets table Known model definitions
--- @param on_cancel function|nil Callback if user aborts or system fails
--- @param deps table Global dependencies
function M.check_system_and_install(target_model, presets, on_cancel, deps)
    local ram_req = get_model_ram(target_model, presets)
    local disk_req = math.ceil(ram_req * 0.7)
    
    local ok_mem, mem_str = pcall(hs.execute, "sysctl -n hw.memsize")
    local sys_ram_gb = math.ceil((tonumber(mem_str) or 0) / (1024^3))
    
    local ok_df, df_str = pcall(hs.execute, "df -g / | awk \"NR==2 {print $4}\"")
    local free_disk_gb = tonumber(df_str) or 0

    local warnings, is_critical = {}, false
    
    if sys_ram_gb > 0 and sys_ram_gb < ram_req then
        table.insert(warnings, string.format("⚠️ RAM : %d Go disponible (requis ~%d Go) — risque de lenteur", sys_ram_gb, ram_req))
    else
        table.insert(warnings, string.format("🟢 RAM : %d Go disponible (requis ~%d Go)", sys_ram_gb, ram_req))
    end
    
    if free_disk_gb > 0 then
        local rem = free_disk_gb - disk_req
        if rem < 2 then
            is_critical = true
            table.insert(warnings, string.format("❌ Disque : %d Go disponible (requis ~%d Go) — espace insuffisant", free_disk_gb, disk_req))
        elseif rem < 15 then
            table.insert(warnings, string.format("⚠️ Disque : %d Go disponible (requis ~%d Go) — espace limité", free_disk_gb, disk_req))
        else
            table.insert(warnings, string.format("🟢 Disque : %d Go disponible (requis ~%d Go)", free_disk_gb, disk_req))
        end
    end

    local msg = "Modèle : " .. target_model .. "\n\n" .. table.concat(warnings, "\n")
    
    hs.timer.doAfter(0.1, function()
        pcall(hs.focus)
        if is_critical then
            pcall(hs.dialog.blockAlert, "Téléchargement impossible", msg, "Fermer", nil, "critical")
            if type(on_cancel) == "function" then pcall(on_cancel) end
            return
        end
        
        local sep = string.rep("─", 25)
        local ok_c, choice = pcall(hs.dialog.blockAlert,
            "Téléchargement requis",
            sep .. "\n" .. msg .. "\n" .. sep .. "\n\nVoulez-vous lancer le téléchargement ?",
            "Télécharger", "Annuler", msg:find("⚠️") and "warning" or "informational")
            
        if ok_c and choice == "Télécharger" then
            if get_ollama_path() then 
                M.pull_model(target_model, deps)
            else 
                M.install_ollama_then_pull(target_model, deps) 
            end
        else
            if type(on_cancel) == "function" then pcall(on_cancel) end
        end
    end)
end





-- =============================
-- =============================
-- ======= 5/ Public API =======
-- =============================
-- =============================

function M.new(deps)
    local obj = {}

    local candidates = {
        hs.configdir .. "/data/llm_models.json",
        hs.configdir .. "/../hammerspoon/data/llm_models.json",
    }
    local presets = {}
    for _, path in ipairs(candidates) do
        local ok, fh = pcall(io.open, path, "r")
        if ok and fh then
            local raw = fh:read("*a")
            pcall(function() fh:close() end)
            local dec_ok, data = pcall(hs.json.decode, raw)
            if dec_ok and type(data) == "table" and type(data.providers) == "table" then 
                presets = data.providers; break 
            end
        end
    end

    function obj.get_ollama_path() return get_ollama_path() end
    function obj.get_presets() return presets end
    function obj.get_model_info(name) return get_model_info(name, presets) end
    function obj.get_model_ram(name) return get_model_ram(name, presets) end
    
    function obj.get_installed_models()
        local installed = {}
        local bin = get_ollama_path() or "/usr/local/bin/ollama"
        local ok, output = pcall(hs.execute, bin .. " list 2>/dev/null")
        if ok and type(output) == "string" then
            for line in output:gmatch("[^\r\n]+") do
                local name = line:match("^(%S+)")
                if name and name ~= "NAME" then installed[name] = true end
            end
        end
        return installed
    end

    --- Main validation entry point called by the menu UI
    --- @param target_model string The model name to check
    --- @param on_success function The callback to execute if the model is ready or already exists
    function obj.check_requirements(target_model, on_success)
        local installed = obj.get_installed_models()
        -- If already installed, proceed immediately
        if installed[target_model] or installed[target_model .. ":latest"] then
            if type(on_success) == "function" then on_success() end
        else
            -- Run the full system check and prompt for download
            M.check_system_and_install(target_model, presets, nil, deps)
        end
    end

    function obj.delete_model(model_name)
        local bin = get_ollama_path()
        if not bin then return end
        pcall(notifications.notify, "🗑️ Suppression…", model_name)
        local ok, t = pcall(hs.task.new, bin, function(code)
            if code == 0 then pcall(notifications.notify, "🗑️ Supprimé", model_name) end
            pcall(deps.update_menu)
        end, {"rm", model_name})
        if ok and t then pcall(function() t:start() end) end
    end

    return obj
end

return M
