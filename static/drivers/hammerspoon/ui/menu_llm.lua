-- ===========================================================================
-- ui/menu_llm.lua
-- ===========================================================================

local M = {}

local hs      = hs
local llm_mod = require("modules.llm")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

-- NOUVEAU : Chargement du module d’édition de prompt
local ok_pe, prompt_editor = pcall(require, "ui.prompt_editor")
if not ok_pe then prompt_editor = nil end

local NBSP = "\194\160"  -- U+00A0

local DEFAULT_LLM_CONTEXT_LENGTH  = 500
local DEFAULT_LLM_TEMPERATURE     = 0.7
local DEFAULT_LLM_MAX_PREDICT     = 40
local DEFAULT_LLM_NUM_PREDICTIONS = llm_mod.DEFAULT_LLM_NUM_PREDICTIONS or 3

local ARROW_MOD_OPTIONS = {
    { label = "Aucun (flèches seules)", mods = {},
      warn = "⚠️ Conflits avec la navigation clavier (uniquement quand l’IA est visible)" },
    { label = "Ctrl ⌃",                mods = {"ctrl"},        warn = "" },
    { label = "Shift ⇧ + Commande ⌘",  mods = {"shift","cmd"}, warn = "" },
    { label = "Option ⌥",              mods = {"alt"},
      warn = "⚠️ Conflit avec Option+flèche (uniquement quand l’IA est visible)" },
    { label = "Shift ⇧",               mods = {"shift"},
      warn = "⚠️ Conflit avec Shift+flèche (uniquement quand l’IA est visible)" },
    { label = "Commande ⌘",            mods = {"cmd"},
      warn = "⚠️ Conflit avec ⌘+flèche (uniquement quand l’IA est visible)" },
}

