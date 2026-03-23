-- ui/menu_llm.lua
local M = {}

local llm_mod = require("modules.llm")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

local NBSP = "\194\160"

local DEFAULT_LLM_CONTEXT_LENGTH  = 500
local DEFAULT_LLM_TEMPERATURE     = 0.1
local DEFAULT_LLM_MAX_PREDICT     = 40
local DEFAULT_LLM_NUM_PREDICTIONS = llm_mod.DEFAULT_LLM_NUM_PREDICTIONS or 3

local ARROW_MOD_OPTIONS = {
    { label = "Aucun (flèches seules)", mods = {},
      warn = "⚠️ Conflits avec la navigation clavier (uniquement quand l'IA est visible)" },
    { label = "Option ⌥",   mods = {"alt"},
      warn = "⚠️ Conflit avec Option+flèche (uniquement quand l'IA est visible)" },
    { label = "Shift ⇧",    mods = {"shift"},
      warn = "⚠️ Conflit avec Shift+flèche (uniquement quand l'IA est visible)" },
    { label = "Commande ⌘", mods = {"cmd"},
      warn = "⚠️ Conflit avec ⌘+flèche (uniquement quand l'IA est visible)" },
    { label = "Shift ⇧ + Commande ⌘", mods = {"shift","cmd"}, warn = "" },
    { label = "Ctrl ⌃",               mods = {"ctrl"},         warn = "" },
}