local function mods_to_key(mods)
    if type(mods) ~= "table" then return "" end
    local s = {}; for _, m in ipairs(mods or {}) do s[#s+1] = m end
    table.sort(s); return table.concat(s, "+")
end

local function mods_label(mods)
    local k = mods_to_key(mods)
    if k == "" then return "Aucun (flèches seules)" end
    for _, opt in ipairs(ARROW_MOD_OPTIONS) do
        if mods_to_key(opt.mods) == k then return opt.label end
    end
    return "Valeur invalide (à reconfigurer)"
end

local function format_mod_string(m_str)
    local dict = { ctrl="⌃", cmd="⌘", alt="⌥", shift="⇧" }
    local res = ""
    for p in (m_str or ""):gmatch("[^+]+") do res = res .. (dict[p] or p) end
    return res == "" and "⌃" or res
end

-- ─────────────────────────────────────────────────────────
-- FACTORY
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

    if keymap and keymap.ignore_window_title then
        keymap.ignore_window_title("Nouveau profil")
        keymap.ignore_window_title("Modifier le profil")
    end

    if state.llm_active_profile == nil then
        state.llm_active_profile = "parallel_simple"
    end
    if state.llm_user_profiles == nil then
        state.llm_user_profiles = {}
    end
    if state.llm_temperature == nil then
        state.llm_temperature = DEFAULT_LLM_TEMPERATURE
    end

    llm_mod.active_profile_id = state.llm_active_profile
    llm_mod.user_profiles     = state.llm_user_profiles or {}

    local function disable_llm()
        state.llm_enabled = false
        if keymap and keymap.set_llm_enabled then keymap.set_llm_enabled(false) end
        save_prefs(); update_menu()
    end

    local function notify(title, body)
        pcall(function()
            hs.notify.new({ title=title, informativeText=body or "" }):send()
        end)
    end

    -- ──────────────────────────────────────────────────────
    -- SYSTEM DETECTION
    -- ──────────────────────────────────────────────────────
    local function get_ollama_path()
        local p = hs.execute("which ollama 2>/dev/null")
        if p and p ~= "" then return p:gsub("%s+","") end
        for _, c in ipairs({"/opt/homebrew/bin/ollama","/usr/local/bin/ollama"}) do
            if hs.fs.attributes(c) then return c end
        end
        return nil
    end

    -- ──────────────────────────────────────────────────────
    -- PRESET GROUPS (loaded from JSON)
    -- ──────────────────────────────────────────────────────
    local PRESET_GROUPS = (function()
        local candidates = {
            hs.configdir.."/data/llm_models.json",
            hs.configdir.."/../hammerspoon/data/llm_models.json",
        }
        for _, path in ipairs(candidates) do
            local fh = io.open(path,"r")
            if fh then
                local raw = fh:read("*a"); fh:close()
                local ok, data = pcall(hs.json.decode, raw)
                if ok and data and data.providers then return data.providers end
            end
        end
        return {} -- Fallback vide, le menu dépendra uniquement du JSON fourni par l’utilisateur
    end)()

    -- ──────────────────────────────────────────────────────
    -- MODEL METADATA PARSING & RAM REQUIREMENTS
    -- ──────────────────────────────────────────────────────
    local function get_model_info(model_name)
        local m_type = "chat"
        local p_count = 0

        -- Recherche dans le JSON (PRESET_GROUPS)
        for _, group in ipairs(PRESET_GROUPS) do
            for _, m in ipairs(group.models or {}) do
                if m.name == model_name or m.name .. ":latest" == model_name then
                    if m.type then m_type = m.type end
                    if m.params then
                        local num = m.params:match("([%d%.]+)")
                        if num then p_count = tonumber(num) end
                    end
                    return { type = m_type, params = p_count }
                end
            end
        end

        -- Fallback si le modèle n’est pas dans le JSON (déduit depuis le nom)
        if model_name:match("%-base$") or model_name:match("coder") then
            m_type = "completion"
        end
        local num = model_name:match("([%d%.]+)b")
        if num then p_count = tonumber(num) end

        return { type = m_type, params = p_count }
    end

    local _model_ram_cache = nil
    local function ensure_ram_cache()
        if _model_ram_cache then return end
        _model_ram_cache = {}
        for _, group in ipairs(PRESET_GROUPS) do
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
        if _model_ram_cache and _model_ram_cache[model_name] then
            return _model_ram_cache[model_name]
        end
        local info = get_model_info(model_name)
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

    local function get_model_requirements(model_name)
        local ram = get_model_ram(model_name)
        return math.ceil(ram * 0.7), ram
    end

    -- ──────────────────────────────────────────────────────
    -- APP PICKER
    -- ──────────────────────────────────────────────────────
    local function openAppPicker(on_select)
        local raw = hs.execute(
            'find /Applications "$HOME/Applications" -maxdepth 2 -name "*.app"'
            ..' -not -name ".*" 2>/dev/null | sort')
        local choices, seen = {}, {}
        for app_path in raw:gmatch("[^\n]+") do
            local name = app_path:match("([^/]+)%.app$")
            if name and not seen[app_path] then
                seen[app_path] = true
                local info = hs.application.infoForBundlePath(app_path)
                local bid  = info and info.CFBundleIdentifier
                local icon = nil
                if bid then
                    local ok, img = pcall(hs.image.imageFromAppBundle, bid)
                    if ok and img then
                        pcall(function() img:setSize({w=18,h=18}) end)
                        icon = img
                    end
                end
                table.insert(choices, {
                    text=name, subText=app_path, image=icon,
                    bundleID=bid, appPath=app_path,
                })
            end
        end
        table.sort(choices, function(a,b) return a.text:lower() < b.text:lower() end)
        local chooser = hs.chooser.new(function(c) if c then on_select(c) end end)
        chooser:placeholderText("Rechercher une application…")
        chooser:choices(choices)
        chooser:bgDark(false)
        chooser:show()
    end

    local function buildLLMDisabledAppsSubmenu()
        local apps = state.llm_disabled_apps or {}
        local menu  = {}
        for i, app in ipairs(apps) do
            local icon = nil
            if app.bundleID then
                local ok, img = pcall(hs.image.imageFromAppBundle, app.bundleID)
                if ok and img then pcall(function() img:setSize({w=16,h=16}) end); icon = img end
            end
            local idx = i
            local styled = hs.styledtext.new(
                (app.name or "?").."\t✗",
                { paragraphStyle={ tabStops={{location=260,alignment="right"}} } })
            table.insert(menu, {
                title=styled, image=icon,
                fn=function()
                    table.remove(state.llm_disabled_apps, idx)
                    if keymap and keymap.set_llm_disabled_apps then
                        keymap.set_llm_disabled_apps(state.llm_disabled_apps)
                    end
                    save_prefs(); update_menu()
                end,
            })
        end
        if #menu > 0 then table.insert(menu, {title="-"}) end
        table.insert(menu, {
            title="+ Ajouter une application…",
            fn=function()
                hs.timer.doAfter(0.1, function()
                    openAppPicker(function(choice)
                        if not state.llm_disabled_apps then state.llm_disabled_apps = {} end
                        for _, a in ipairs(state.llm_disabled_apps) do
                            if a.appPath == choice.appPath then return end
                        end
                        table.insert(state.llm_disabled_apps, {
                            name=choice.text, appPath=choice.appPath, bundleID=choice.bundleID,
                        })
                        if keymap and keymap.set_llm_disabled_apps then
                            keymap.set_llm_disabled_apps(state.llm_disabled_apps)
                        end
                        save_prefs(); update_menu()
                    end)
                end)
            end,
        })
        return menu
    end

    -- ──────────────────────────────────────────────────────
    -- INSTALLATION PIPELINE
    -- ──────────────────────────────────────────────────────
    local function pull_model(target_model)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then
            notify("❌ Ollama introuvable", "Installez Ollama depuis ollama.com."); return
        end
        local function do_cancel()
            local t = active_tasks["download"]
            if t and type(t)=="userdata" and t.terminate then t:terminate() end
        end
        if download_window then download_window.show(target_model, do_cancel) end
        update_icon("📥 0%"); update_menu()

        local _bytes_done, _bytes_total = 0, 0
        local task = hs.task.new(
            ollama_bin,
            function(exit_code, stdout, stderr)
                active_tasks["download"] = nil; update_icon(); update_menu()
                if exit_code == 15 then
                    notify("🛑 Annulé", "Téléchargement de "..target_model.." interrompu.")
                    if download_window then download_window.complete(false, target_model) end
                    return
                end
                local output   = (stdout or "")..(stderr or "")
                local has_err  = output:lower():find("not found") or output:lower():find("error")
                if exit_code == 0 and not has_err then
                    state.llm_model = target_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(target_model) end
                    save_prefs()
                    if download_window then download_window.complete(true, target_model) end
                    notify("🟢  MODÈLE INSTALLÉ", target_model.." est prêt à l’emploi !")
                    hs.timer.doAfter(2, hs.reload)
                else
                    local detail = output:sub(1,120)
                    if download_window then download_window.complete(false, target_model) end
                    notify("❌ Échec téléchargement", target_model.." : "..detail)
                    hs.timer.doAfter(0.3, function()
                        hs.focus()
                        hs.dialog.blockAlert("Échec du téléchargement",
                            "Modèle : "..target_model.."\n\nDétails :\n"..detail,
                            "OK", nil, "critical")
                    end)
                end
            end,
            function(_, stdout, stderr)
                local out = (stdout or "")..(stderr or "")
                local percent = out:match("(%d+)%%")
                local done_s, total_s = out:match("(%d+%.?%d*%s*%a+)/(%d+%.?%d*%s*%a+)")
                local function parse_size(s)
                    if not s then return nil end
                    s = s:match("^%s*(.-)%s*$"):lower()
                    local n, unit = s:match("^([%d%.]+)%s*(%a+)")
                    n = tonumber(n); if not n then return nil end
                    if unit=="gb" or unit=="g" then return n*1e9
                    elseif unit=="mb" or unit=="m" then return n*1e6
                    elseif unit=="kb" or unit=="k" then return n*1e3 end
                    return n
                end
                if done_s  then _bytes_done  = parse_size(done_s)  or _bytes_done  end
                if total_s then _bytes_total = parse_size(total_s) or _bytes_total end
                if percent then
                    update_icon("📥 "..percent.."%")
                    if download_window then
                        download_window.update(percent, _bytes_done, _bytes_total,
                            out:match("([^\13\10]+)") or "")
                    end
                elseif out:lower():find("pulling") or out:lower():find("downloading") then
                    update_icon("📥 Récupération…")
                    if download_window then download_window.update(0,0,0,out:match("([^\13\10]+)") or "") end
                elseif out:lower():find("verif") then
                    update_icon("📥 Vérification…")
                    if download_window then download_window.update(99,_bytes_done,_bytes_total,"Vérification…") end
                end
                return true
            end,
            { "pull", target_model }
        )
        active_tasks["download"] = task; task:start()
    end

    local function install_ollama_then_pull(target_model)
        notify("Étape 1/2 : Installation", "Téléchargement de l’application Ollama…")
        local task = hs.task.new("/bin/bash", function(code)
            active_tasks["install"] = nil
            if code==0 then
                notify("🟢 Ollama installé", "Lancement du téléchargement du modèle…")
                pull_model(target_model)
            else
                notify("❌ Échec installation", "L’installation d’Ollama a échoué.")
            end
        end, { "-c", [[
            curl -L https://ollama.com/download/ollama-darwin-universal.zip -o /tmp/ollama.zip
            unzip -o /tmp/ollama.zip -d /tmp/ollama_app
            cp -R /tmp/ollama_app/Ollama.app /Applications/
        ]] })
        active_tasks["install"] = task; task:start()
    end

    local function check_system_and_install(target_model, on_cancel)
        local req_disk, req_ram = get_model_requirements(target_model)
        
        local mem_str = hs.execute("sysctl -n hw.memsize")
        local sys_ram_gb = math.ceil((tonumber(mem_str) or 0) / (1024^3))
        
        local df_str = hs.execute("df -g / | awk 'NR==2 {print $4}'")
        local free_disk_gb = tonumber(df_str) or 0

        local warnings, is_critical = {}, false
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
                    "❌ Disque : %d Go disponible (requis ~%d Go) — espace insuffisant",
                    free_disk_gb, req_disk))
            elseif rem < 15 then
                table.insert(warnings, string.format(
                    "⚠️ Disque : %d Go disponible (requis ~%d Go) — espace limité",
                    free_disk_gb, req_disk))
            else
                table.insert(warnings, string.format(
                    "🟢 Disque : %d Go disponible (requis ~%d Go)", free_disk_gb, req_disk))
            end
        end

        local msg = "Modèle : "..target_model.."\n\n"..table.concat(warnings, "\n")
        hs.timer.doAfter(0.1, function()
            hs.focus()
            if is_critical then
                hs.dialog.blockAlert("Téléchargement impossible", msg, "Fermer", nil, "critical")
                if on_cancel then on_cancel() end; return
            end
            local sep = string.rep("─", 25)
            local choice = hs.dialog.blockAlert(
                "Téléchargement requis",
                sep.."\n"..msg.."\n"..sep
                .."\n\nCe modèle n’est pas encore installé."
                .."\nVoulez-vous lancer le téléchargement ?"
                .."\nLa progression sera visible dans une fenêtre dédiée.",
                "Télécharger", "Annuler",
                msg:find("⚠️") and "warning" or "informational")
            if choice == "Télécharger" then
                if get_ollama_path() then pull_model(target_model)
                else install_ollama_then_pull(target_model) end
            else
                if on_cancel then on_cancel() end
            end
        end)
    end

    -- ──────────────────────────────────────────────────────
    -- INSTALLED MODELS
    -- ──────────────────────────────────────────────────────
    local function get_installed_models()
        local installed  = {}
        local ollama_bin = get_ollama_path() or "/usr/local/bin/ollama"
        local output     = hs.execute(ollama_bin.." list 2>/dev/null")
        if output then
            for line in output:gmatch("[^\r\n]+") do
                local name = line:match("^(%S+)")
                if name and name ~= "NAME" then
                    installed[name] = true
                    if name:match(":latest$") then
                        installed[name:gsub(":latest$","")] = true
                    end
                end
            end
        end
        return installed
    end

    local function delete_model(model_name)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then notify("❌ Ollama introuvable",""); return end
        notify("🗑️ Suppression…", model_name)
        local t = hs.task.new(ollama_bin, function(code, out, err)
            if code==0 then notify("🗑️ Supprimé", model_name.." retiré du cache.")
            else notify("❌ Échec suppression", (err or out or ""):sub(1,80)) end
            update_menu()
        end, {"rm", model_name})
        t:start()
    end

    -- ──────────────────────────────────────────────────────
    -- PROMPT PROFILE MENU
    -- ──────────────────────────────────────────────────────

    local function sync_profiles()
        llm_mod.active_profile_id = state.llm_active_profile or "parallel_simple"
        llm_mod.user_profiles     = state.llm_user_profiles or {}
    end
    sync_profiles()

    local function get_all_profiles()
        local all = {}
        for _, p in ipairs(llm_mod.BUILTIN_PROFILES) do table.insert(all, p) end
        for _, p in ipairs(state.llm_user_profiles or {}) do table.insert(all, p) end
        return all
    end

    local function active_profile_label()
        local id = state.llm_active_profile or "parallel_simple"
        for _, p in ipairs(get_all_profiles()) do
            if p.id == id then return p.label end
        end
        return id
    end

    local function buildProfileMenu(paused)
        local menu = {}
        local all  = get_all_profiles()

        for _, profile in ipairs(all) do
            local pid  = profile.id
            local is_builtin = false
            for _, bp in ipairs(llm_mod.BUILTIN_PROFILES) do
                if bp.id == pid then is_builtin = true; break end
            end

            local is_thinking = llm_mod.is_thinking_model(state.llm_model)
            local extra = ""
            if (pid == "parallel_simple" or pid == "parallel_advanced") and is_thinking then
                extra = "  ⚠️ Non recommandé avec les modèles thinking"
            end

            local item = {
                title    = profile.label
                            ..(profile.description and ("  —  "..profile.description) or "")
                            ..extra,
                checked  = (state.llm_active_profile == pid) or nil,
                disabled = paused or nil,
            }

            if not is_builtin then
                item.menu = {
                    {
                        title    = "Utiliser ce profil",
                        checked  = (state.llm_active_profile == pid) or nil,
                        disabled = paused or nil,
                        fn       = not paused and function()
                            state.llm_active_profile = pid
                            sync_profiles()
                            save_prefs(); update_menu()
                        end or nil,
                    },
                    { title="-" },
                    {
                        title = "✏️ Modifier…",
                        fn    = function()
                            if prompt_editor then
                                hs.timer.doAfter(0.1, function()
                                    prompt_editor.open(profile, function(updated)
                                        for i, p in ipairs(state.llm_user_profiles) do
                                            if p.id == updated.id then
                                                state.llm_user_profiles[i] = updated; break
                                            end
                                        end
                                        sync_profiles(); save_prefs(); update_menu()
                                        notify("✅ Profil modifié", updated.label)
                                    end)
                                end)
                            else
                                notify("❌ Erreur", "Le module d’édition de prompt est introuvable.")
                            end
                        end,
                    },
                    {
                        title = "🗑️ Supprimer…",
                        fn    = function()
                            hs.focus()
                            local c = hs.dialog.blockAlert(
                                "Supprimer \""..profile.label.."\" ?",
                                "Ce profil personnalisé sera supprimé définitivement.",
                                "Supprimer", "Annuler", "critical")
                            if c ~= "Supprimer" then return end
                            local kept = {}
                            for _, p in ipairs(state.llm_user_profiles) do
                                if p.id ~= pid then table.insert(kept, p) end
                            end
                            state.llm_user_profiles = kept
                            if state.llm_active_profile == pid then
                                state.llm_active_profile = "parallel_simple"
                            end
                            sync_profiles(); save_prefs(); update_menu()
                        end,
                    },
                }
                item.fn = nil
            else
                item.fn = not paused and function()
                    state.llm_active_profile = pid
                    sync_profiles(); save_prefs(); update_menu()
                end or nil
            end

            table.insert(menu, item)
        end

        table.insert(menu, { title="-" })
        table.insert(menu, {
            title = "+ Créer un profil personnalisé…",
            fn    = not paused and function()
                if prompt_editor then
                    hs.timer.doAfter(0.1, function()
                        prompt_editor.open(nil, function(new_profile)
                            if not state.llm_user_profiles then state.llm_user_profiles = {} end
                            table.insert(state.llm_user_profiles, new_profile)
                            state.llm_active_profile = new_profile.id
                            sync_profiles(); save_prefs(); update_menu()
                            notify("✅ Profil créé", new_profile.label)
                        end)
                    end)
                else
                    notify("❌ Erreur", "Le module d’édition de prompt est introuvable.")
                end
            end or nil,
        })
        return menu
    end

    -- ──────────────────────────────────────────────────────
    -- MENU BUILDER
    -- ──────────────────────────────────────────────────────
    local function build_item()
        local paused      = script_control and script_control.is_paused() or false
        local debounce_ms = math.floor(state.llm_debounce * 1000 + 0.5)
        local installed     = get_installed_models()
        local num_pred      = math.max(1, math.floor(
            tonumber(state.llm_num_predictions) or DEFAULT_LLM_NUM_PREDICTIONS))
        local arrow_enabled = state.llm_arrow_nav_enabled or false
        local arrow_mods    = state.llm_arrow_nav_mods or {}
        local show_info_bar     = state.llm_show_info_bar
        local pred_shortcut_mod = state.llm_pred_shortcut_mod or "ctrl"
        local user_models       = state.llm_user_models or {}
        local is_downloading    = (active_tasks["download"] ~= nil)
        local is_small          = llm_mod.is_small_model(state.llm_model)
        local is_thinking       = llm_mod.is_thinking_model(state.llm_model)

        local function cancel_download()
            local t = active_tasks["download"]
            if t and type(t)=="userdata" and t.terminate then t:terminate() end
        end

        local function switch_model(new_model)
            if not get_ollama_path() then
                notify("❌ Ollama introuvable","Installez Ollama depuis ollama.com."); return
            end
            notify("⏳ Vérification…", new_model)
            llm_mod.check_availability(new_model,
                function()
                    state.llm_model = new_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(new_model) end

                    -- Changement automatique de la stratégie de prompt
                    local info = get_model_info(new_model)
                    local prev_profile = state.llm_active_profile
                    
                    if info.type == "completion" then
                        state.llm_active_profile = "base_completion"
                    else
                        if info.params > 10 then
                            state.llm_active_profile = "batch_simple"
                        else
                            state.llm_active_profile = "parallel_simple"
                        end
                    end
                    llm_mod.active_profile_id = state.llm_active_profile

                    save_prefs(); update_menu()

                    local msg = new_model
                    if prev_profile ~= state.llm_active_profile then
                        msg = msg .. "\nStratégie auto : " .. (state.llm_active_profile:gsub("_", " "))
                    end
                    notify("🟢  MODÈLE ACTIF", msg)
                end,
                function(needs_ollama)
                    hs.timer.doAfter(0.1, function()
                        hs.focus()
                        if needs_ollama then
                            local c = hs.dialog.blockAlert("Ollama non disponible",
                                "Ollama n’est pas lancé ou installé.\nInstaller maintenant ?",
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
            local m_name  = type(m)=="table" and m.name or m
            local ram     = (type(m)=="table" and m.ram_gb)
                            and math.ceil(m.ram_gb) or get_model_ram(m_name)
            local is_inst = installed[m_name] or installed[m_name..":latest"]
            local is_model_thinking = llm_mod.is_thinking_model(m_name)

            local seen_emojis = {}
            if is_model_thinking then seen_emojis["🧠💭"] = true end

            if type(m)=="table" and m.tags and #m.tags > 0 then
                for _, t in ipairs(m.tags) do
                    local em = ({best="⭐",reasoning="🧠",math="🧠",code="💻",
                                 completion="💻",fast="⚡",tiny="⚡",
                                 ["ultra-tiny"]="⚡",edge="⚡",
                                 multilingual="🌐",chinese="🌐",korean="🌐",
                                 multimodal="🖼️",["high-quality"]="🏆",quality="🏆"})[t]
                    
                    if em == "🧠" and seen_emojis["🧠💭"] then em = nil end
                    if em then seen_emojis[em] = true end
                end
            end

            local tag_list = {}
            for em, _ in pairs(seen_emojis) do table.insert(tag_list, em) end

            local EMOJI_ORDER = { ["🏆"]=1, ["⚡"]=2, ["🧠💭"]=3, ["🧠"]=4, ["💻"]=5, ["🌐"]=6, ["🖼️"]=7, ["⭐"]=8 }
            
            table.sort(tag_list, function(a, b)
                local oa = EMOJI_ORDER[a] or 99
                local ob = EMOJI_ORDER[b] or 99
                if oa == ob then return a < b end
                return oa < ob
            end)

            local tag_str = #tag_list > 0 and (" " .. table.concat(tag_list, "")) or ""
            local params_str = (type(m)=="table" and m.params) and (" · "..m.params) or ""
            
            local type_str = ""
            if type(m) == "table" and m.type then
                if m.type == "completion" then type_str = " [📝 Complétion]"
                elseif m.type == "chat" then type_str = " [💬 Chat]" end
            elseif m_name:match("%-base$") or m_name:match("coder") then
                type_str = " [📝 Complétion]"
            else
                type_str = " [💬 Chat]"
            end

            local title = string.format("%s%s%s (~%d Go RAM%s)%s",
                is_inst and "🟢 " or "  ",
                m_name, type_str, ram, params_str, tag_str)

            if is_inst then
                return {
                    title   = title,
                    checked = (state.llm_model == m_name),
                    menu    = {
                        { title="Utiliser ce modèle",
                          fn=not paused and function() switch_model(m_name) end or nil },
                        { title="-" },
                        { title="🗑️ Supprimer du cache…",
                          fn=function()
                            hs.focus()
                            local c = hs.dialog.blockAlert("Supprimer "..m_name.." ?",
                                "Le modèle sera supprimé du disque.\n"
                                .."Il faudra le re-télécharger pour l’utiliser.",
                                "Supprimer","Annuler","critical")
                            if c=="Supprimer" then delete_model(m_name) end
                          end },
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
            for _, m in ipairs(group.models or {}) do table.insert(sub, model_item(m)) end
            if #sub>0 then
                table.insert(models_menu, {title=group.label or group.id or "?", menu=sub})
            end
        end
        table.insert(models_menu, {title="-"})

        local user_sub = {}
        table.insert(user_sub, {
            title="+ Ajouter un modèle personnalisé…",
            fn=not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Ajouter un modèle",
                    "Nom exact du modèle Ollama (ex : llama3.1:8b) :",
                    "","Ajouter","Annuler")
                if btn~="Ajouter" or not raw or raw:match("^%s*$") then return end
                local name = raw:match("^%s*(.-)%s*$")
                for _, e in ipairs(state.llm_user_models or {}) do
                    if e==name then notify("ℹ️ Déjà présent",name); return end
                end
                state.llm_user_models = state.llm_user_models or {}
                table.insert(state.llm_user_models, name)
                save_prefs(); update_menu()
            end or nil,
        })
        if #user_models>0 then
            table.insert(user_sub, {title="-"})
            for idx, m in ipairs(user_models) do
                local it = model_item(m)
                local remove_fn = function()
                    table.remove(state.llm_user_models, idx)
                    if state.llm_model==m then
                        state.llm_model = llm_mod.DEFAULT_LLM_MODEL or "llama3.1"
                        if keymap and keymap.set_llm_model then
                            keymap.set_llm_model(state.llm_model)
                        end
                    end
                    save_prefs(); update_menu()
                end
                local remove_item = {title="✂️ Retirer de mes modèles", fn=remove_fn}
                if it.menu then
                    table.insert(it.menu, {title="-"})
                    table.insert(it.menu, remove_item)
                else
                    it.menu = {
                        {title="Utiliser ce modèle",
                         fn=not paused and function() switch_model(m) end or nil},
                        {title="-"},
                        remove_item,
                    }
                    it.fn = nil
                end
                table.insert(user_sub, it)
            end
        end
        table.insert(models_menu, {
            title="Autres modèles"..(#user_models>0 and (" ("..#user_models..")") or ""),
            menu=user_sub,
        })

        local pred_label = num_pred.." suggestion"..(num_pred>1 and "s" or "")
        local num_pred_menu = {}
        for n=1,10 do
            table.insert(num_pred_menu, {
                title   = n.." suggestion"..(n>1 and "s" or ""),
                checked = (n==num_pred) or nil,
                fn      = not paused and (function(chosen) return function()
                    state.llm_num_predictions = chosen
                    if keymap and keymap.set_llm_num_predictions then
                        keymap.set_llm_num_predictions(chosen)
                    end
                    save_prefs(); update_menu()
                end end)(n) or nil,
            })
        end

        -- ==========================================
        -- SOUS-MENUS RÉUTILISABLES
        -- ==========================================

        -- Sous-menu : Indentation
        local cur_indent = math.max(0, math.min(5, math.floor(tonumber(state.llm_pred_indent) or 0)))
        local sub_indent = {}
        for n=0,5 do
            table.insert(sub_indent, {
                title   = n==0 and "0 — aucune" or (n.." espace"..(n>1 and "s" or "")),
                checked = (n==cur_indent) or nil,
                fn      = not paused and (function(v) return function()
                    state.llm_pred_indent = v
                    if keymap and keymap.set_llm_pred_indent then keymap.set_llm_pred_indent(v) end
                    save_prefs(); update_menu()
                end end)(n) or nil,
            })
        end

        -- Sous-menu : Raccourcis de sélection
        local mod_sym = format_mod_string(pred_shortcut_mod)
        local function apply_pm(m)
            state.llm_pred_shortcut_mod = m
            if keymap and keymap.set_llm_pred_shortcut_mod then keymap.set_llm_pred_shortcut_mod(m) end
            save_prefs(); update_menu()
        end
        local mod_sub = {
            { title="Ctrl ⌃ (défaut)", checked=(pred_shortcut_mod=="ctrl") or nil, fn=not paused and function() apply_pm("ctrl") end or nil },
            { title="Option ⌥",        checked=(pred_shortcut_mod=="alt")  or nil, fn=not paused and function() apply_pm("alt")  end or nil },
            { title="Commande ⌘",      checked=(pred_shortcut_mod=="cmd")  or nil, fn=not paused and function() apply_pm("cmd")  end or nil },
            { title="Shift ⇧ + Commande ⌘", checked=(pred_shortcut_mod=="shift+cmd" or pred_shortcut_mod=="cmd+shift") or nil, fn=not paused and function() apply_pm("cmd+shift") end or nil },
            { title="-" },
            { title="Personnaliser…", disabled=paused or nil, fn=not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Modificateur", "Séparés par '+' (ex: cmd+alt) :", pred_shortcut_mod,"OK","Annuler")
                if btn=="OK" and raw~="" then
                    local parts={}
                    for p in raw:lower():gmatch("[a-z]+") do
                        if p=="option" then p="alt" end; if p=="command" then p="cmd" end; if p=="control" then p="ctrl" end
                        if p=="cmd" or p=="ctrl" or p=="alt" or p=="shift" then table.insert(parts,p) end
                    end
                    if #parts>0 then table.sort(parts); apply_pm(table.concat(parts,"+")) end
                end
              end or nil },
        }

        -- Sous-menu : Modificateurs flèches
        local cur_key = mods_to_key(arrow_mods)
        local mods_sub = {}
        for _, opt in ipairs(ARROW_MOD_OPTIONS) do
            table.insert(mods_sub, {
                title    = opt.label..(opt.warn~="" and "  "..opt.warn or ""),
                checked  = (mods_to_key(opt.mods)==cur_key) or nil,
                disabled = not arrow_enabled or paused or nil,
                fn       = (arrow_enabled and not paused) and (function(mo) return function()
                    state.llm_arrow_nav_mods = mo
                    if keymap and keymap.set_llm_arrow_nav_mods then keymap.set_llm_arrow_nav_mods(mo) end
                    save_prefs(); update_menu()
                end end)(opt.mods) or nil,
            })
        end

        -- ==========================================
        -- CONSTRUCTION DU MENU PRINCIPAL
        -- ==========================================
        local main_menu = {}

        if is_downloading then
            table.insert(main_menu, { title="🛑 Annuler le téléchargement en cours", fn=cancel_download })
            table.insert(main_menu, { title="-" })
        end

        -- --- 1. MODÈLE ---
        local model_badge = ""
        if is_thinking then model_badge = " 🧠💭"
        elseif is_small then model_badge = " ⚡" end
        
        table.insert(main_menu, {
            title    = "Modèle actif : "..state.llm_model..model_badge,
            disabled = paused or nil,
            menu     = models_menu,
        })

        if is_thinking then
            table.insert(main_menu, { title = "   ↳ Info : Modèle thinking (réflexion masquée)", disabled = true })
        end

        table.insert(main_menu, { title="-" })

        -- --- 2. COMPORTEMENT & PERFORMANCES ---
        table.insert(main_menu, { title="— COMPORTEMENT & PERFORMANCES —", disabled=true })

        local profile_warning = ""
        if is_thinking and state.llm_active_profile == "parallel_simple" then profile_warning = "  ⚠️" end
        table.insert(main_menu, {
            title    = "Stratégie IA : "..active_profile_label()..profile_warning,
            disabled = paused or nil,
            menu     = buildProfileMenu(paused),
        })

        table.insert(main_menu, {
            title    = "Nombre de suggestions : "..pred_label,
            disabled = paused or nil,
            menu     = num_pred_menu,
        })

        table.insert(main_menu, {
            title    = "Délai d’inactivité avant prédiction : "..debounce_ms.." ms…",
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Délai (ms)", "Temps d’inactivité clavier (ex: 500) :", tostring(debounce_ms),"OK","Annuler")
                if btn=="OK" and tonumber(raw) then
                    state.llm_debounce = tonumber(raw)/1000
                    if keymap and keymap.set_llm_debounce then keymap.set_llm_debounce(state.llm_debounce) end
                    save_prefs(); update_menu()
                end
            end or nil,
        })

        table.insert(main_menu, {
            title    = "Tokens max générés : "..state.llm_max_predict..(is_thinking and " (min 400 pour réflexion)" or ""),
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Tokens max", "Ex: 40 :", tostring(state.llm_max_predict),"OK","Annuler")
                if btn=="OK" and tonumber(raw) then
                    state.llm_max_predict = tonumber(raw)
                    if keymap and keymap.set_llm_max_predict then keymap.set_llm_max_predict(state.llm_max_predict) end
                    save_prefs(); update_menu()
                end
            end or nil,
        })

        table.insert(main_menu, {
            title    = "Température (Créativité) : "..state.llm_temperature,
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Température", "De 0.0 (strict) à 1.0 (créatif) :", tostring(state.llm_temperature),"OK","Annuler")
                if btn=="OK" and tonumber(raw) then
                    state.llm_temperature = tonumber(raw)
                    if keymap and keymap.set_llm_temperature then keymap.set_llm_temperature(state.llm_temperature) end
                    save_prefs(); update_menu()
                end
            end or nil,
        })

        table.insert(main_menu, { title="-" })

        -- --- 3. CONTEXTE & EXCLUSIONS ---
        table.insert(main_menu, { title="— CONTEXTE & EXCLUSIONS —", disabled=true })

        table.insert(main_menu, {
            title    = "Taille du contexte envoyé : "..state.llm_context_length.." derniers caractères",
            disabled = paused or nil,
            fn       = not paused and function()
                hs.focus()
                local btn, raw = hs.dialog.textPrompt("Contexte", "Caractères à analyser (ex: 500) :", tostring(state.llm_context_length),"OK","Annuler")
                if btn=="OK" and tonumber(raw) then
                    state.llm_context_length = tonumber(raw)
                    if keymap and keymap.set_llm_context_length then keymap.set_llm_context_length(state.llm_context_length) end
                    save_prefs(); update_menu()
                end
            end or nil,
        })

        table.insert(main_menu, {
            title    = "Vider le contexte sur clic de souris/navigation",
            checked  = state.llm_reset_on_nav,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_reset_on_nav = not state.llm_reset_on_nav
                if keymap and keymap.set_llm_reset_on_nav then keymap.set_llm_reset_on_nav(state.llm_reset_on_nav) end
                save_prefs(); update_menu()
            end or nil,
        })

        local disabled_count = #(state.llm_disabled_apps or {})
        table.insert(main_menu, {
            title = "Désactivé dans"..(disabled_count>0 and (" "..disabled_count.." application(s)") or " ces applications"),
            menu  = buildLLMDisabledAppsSubmenu(),
        })

        table.insert(main_menu, { title="-" })

        -- --- 4. INTERFACE & RACCOURCIS ---
        table.insert(main_menu, { title="— INTERFACE & RACCOURCIS —", disabled=true })

        table.insert(main_menu, {
            title    = "Afficher la barre d’info (Modèle & Latence)",
            checked  = show_info_bar or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_show_info_bar = not show_info_bar
                if keymap and keymap.set_llm_show_info_bar then keymap.set_llm_show_info_bar(state.llm_show_info_bar) end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(main_menu, {
            title    = "Raccourcis de sélection : "..mod_sym.."1 – "..mod_sym.."0",
            disabled = paused or nil,
            menu     = mod_sub,
        })

        table.insert(main_menu, {
            title    = "Naviguer dans les prédictions avec les flèches",
            checked  = arrow_enabled or nil,
            disabled = paused or nil,
            fn       = not paused and function()
                state.llm_arrow_nav_enabled = not arrow_enabled
                if keymap and keymap.set_llm_arrow_nav_enabled then keymap.set_llm_arrow_nav_enabled(state.llm_arrow_nav_enabled) end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(main_menu, {
            title    = "   ↳ Modificateurs requis : "..mods_label(arrow_mods),
            disabled = not arrow_enabled or paused or nil,
            menu     = mods_sub,
        })

        table.insert(main_menu, {
            title    = "Indentation de la prédiction insérée : "..cur_indent,
            disabled = paused or nil,
            menu     = sub_indent,
        })

        return {
            title   = "Intelligence Artificielle",
            checked = (state.llm_enabled and not paused) or nil,
            fn      = not paused and function()
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
                                    "Pour utiliser l’IA, installez Ollama.\nSouhaitez-vous procéder ?",
                                    "Installer","Plus tard","informational")
                                if c=="Installer" then
                                    check_system_and_install(state.llm_model, disable_llm)
                                else disable_llm() end
                            else
                                check_system_and_install(state.llm_model, disable_llm)
                            end
                        end)
                    end
                )
            end or nil,
            menu = main_menu,
        }
    end

    local function check_startup()
        if not state.llm_enabled then return end
        llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
            hs.timer.doAfter(1, function()
                hs.focus()
                if needs_ollama then
                    local c = hs.dialog.blockAlert("Ollama absent",
                        "Pour utiliser l’IA, installez Ollama.\nSouhaitez-vous procéder ?",
                        "Installer","Plus tard","informational")
                    if c=="Installer" then
                        check_system_and_install(state.llm_model, disable_llm)
                    else disable_llm() end
                else
                    check_system_and_install(state.llm_model, disable_llm)
                end
            end)
        end)
    end

    return { build_item=build_item, check_startup=check_startup }
end

return M