local function mods_to_key(mods)
    local s = {}; for _, m in ipairs(mods or {}) do s[#s+1] = m end
    table.sort(s); return table.concat(s, "+")
end
local function mods_label(mods)
    local k = mods_to_key(mods)
    if k == "" then return "Aucun (flèches seules)" end
    for _, opt in ipairs(ARROW_MOD_OPTIONS) do
        if mods_to_key(opt.mods) == k then return opt.label end
    end
    return k
end

-- ─────────────────────────────────────────────────────────
-- 1. FACTORY
-- ─────────────────────────────────────────────────────────
function M.create(deps)
    assert(type(deps)              == "table")
    assert(type(deps.state)        == "table")
    assert(type(deps.active_tasks) == "table")
    assert(type(deps.update_icon)  == "function")
    assert(type(deps.update_menu)  == "function")
    assert(type(deps.save_prefs)   == "function")

    local state          = deps.state
    local active_tasks   = deps.active_tasks
    local update_icon    = deps.update_icon
    local update_menu    = deps.update_menu
    local save_prefs     = deps.save_prefs
    local keymap         = deps.keymap
    local script_control = deps.script_control

    local function disable_llm()
        state.llm_enabled = false
        if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
        save_prefs(); update_menu()
    end

    local function notify(title, body)
        pcall(function()
            hs.notify.new({ title = title, informativeText = body or "" }):send()
        end)
    end

-- ─────────────────────────────────────────────────────────
-- 2. SYSTEM DETECTION
-- ─────────────────────────────────────────────────────────
    local function get_ollama_path()
        local p = hs.execute("which ollama 2>/dev/null")
        if p and p ~= "" then return p:gsub("%s+", "") end
        for _, c in ipairs({ "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama" }) do
            if hs.fs.attributes(c) then return c end
        end
        return nil
    end

-- ─────────────────────────────────────────────────────────
-- 3. MODEL REQUIREMENTS
-- ─────────────────────────────────────────────────────────
    -- Cache JSON → ram_gb par nom de modèle (construit paresseusement)
    local _model_ram_cache = nil   -- nil = pas encore construit
    local function ensure_ram_cache()
        if _model_ram_cache then return end
        _model_ram_cache = {}
        for _, group in ipairs(PRESET_GROUPS or {}) do
            for _, m in ipairs(group.models or {}) do
                if m.name and m.ram_gb then
                    _model_ram_cache[m.name] = m.ram_gb
                    local base = m.name:match("^(.-):")
                    if base and not _model_ram_cache[base] then
                        _model_ram_cache[base] = m.ram_gb
                    end
                end
            end
        end
    end

    local function get_model_ram(model_name)
        ensure_ram_cache()
        if _model_ram_cache[model_name] then return _model_ram_cache[model_name] end
        local name = model_name:lower()
        local total_b = 0
        local experts, size = name:match("(%d+)x([%d%.]+)b")
        if experts and size then
            total_b = tonumber(experts) * tonumber(size)
        else
            local b = name:match("([%d%.]+)b")
            if b then total_b = tonumber(b) end
        end
        if total_b == 0 then
            local defaults = {
                codestral=22, ["command.r"]=35, deepseek=7, gemma2=9, gemma3=4,
                glm4=9, granite=8, internlm=7, ["llama3%.2"]=3, llama3=8,
                mistral=7, mixtral=47, nemotron=4, phi3=4, phi4=14,
                ["qwen3%.5"]=8, qwen3=8, qwen=7, smollm=1.7, solar=10.7, yi=6,
            }
            for pattern, sz in pairs(defaults) do
                if name:find(pattern) then total_b = sz; break end
            end
            if total_b == 0 then total_b = 8 end
        end
        return math.ceil(total_b * 0.7 + 2.0)
    end

    local function get_model_requirements(model_name)
        local ram = get_model_ram(model_name)
        return math.ceil(ram * 0.7), ram
    end

-- ─────────────────────────────────────────────────────────
-- 4. INSTALLATION PIPELINE
-- ─────────────────────────────────────────────────────────
    local function make_progress_bar(pct)
        local p = math.max(0, math.min(100, tonumber(pct) or 0))
        return string.rep("\226\150\160", math.floor(p/10))
            .. string.rep("\226\150\161", 10 - math.floor(p/10))
    end

    local _menu_update_timer = nil
    local function schedule_menu_update()
        if _menu_update_timer then _menu_update_timer:stop() end
        _menu_update_timer = hs.timer.doAfter(0.5, function()
            _menu_update_timer = nil
            update_menu()
        end)
    end

    local function pull_model(target_model)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then
            notify("❌ Ollama introuvable", "Installez Ollama depuis ollama.com.")
            return
        end

        local function do_cancel()
            local t = active_tasks["download"]
            if t and type(t) == "userdata" and t.terminate then t:terminate() end
        end
        if download_window then
            download_window.show(target_model, do_cancel)
        end
        update_icon("📥 0%")
        update_menu()

        local _bytes_done  = 0
        local _bytes_total = 0

        local task_id = "download"
        local task = hs.task.new(
            ollama_bin,
            function(exit_code, stdout, stderr)
                active_tasks[task_id] = nil
                update_icon()
                update_menu()

                if exit_code == 15 then
                    notify("🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
                    if download_window then download_window.complete(false, target_model) end
                    return
                end
                local output    = (stdout or "") .. (stderr or "")
                local has_error = output:lower():find("not found") or output:lower():find("error")
                if exit_code == 0 and not has_error then
                    state.llm_model = target_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(target_model) end
                    save_prefs()
                    if download_window then download_window.complete(true, target_model) end
                    notify("🟢  MODÈLE INSTALLÉ", target_model .. " est prêt à l'emploi !")
                    hs.timer.doAfter(2, hs.reload)
                else
                    local detail = output:sub(1, 120)
                    if download_window then download_window.complete(false, target_model) end
                    notify("❌ Échec téléchargement", target_model .. " : " .. detail)
                    hs.timer.doAfter(0.3, function()
                        hs.focus()
                        hs.dialog.blockAlert("Échec du téléchargement",
                            "Modèle : " .. target_model .. "\n\nDétails :\n" .. detail,
                            "OK", nil, "critical")
                    end)
                end
            end,
            function(_, stdout, stderr)
                local out = (stdout or "") .. (stderr or "")

                local percent = out:match("(%d+)%%")
                local done_s, total_s = out:match("(%d+%.?%d*%s*%a+)/(%d+%.?%d*%s*%a+)")

                local function parse_size(s)
                    if not s then return nil end
                    s = s:match("^%s*(.-)%s*$"):lower()
                    local n, unit = s:match("^([%d%.]+)%s*(%a+)")
                    n = tonumber(n)
                    if not n then return nil end
                    if unit == "gb" or unit == "g" then return n * 1e9 end
                    if unit == "mb" or unit == "m" then return n * 1e6 end
                    if unit == "kb" or unit == "k" then return n * 1e3 end
                    return n
                end

                if done_s  then _bytes_done  = parse_size(done_s)  or _bytes_done  end
                if total_s then _bytes_total = parse_size(total_s) or _bytes_total end

                if percent then
                    update_icon("📥 " .. percent .. "%")
                    if download_window then
                        download_window.update(percent, _bytes_done, _bytes_total, out:match("([^\13\10]+)") or "")
                    end
                elseif out:lower():find("pulling") or out:lower():find("downloading") then
                    update_icon("📥 Récupération…")
                    if download_window then download_window.update(0, 0, 0, out:match("([^\13\10]+)") or "") end
                elseif out:lower():find("verif") then
                    update_icon("📥 Vérification…")
                    if download_window then download_window.update(99, _bytes_done, _bytes_total, "Vérification…") end
                end
                return true
            end,
            { "pull", target_model }
        )
        active_tasks[task_id] = task
        task:start()
    end

    local function install_ollama_then_pull(target_model)
        notify("Étape 1/2 : Installation", "Téléchargement de l'application Ollama…")
        local task_id = "install"
        local task = hs.task.new("/bin/bash", function(code)
            active_tasks[task_id] = nil
            if code == 0 then
                notify("🟢 Ollama installé", "Lancement du téléchargement du modèle…")
                pull_model(target_model)
            else
                notify("❌ Échec installation", "L'installation d'Ollama a échoué.")
            end
        end, { "-c", [[
            curl -L https://ollama.com/download/ollama-darwin-universal.zip -o /tmp/ollama.zip
            unzip -o /tmp/ollama.zip -d /tmp/ollama_app
            cp -R /tmp/ollama_app/Ollama.app /Applications/
        ]] })
        active_tasks[task_id] = task
        task:start()
    end

-- ─────────────────────────────────────────────────────────
-- 5. SYSTEM CHECKS
-- ─────────────────────────────────────────────────────────
    local function check_system_and_install(target_model, on_cancel)
        local req_disk, req_ram = get_model_requirements(target_model)
        local sys_ram_gb   = math.ceil(
            (tonumber((hs.execute("sysctl -n hw.memsize"))) or 0) / (1024^3))
        local free_disk_gb = tonumber((hs.execute("df -g / | awk 'NR==2 {print $4}'"))) or 0

        local warnings    = {}
        local is_critical = false

        if sys_ram_gb > 0 and sys_ram_gb < req_ram then
            table.insert(warnings, string.format(
                "⚠️ RAM : %d Go disponible (requis ~%d Go) — risque de lenteur", sys_ram_gb, req_ram))
        else
            table.insert(warnings, string.format(
                "🟢 RAM : %d Go disponible (requis ~%d Go)", sys_ram_gb, req_ram))
        end
        if free_disk_gb > 0 then
            local rem = free_disk_gb - req_disk
            if rem < 2 then
                is_critical = true
                table.insert(warnings, string.format(
                    "❌ Disque : %d Go disponible (requis ~%d Go) — espace insuffisant", free_disk_gb, req_disk))
            elseif rem < 15 then
                table.insert(warnings, string.format(
                    "⚠️ Disque : %d Go disponible (requis ~%d Go) — espace limité", free_disk_gb, req_disk))
            else
                table.insert(warnings, string.format(
                    "🟢 Disque : %d Go disponible (requis ~%d Go)", free_disk_gb, req_disk))
            end
        end

        local msg = "Modèle : " .. target_model .. "\n\n" .. table.concat(warnings, "\n")

        hs.timer.doAfter(0.1, function()
            hs.focus()
            if is_critical then
                hs.dialog.blockAlert("Téléchargement impossible", msg, "Fermer", nil, "critical")
                if on_cancel then on_cancel() end; return
            end
            local sep = string.rep("─", 40)
            local choice = hs.dialog.blockAlert(
                "Téléchargement requis",
                sep .. "\n" .. msg
                .. "\n" .. sep
                .. "\n\nCe modèle n'est pas encore installé."
                .. "\nVoulez-vous lancer le téléchargement ?"
                .. "\nLa progression sera visible dans une fenêtre dédiée.",
                "Télécharger", "Annuler",
                msg:find("⚠️") and "warning" or "informational"
            )
            if choice == "Télécharger" then
                if get_ollama_path() then pull_model(target_model)
                else install_ollama_then_pull(target_model) end
            else
                if on_cancel then on_cancel() end
            end
        end)
    end

-- ─────────────────────────────────────────────────────────
-- 6. INSTALLED MODELS
-- ─────────────────────────────────────────────────────────
    local function get_installed_models()
        local installed  = {}
        local ollama_bin = get_ollama_path() or "/usr/local/bin/ollama"
        local output     = hs.execute(ollama_bin .. " list 2>/dev/null")
        if output then
            for line in output:gmatch("[^\r\n]+") do
                local name = line:match("^(%S+)")
                if name and name ~= "NAME" then
                    installed[name] = true
                    if name:match(":latest$") then
                        installed[name:gsub(":latest$", "")] = true
                    end
                end
            end
        end
        return installed
    end

    local function delete_model(model_name)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then notify("❌ Ollama introuvable", ""); return end
        notify("🗑️ Suppression…", model_name)
        local t = hs.task.new(ollama_bin, function(code, out, err)
            if code == 0 then
                notify("🗑️ Supprimé", model_name .. " retiré du cache.")
            else
                notify("❌ Échec suppression", (err or out or ""):sub(1, 80))
            end
            update_menu()
        end, { "rm", model_name })
        t:start()
    end

-- ─────────────────────────────────────────────────────────
-- 7. MENU BUILDER
-- ─────────────────────────────────────────────────────────
    local PRESET_GROUPS = (function()
        local candidates = {
            hs.configdir .. "/data/llm_models.json",
            hs.configdir .. "/../hammerspoon/data/llm_models.json",
        }
        local json_data = nil
        for _, path in ipairs(candidates) do
            local fh = io.open(path, "r")
            if fh then
                local raw = fh:read("*a"); fh:close()
                local ok, data = pcall(hs.json.decode, raw)
                if ok and data and data.providers then json_data = data; break end
            end
        end
        if not json_data then
            return {
                { label = "Meta (Llama)", models = {
                    { name = "llama3.2:1b" }, { name = "llama3.2" }, { name = "llama3.1" }
                }},
                { label = "Mistral AI", models = {
                    { name = "mistral" }
                }},
            }
        end
        return json_data.providers
    end)()

    local function build_item()
        local paused      = script_control and script_control.is_paused() or false
        local debounce_ms = math.floor(state.llm_debounce * 1000 + 0.5)
        local default_debounce_ms = math.floor((llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5) * 1000 + 0.5)
        local installed     = get_installed_models()
        local num_pred      = math.max(1, math.floor(tonumber(state.llm_num_predictions)
                                                      or DEFAULT_LLM_NUM_PREDICTIONS))
        local arrow_enabled = state.llm_arrow_nav_enabled or false
        local arrow_mods    = state.llm_arrow_nav_mods or {}
        local show_model    = state.llm_show_model_name or false
        local user_models   = state.llm_user_models or {}
        local is_downloading = (active_tasks["download"] ~= nil)

        local function cancel_download()
            local t = active_tasks["download"]
            if t and type(t) == "userdata" and t.terminate then t:terminate() end
        end

        local function switch_model(new_model)
            if not get_ollama_path() then
                notify("❌ Ollama introuvable", "Installez Ollama depuis ollama.com.")
                return
            end
            notify("⏳ Vérification…", new_model)
            llm_mod.check_availability(new_model,
                function()
                    state.llm_model = new_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(new_model) end
                    save_prefs(); update_menu()
                    notify("🟢  MODÈLE ACTIF", new_model)
                end,
                function(needs_ollama)
                    hs.timer.doAfter(0.1, function()
                        hs.focus()
                        if needs_ollama then
                            local c = hs.dialog.blockAlert("Ollama non disponible",
                                "Ollama n'est pas lancé ou installé.\nInstaller maintenant ?",
                                "Installer", "Annuler", "informational")
                            if c == "Installer" then install_ollama_then_pull(new_model) end
                        else
                            check_system_and_install(new_model)
                        end
                    end)
                end
            )
        end

        local function model_item(m)
            local m_name = type(m) == "table" and m.name or m
            local ram  = (type(m) == "table" and m.ram_gb) and math.ceil(m.ram_gb) or get_model_ram(m_name)
            local is_inst = installed[m_name] or installed[m_name .. ":latest"]
            local tag_str = ""
            if type(m) == "table" and m.tags and #m.tags > 0 then
                local tag_parts = {}
                for _, t in ipairs(m.tags) do
                    if t == "best" then table.insert(tag_parts, "⭐")
                    elseif t == "reasoning" or t == "math" then table.insert(tag_parts, "🧠")
                    elseif t == "code" or t == "completion" then table.insert(tag_parts, "💻")
                    elseif t == "fast" or t == "tiny" or t == "ultra-tiny" or t == "edge" then table.insert(tag_parts, "⚡")
                    elseif t == "multilingual" or t == "chinese" or t == "korean" then table.insert(tag_parts, "🌐")
                    elseif t == "multimodal" then table.insert(tag_parts, "🖼️")
                    elseif t == "high-quality" or t == "quality" then table.insert(tag_parts, "🏆")
                    end
                end
                local seen = {}; local uniq = {}
                for _, t in ipairs(tag_parts) do
                    if not seen[t] then seen[t]=true; table.insert(uniq, t) end
                end
                if #uniq > 0 then tag_str = " " .. table.concat(uniq, "") end
            end
            local params_str = (type(m) == "table" and m.params) and (" · " .. m.params) or ""
            local title = string.format("%s%s (~%d Go RAM%s)%s",
                is_inst and "🟢 " or "  ", m_name, ram, params_str, tag_str)
            if is_inst then
                return {
                    title   = title,
                    checked = (state.llm_model == m_name),
                    menu    = {
                        {
                            title = "Utiliser ce modèle",
                            fn    = not paused and function() switch_model(m_name) end or nil,
                        },
                        { title = "-" },
                        {
                            title = "🗑️ Supprimer du cache…",
                            fn    = function()
                                hs.focus()
                                local c = hs.dialog.blockAlert(
                                    "Supprimer " .. m_name .. " ?",
                                    "Le modèle sera supprimé du disque.\nIl faudra le re-télécharger pour l'utiliser.",
                                    "Supprimer", "Annuler", "critical")
                                if c == "Supprimer" then delete_model(m_name) end
                            end,
                        },
                    },
                }
            else
                return {
                    title   = title,
                    checked = (state.llm_model == m_name),
                    fn      = not paused and function() switch_model(m_name) end or nil,
                }
            end
        end

        local models_menu = {}
        for _, group in ipairs(PRESET_GROUPS) do
            local sub = {}
            for _, m in ipairs(group.models or {}) do
                table.insert(sub, model_item(m))
            end
            if #sub > 0 then
                table.insert(models_menu, {
                    title = group.label or group.id or "?",
                    menu  = sub,
                })
            end
        end

        table.insert(models_menu, { title = "-" })
        local user_sub = {}

        table.insert(user_sub, {
            title = "+ Ajouter un modèle personnalisé…",
            fn    = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt(
                    "Ajouter un modèle",
                    "Nom exact du modèle Ollama (ex : llama3.2:latest) :",
                    "", "Ajouter", "Annuler"
                )
                if btn ~= "Ajouter" or not raw or raw:match("^%s*$") then return end
                local name = raw:match("^%s*(.-)%s*$")
                for _, e in ipairs(state.llm_user_models or {}) do
                    if e == name then notify("ℹ️ Déjà présent", name); return end
                end
                state.llm_user_models = state.llm_user_models or {}
                table.insert(state.llm_user_models, name)
                save_prefs(); update_menu()
            end or nil,
        })

        if #user_models > 0 then
            table.insert(user_sub, { title = "-" })
            for idx, m in ipairs(user_models) do
                local it = model_item(m)
                if it.menu then
                    table.insert(it.menu, { title = "-" })
                    table.insert(it.menu, {
                        title = "✂️ Retirer de mes modèles",
                        fn    = function()
                            table.remove(state.llm_user_models, idx)
                            if state.llm_model == m then
                                state.llm_model = llm_mod.DEFAULT_LLM_MODEL or "llama3.1"
                                if keymap and keymap.set_llm_model then
                                    keymap.set_llm_model(state.llm_model)
                                end
                            end
                            save_prefs(); update_menu()
                        end,
                    })
                else
                    it.menu = {
                        { title = "Utiliser ce modèle",
                          fn = not paused and function() switch_model(m) end or nil },
                        { title = "-" },
                        { title = "✂️ Retirer de mes modèles",
                          fn = function()
                            table.remove(state.llm_user_models, idx)
                            if state.llm_model == m then
                                state.llm_model = llm_mod.DEFAULT_LLM_MODEL or "llama3.1"
                                if keymap and keymap.set_llm_model then keymap.set_llm_model(state.llm_model) end
                            end
                            save_prefs(); update_menu()
                          end },
                    }
                    it.fn = nil
                end
                table.insert(user_sub, it)
            end
        end

        table.insert(models_menu, {
            title = "Autres modèles" .. (#user_models > 0 and (" (" .. #user_models .. ")") or ""),
            menu  = user_sub,
        })

        local pred_label = num_pred .. " suggestion" .. (num_pred > 1 and "s" or "")
        local num_pred_menu = {}
        for n = 1, 11 do
            table.insert(num_pred_menu, {
                title   = n .. " suggestion" .. (n > 1 and "s" or ""),
                checked = (n == num_pred) or nil,
                fn      = not paused and (function(chosen) return function()
                    state.llm_num_predictions = chosen
                    if keymap and keymap.set_llm_num_predictions then
                        keymap.set_llm_num_predictions(chosen)
                    end
                    save_prefs(); update_menu()
                end end)(n) or nil,
            })
        end
        table.insert(num_pred_menu, { title = "-" })
        table.insert(num_pred_menu, {
            title    = "   ↩ Réinitialiser (défaut : " .. DEFAULT_LLM_NUM_PREDICTIONS .. " suggestions)",
            disabled = (paused or num_pred == DEFAULT_LLM_NUM_PREDICTIONS) or nil,
            fn       = (not paused and num_pred ~= DEFAULT_LLM_NUM_PREDICTIONS) and function()
                state.llm_num_predictions = DEFAULT_LLM_NUM_PREDICTIONS
                if keymap and keymap.set_llm_num_predictions then
                    keymap.set_llm_num_predictions(DEFAULT_LLM_NUM_PREDICTIONS)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        local advanced_menu = {}

        table.insert(advanced_menu, {
            title    = "Afficher le nom du modèle dans la bulle",
            checked  = show_model or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_show_model_name = not show_model
                if keymap and keymap.set_llm_show_model_name then
                    keymap.set_llm_show_model_name(state.llm_show_model_name)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        do
            local cur_indent = math.max(0, math.min(5, math.floor(
                tonumber(state.llm_pred_indent) or 0)))
            local indent_sub = {}
            for n = 0, 5 do
                table.insert(indent_sub, {
                    title   = n == 0 and "0 — aucune" or (n .. " espace" .. (n > 1 and "s" or "")),
                    checked = (n == cur_indent) or nil,
                    fn      = not paused and (function(v) return function()
                        state.llm_pred_indent = v
                        if keymap and keymap.set_llm_pred_indent then
                            keymap.set_llm_pred_indent(v)
                        end
                        save_prefs(); update_menu()
                    end end)(n) or nil,
                })
            end
            table.insert(advanced_menu, {
                title    = "Indentation de la sélection : " .. cur_indent,
                disabled = paused or nil,
                menu     = indent_sub,
            })
        end

        table.insert(advanced_menu, { title = "-" })

        table.insert(advanced_menu, {
            title    = "Naviguer avec les flèches directionnelles",
            checked  = arrow_enabled or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_arrow_nav_enabled = not arrow_enabled
                if keymap and keymap.set_llm_arrow_nav_enabled then
                    keymap.set_llm_arrow_nav_enabled(state.llm_arrow_nav_enabled)
                end
                save_prefs(); update_menu()
            end or nil,
        })
        local cur_key = mods_to_key(arrow_mods)
        local mods_sub = {}
        for _, opt in ipairs(ARROW_MOD_OPTIONS) do
            local title_str = opt.label .. (opt.warn ~= "" and "  " .. opt.warn or "")
            table.insert(mods_sub, {
                title    = title_str,
                checked  = (mods_to_key(opt.mods) == cur_key) or nil,
                disabled = not arrow_enabled or paused or nil,
                fn       = (arrow_enabled and not paused) and (function(m) return function()
                    state.llm_arrow_nav_mods = m
                    if keymap and keymap.set_llm_arrow_nav_mods then
                        keymap.set_llm_arrow_nav_mods(m)
                    end
                    save_prefs(); update_menu()
                end end)(opt.mods) or nil,
            })
        end
        table.insert(advanced_menu, {
            title    = "   Modificateurs flèches : " .. mods_label(arrow_mods),
            disabled = not arrow_enabled or paused or nil,
            menu     = mods_sub,
        })

        table.insert(advanced_menu, { title = "-" })

        table.insert(advanced_menu, {
            title    = "Contexte : " .. state.llm_context_length .. " caractères",
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Contexte",
                    "Nombre de caractères gardés en mémoire :",
                    tostring(state.llm_context_length), "OK", "Annuler")
                if btn == "OK" and tonumber(raw) then
                    state.llm_context_length = tonumber(raw)
                    if keymap and keymap.set_llm_context_length then
                        keymap.set_llm_context_length(state.llm_context_length)
                    end
                    save_prefs(); update_menu()
                end
            end or nil,
        })
        table.insert(advanced_menu, {
            title    = "   ↩ Réinitialiser (défaut : " .. DEFAULT_LLM_CONTEXT_LENGTH .. ")",
            disabled = (paused or state.llm_context_length == DEFAULT_LLM_CONTEXT_LENGTH) or nil,
            fn       = (not paused and state.llm_context_length ~= DEFAULT_LLM_CONTEXT_LENGTH) and function()
                state.llm_context_length = DEFAULT_LLM_CONTEXT_LENGTH
                if keymap and keymap.set_llm_context_length then
                    keymap.set_llm_context_length(DEFAULT_LLM_CONTEXT_LENGTH)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(advanced_menu, { title = "-" })

        table.insert(advanced_menu, {
            title    = "Reset contexte sur clic/flèches",
            checked  = state.llm_reset_on_nav,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and keymap.set_llm_reset_on_nav then
                    keymap.set_llm_reset_on_nav(state.llm_reset_on_nav)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(advanced_menu, { title = "-" })

        table.insert(advanced_menu, {
            title    = "Température : " .. state.llm_temperature,
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Température",
                    "0.0 = prévisible, 1.0 = créatif :",
                    tostring(state.llm_temperature), "OK", "Annuler")
                if btn == "OK" and tonumber(raw) then
                    state.llm_temperature = tonumber(raw)
                    if keymap and keymap.set_llm_temperature then
                        keymap.set_llm_temperature(state.llm_temperature)
                    end
                    save_prefs(); update_menu()
                end
            end or nil,
        })
        table.insert(advanced_menu, {
            title    = "   ↩ Réinitialiser (défaut : " .. DEFAULT_LLM_TEMPERATURE .. ")",
            disabled = (paused or state.llm_temperature == DEFAULT_LLM_TEMPERATURE) or nil,
            fn       = (not paused and state.llm_temperature ~= DEFAULT_LLM_TEMPERATURE) and function()
                state.llm_temperature = DEFAULT_LLM_TEMPERATURE
                if keymap and keymap.set_llm_temperature then
                    keymap.set_llm_temperature(DEFAULT_LLM_TEMPERATURE)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(advanced_menu, { title = "-" })

        table.insert(advanced_menu, {
            title    = "Tokens max. par prédiction : " .. state.llm_max_predict,
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Tokens max.",
                    "Nombre maximum de tokens générés (ex : 40) :",
                    tostring(state.llm_max_predict), "OK", "Annuler")
                if btn == "OK" and tonumber(raw) then
                    state.llm_max_predict = tonumber(raw)
                    if keymap and keymap.set_llm_max_predict then
                        keymap.set_llm_max_predict(state.llm_max_predict)
                    end
                    save_prefs(); update_menu()
                end
            end or nil,
        })
        table.insert(advanced_menu, {
            title    = "   ↩ Réinitialiser (défaut : " .. DEFAULT_LLM_MAX_PREDICT .. " tokens)",
            disabled = (paused or state.llm_max_predict == DEFAULT_LLM_MAX_PREDICT) or nil,
            fn       = (not paused and state.llm_max_predict ~= DEFAULT_LLM_MAX_PREDICT) and function()
                state.llm_max_predict = DEFAULT_LLM_MAX_PREDICT
                if keymap and keymap.set_llm_max_predict then
                    keymap.set_llm_max_predict(DEFAULT_LLM_MAX_PREDICT)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        local main_menu = {}

        if is_downloading then
            table.insert(main_menu, {
                title = "🛑 Annuler le téléchargement en cours",
                fn    = cancel_download,
            })
            table.insert(main_menu, { title = "-" })
        end

        table.insert(main_menu, {
            title    = "Activer les suggestions IA (LLM)",
            checked  = (state.llm_enabled and not paused) or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                llm_mod.check_availability(state.llm_model,
                    function()
                        state.llm_enabled = not state.llm_enabled
                        if keymap and keymap.set_llm_enabled then
                            keymap.set_llm_enabled(state.llm_enabled)
                        end
                        save_prefs(); update_menu()
                        notify(state.llm_enabled and "🟢 ACTIVÉ" or "🔴 DÉSACTIVÉ",
                               "Suggestions IA")
                    end,
                    function(needs_ollama)
                        hs.timer.doAfter(0.1, function()
                            hs.focus()
                            if needs_ollama then
                                local c = hs.dialog.blockAlert("Installation requise",
                                    "Pour utiliser l'IA, installez Ollama.\nSouhaitez-vous procéder ?",
                                    "Installer", "Plus tard", "informational")
                                if c == "Installer" then
                                    check_system_and_install(state.llm_model, disable_llm)
                                else disable_llm() end
                            else
                                check_system_and_install(state.llm_model, disable_llm)
                            end
                        end)
                    end
                )
            end or nil,
        })

        table.insert(main_menu, { title = "-" })
        table.insert(main_menu, {
            title    = "Modèle : " .. state.llm_model,
            disabled = paused or nil,
            menu     = models_menu,
        })
        table.insert(main_menu, {
            title    = "Nombre de suggestions : " .. pred_label,
            disabled = paused or nil,
            menu     = num_pred_menu,
        })
        table.insert(main_menu, {
            title    = "Délai avant suggestion : " .. debounce_ms .. " ms…",
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Délai avant suggestion IA",
                    "Temps d'inactivité clavier avant déclenchement (ms).\n"
                    .. "⚠️ Court = réactif mais chauffe ; Long = préserve la batterie.\n\nDélai (ms) :",
                    tostring(debounce_ms), "OK", "Annuler")
                if btn ~= "OK" then return end
                local val = tonumber(raw)
                if not val or val < 0 or val ~= math.floor(val) then
                    hs.notify.new({ title = "Délai invalide",
                        informativeText = "Entier ≥ 0 requis." }):send(); return
                end
                state.llm_debounce = val / 1000
                if keymap and keymap.set_llm_debounce then
                    keymap.set_llm_debounce(state.llm_debounce)
                end
                save_prefs(); update_menu()
            end or nil,
        })
        table.insert(main_menu, {
            title    = "   ↩ Réinitialiser (défaut : " .. default_debounce_ms .. " ms)",
            disabled = (paused or debounce_ms == default_debounce_ms) or nil,
            fn       = (not paused and debounce_ms ~= default_debounce_ms) and function()
                state.llm_debounce = llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5
                if keymap and keymap.set_llm_debounce then
                    keymap.set_llm_debounce(state.llm_debounce)
                end
                save_prefs(); update_menu()
            end or nil,
        })
        table.insert(main_menu, { title = "-" })
        table.insert(main_menu, {
            title    = "Paramètres avancés…",
            disabled = paused or nil,
            menu     = advanced_menu,
        })

        return { title = "Intelligence Artificielle", menu = main_menu }
    end

-- ─────────────────────────────────────────────────────────
-- 8. STARTUP CHECK
-- ─────────────────────────────────────────────────────────
    local function check_startup()
        if not state.llm_enabled then return end
        llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
            hs.timer.doAfter(1, function()
                hs.focus()
                if needs_ollama then
                    local c = hs.dialog.blockAlert("Ollama absent",
                        "Pour utiliser l'IA, installez Ollama.\nSouhaitez-vous procéder ?",
                        "Installer", "Plus tard", "informational")
                    if c == "Installer" then
                        check_system_and_install(state.llm_model, disable_llm)
                    else disable_llm() end
                else
                    check_system_and_install(state.llm_model, disable_llm)
                end
            end)
        end)
    end

    return { build_item = build_item, check_startup = check_startup }
end

return M
