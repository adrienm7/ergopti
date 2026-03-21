-- ui/menu_llm.lua
-- Factory for the LLM (Ollama) menu section.
-- Handles system checks, installation, model downloads, and builds
-- the "Prediction par IA (LLM)" menu item.
--
-- Usage (called from ui/menu.lua AFTER startup prefs are applied):
--   local h = require("ui.menu_llm").create(deps)
--   h.check_startup()    -- once, after prefs are fully loaded
--   h.build_item()       -- inside updateMenu()

local M = {}

local llm_mod = require("modules.llm")

local NBSP  = "\194\160"      -- U+00A0  non-breaking space   (before :)
local NNBSP = "\226\128\175"  -- U+202F  narrow no-break sp.  (before !  ?)

-- ================================
-- ================================
-- ================================
-- ========== 1. FACTORY ==========
-- ================================
-- ================================
-- ================================

---@param  deps table  { state, active_tasks, update_icon, update_menu, save_prefs, keymap, script_control }
---@return table       { build_item:function, check_startup:function }
function M.create(deps)
    assert(type(deps)              == "table",    "[menu_llm] deps must be a table")
    assert(type(deps.state)        == "table",    "[menu_llm] deps.state must be a table")
    assert(type(deps.active_tasks) == "table",    "[menu_llm] deps.active_tasks must be a table")
    assert(type(deps.update_icon)  == "function", "[menu_llm] deps.update_icon must be a function")
    assert(type(deps.update_menu)  == "function", "[menu_llm] deps.update_menu must be a function")
    assert(type(deps.save_prefs)   == "function", "[menu_llm] deps.save_prefs must be a function")

    local state          = deps.state
    local active_tasks   = deps.active_tasks
    local update_icon    = deps.update_icon
    local update_menu    = deps.update_menu
    local save_prefs     = deps.save_prefs
    local keymap         = deps.keymap
    local script_control = deps.script_control

    -- ==================================
-- ======= 1.1 Shared Helpers =======
-- ==================================

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

-- =========================================
-- =========================================
-- =========================================
-- ========== 2. SYSTEM DETECTION ==========
-- =========================================
-- =========================================
-- =========================================

    local function get_ollama_path()
        local p = hs.execute("which ollama 2>/dev/null")
        if p and p ~= "" then return p:gsub("%s+", "") end
        for _, c in ipairs({ "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama" }) do
            if hs.fs.attributes(c) then return c end
        end
        return nil
    end

-- ===========================================
-- ===========================================
-- ===========================================
-- ========== 3. MODEL REQUIREMENTS ==========
-- ===========================================
-- ===========================================
-- ===========================================

    ---@param  model_name string
    ---@return number disk_gb, number ram_gb
    local function get_model_requirements(model_name)
        local name    = model_name:lower()
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
                ["llama3%.2"] = 3, llama3 = 8, mistral = 7, qwen = 7,
                gemma2 = 9, phi3 = 4, mixtral = 47,
            }
            for pattern, sz in pairs(defaults) do
                if name:find(pattern) then total_b = sz; break end
            end
            if total_b == 0 then total_b = 8 end
        end
        return math.ceil(total_b * 0.6 + 0.5), math.ceil(total_b * 0.7 + 2.0)
    end

-- ==============================================
-- ==============================================
-- ==============================================
-- ========== 4. INSTALLATION PIPELINE ==========
-- ==============================================
-- ==============================================
-- ==============================================


    -- ================================
-- ======= 4.1 Progress Bar =======
-- ================================

    local function make_progress_bar(pct)
        local p      = math.max(0, math.min(100, tonumber(pct) or 0))
        local filled = math.floor(p / 10)
        return string.rep("\226\150\160", filled) .. string.rep("\226\150\161", 10 - filled)
    end

    -- ==============================
-- ======= 4.2 Model Pull =======
-- ==============================

    local function pull_model(target_model)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then
            notify("❌ Ollama introuvable", "Impossible de localiser l’exécutable ollama.")
            return
        end

        -- Immediate feedback so the user knows something started
        notify("\226\143\167 Téléchargement démarré", target_model .. " se télécharge en arrière-plan…")
        update_icon("\240\159\147\165 Démarrage…")

        local task_id = "download"
        local task = hs.task.new(
            ollama_bin,
            function(exit_code, stdout, stderr)
                active_tasks[task_id] = nil
                update_icon(); update_menu()

                if exit_code == 15 then
                    notify("🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
                    return
                end

                local output    = (stdout or "") .. (stderr or "")
                local has_error = output:lower():find("not found") or output:lower():find("error")

                if exit_code == 0 and not has_error then
                    state.llm_model = target_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(target_model) end
                    save_prefs()
                    notify("🟢  MODÈLE INSTALLÉ", target_model .. " est prêt à l’emploi.")
                    hs.timer.doAfter(1, hs.reload)
                else
                    notify("❌ Échec du téléchargement", target_model .. " — " .. output:sub(1, 80))
                    hs.dialog.blockAlert(
                        "Erreur de modèle",
                        "Le modèle [" .. target_model .. "] n'a pas pu être téléchargé.\n\n"
                        .. "Détails" .. NBSP .. ": " .. output:sub(1, 150) .. "…",
                        "OK", nil, "critical"
                    )
                end
            end,
            function(_, stdout, stderr)
                local out     = (stdout or "") .. (stderr or "")
                local percent = out:match("(%d+)%%")
                if percent then
                    update_icon("\240\159\147\165 " .. make_progress_bar(percent) .. " " .. percent .. "%")
                elseif out:lower():find("pulling") or out:lower():find("downloading") then
                    update_icon("\240\159\147\165 Récupération…")
                end
                return true
            end,
            { "pull", target_model }
        )

        -- Store BEFORE start so Cancel button appears immediately in menu
        active_tasks[task_id] = task
        update_menu()
        task:start()
    end

-- ====================================
-- ======= 4.3 Full App Install =======
-- ====================================

    local function install_ollama_then_pull(target_model)
        notify("Étape 1/2" .. NBSP .. ": Installation", "Téléchargement de l'application Ollama…")
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

-- ======================================
-- ======================================
-- ======================================
-- ========== 5. SYSTEM CHECKS ==========
-- ======================================
-- ======================================
-- ======================================

    ---@param target_model string
    ---@param on_cancel    function|nil
    local function check_system_and_install(target_model, on_cancel)
        local req_disk, req_ram = get_model_requirements(target_model)
        local sys_ram_gb        = math.ceil(
            (tonumber(hs.execute("sysctl -n hw.memsize")) or 0) / (1024 ^ 3))
        local free_disk_gb      = tonumber(
            hs.execute("df -g / | awk 'NR==2 {print $4}'")) or 0

        local warnings    = {}
        local is_critical = false

        if sys_ram_gb > 0 and sys_ram_gb < req_ram then
            table.insert(warnings, string.format(
                "⚠️ RAM" .. NBSP .. ": %d Go (requiert ~%d Go). Risque de lenteur.",
                sys_ram_gb, req_ram))
        else
            table.insert(warnings, string.format(
                "🟢 RAM" .. NBSP .. ": %d Go OK (requiert ~%d Go).", sys_ram_gb, req_ram))
        end

        if free_disk_gb > 0 then
            local remaining = free_disk_gb - req_disk
            if remaining < 2 then
                is_critical = true
                table.insert(warnings, string.format(
                    "❌ Disque" .. NBSP .. ": seulement %d Go restant après installation. Bloqué.", remaining))
            elseif remaining < 15 then
                table.insert(warnings, string.format(
                    "\226\154\160\239\184\143 Disque" .. NBSP .. ": %d Go restants (poids" .. NBSP .. ": ~%d Go).",
                    remaining, req_disk))
            else
                table.insert(warnings, string.format(
                    "🟢 Disque" .. NBSP .. ": OK (poids" .. NBSP .. ": ~%d Go).", req_disk))
            end
        end

        local msg = "Modèle ciblé" .. NBSP .. ": " .. target_model .. "\n\n"
                    .. table.concat(warnings, "\n")

        hs.timer.doAfter(0.1, function()
            if is_critical then
                hs.dialog.blockAlert("Téléchargement bloqué", msg, "Annuler", nil, "critical")
                if on_cancel then on_cancel() end
                return
            end

            local alert_type = (msg:find("⚠️") or msg:find("\226\154\160\239\184\143"))
                                and "warning" or "informational"
            local choice = hs.dialog.blockAlert(
                "Installation requise",
                msg .. "\n\nCe modèle n’est pas installé.\n"
                .. "Voulez-vous lancer le téléchargement en arrière-plan" .. NBSP .. "?",
                "Télécharger", "Annuler", alert_type
            )

            if choice == "Télécharger" then
                if get_ollama_path() then pull_model(target_model)
                else install_ollama_then_pull(target_model) end
            else
                if on_cancel then on_cancel() end
            end
        end)
    end

-- =================================================
-- =================================================
-- =================================================
-- ========== 6. INSTALLED MODELS CATALOG ==========
-- =================================================
-- =================================================
-- =================================================

    ---@return table  { [model_name] = true }
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

-- =====================================
-- =====================================
-- =====================================
-- ========== 7. MENU BUILDER ==========
-- =====================================
-- =====================================
-- =====================================

    local PRESET_GROUPS = {
        { "llama3.2:1b",  "llama3.2",    "llama3.1"     },
        { "qwen2.5:0.5b", "qwen2.5:1.5b","qwen2.5:7b",  "qwen2.5:14b" },
        { "mistral",      "mixtral:8x7b" },
        { "gemma2:2b",    "gemma2",       "gemma2:27b"   },
        { "phi3",         "phi3:14b"      },
    }

    ---@return table  Hammerspoon menu item
    local function build_item()
        local paused      = script_control and script_control.is_paused() or false
        local debounce_ms = math.floor(state.llm_debounce * 1000 + 0.5)
        local installed   = get_installed_models()

-- ======================================
-- ======= 7.1 Model Switch Logic =======
-- ======================================

        local function switch_model(new_model)
            -- Immediate feedback: user clicked, something is happening
            notify("\226\143\167 Vérification…", "Contrôle du modèle " .. new_model .. "…")

            llm_mod.check_availability(new_model,
                function()
                    state.llm_model = new_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(new_model) end
                    save_prefs(); update_menu()
                    notify("🟢  MODELE CHANGE", new_model .. " est actif.")
                end,
                function(needs_ollama)
                    hs.timer.doAfter(0.1, function()
                        if needs_ollama then
                            hs.dialog.blockAlert("Ollama absent",
                                "Ollama ne semble pasêtre lancé ou installé.", "OK")
                        else
                            check_system_and_install(new_model)
                        end
                    end)
                end
            )
        end

-- ===================================
-- ======= 7.2 Models Sub-Menu =======
-- ===================================

        local models_menu = {}

        -- Cancel button pinned at top when a download is active
        if active_tasks["download"] then
            table.insert(models_menu, {
                title = "🛑 Annuler le téléchargement en cours",
                fn    = function()
                    local t = active_tasks["download"]
                    if t and type(t) == "userdata" and t.terminate then t:terminate() end
                end,
            })
            table.insert(models_menu, { title = "-" })
        end

        for i, group in ipairs(PRESET_GROUPS) do
            for _, m in ipairs(group) do
                local _, ram       = get_model_requirements(m)
                local is_installed = installed[m] or installed[m .. ":latest"]
                table.insert(models_menu, {
                    title   = string.format("%s%s (~%d Go RAM)",
                                is_installed and "🟢 " or "  ", m, ram),
                    checked = (state.llm_model == m),
                    fn      = not paused and function() switch_model(m) end or nil,
                })
            end
            if i < #PRESET_GROUPS then table.insert(models_menu, { title = "-" }) end
        end

        table.insert(models_menu, { title = "-" })
        table.insert(models_menu, {
            title = "  Autre modèle (saisie manuelle)…",
            fn    = not paused and function()
                local btn, raw = hs.dialog.textPrompt(
                    "Modèle IA personnalisé",
                    "Entrez le nom exact du modèle Ollama" .. NBSP .. ":",
                    state.llm_model, "OK", "Annuler"
                )
                if btn == "OK" and raw and raw ~= "" then
                    switch_model(raw:match("^%s*(.-)%s*$"))
                end
            end or nil,
        })

-- ===========================================
-- ======= 7.3 Advanced Settings Menu ========
-- ===========================================

        local advanced_menu = {
            {
                title = "Contexte" .. NBSP .. ": " .. state.llm_context_length .. " derniers caractères.",
                disabled = paused or nil,
                fn = not paused and function()
                    local btn, raw = hs.dialog.textPrompt("Longueur du contexte", 
                        "Entrez le nombre de caractères gardés en mémoire (ex: 500) :", 
                        tostring(state.llm_context_length), "OK", "Annuler")
                    if btn == "OK" and tonumber(raw) then
                        state.llm_context_length = tonumber(raw)
                        if keymap and keymap.set_llm_context_length then 
                            keymap.set_llm_context_length(state.llm_context_length) 
                        end
                        save_prefs(); update_menu()
                    end
                end or nil
            },
            {
                title = "Reset contexte sur clic/flèches",
                checked = state.llm_reset_on_nav,
                disabled = paused or nil,
                fn = not paused and function()
                    state.llm_reset_on_nav = not state.llm_reset_on_nav
                    if keymap and keymap.set_llm_reset_on_nav then 
                        keymap.set_llm_reset_on_nav(state.llm_reset_on_nav) 
                    end
                    save_prefs(); update_menu()
                end or nil
            },
            {
                title = "Température" .. NBSP .. ": " .. state.llm_temperature,
                disabled = paused or nil,
                fn = not paused and function()
                    local btn, raw = hs.dialog.textPrompt("Température du LLM", 
                        "Nombre décimal entre 0.0 (prévisible) et 1.0 (créatif)" .. NBSP .. ":", 
                        tostring(state.llm_temperature), "OK", "Annuler")
                    if btn == "OK" and tonumber(raw) then
                        state.llm_temperature = tonumber(raw)
                        if keymap and keymap.set_llm_temperature then 
                            keymap.set_llm_temperature(state.llm_temperature) 
                        end
                        save_prefs(); update_menu()
                    end
                end or nil
            },
            {
                title = "Longueur max. de prédiction : " .. state.llm_max_predict .. " tokens",
                disabled = paused or nil,
                fn = not paused and function()
                    local btn, raw = hs.dialog.textPrompt("Prédiction maximale", 
                        "Nombre maximum de mots/tokens générés par l'IA (ex: 40) :", 
                        tostring(state.llm_max_predict), "OK", "Annuler")
                    if btn == "OK" and tonumber(raw) then
                        state.llm_max_predict = tonumber(raw)
                        if keymap and keymap.set_llm_max_predict then 
                            keymap.set_llm_max_predict(state.llm_max_predict) 
                        end
                        save_prefs(); update_menu()
                    end
                end or nil
            }
        }

-- ===========================================
-- ======= 7.4 Top-Level Item Assembly =======
-- ===========================================

        return {
            title = "Intelligence Artificielle",
            menu  = {
                {
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
                                if state.llm_enabled then
                                    notify("🟢 ACTIVÉ", "Suggestions IA activées.")
                                else
                                    notify("🔴 DÉSACTIVÉ", "Suggestions IA désactivées.")
                                end
                            end,
                            function(needs_ollama)
                                hs.timer.doAfter(0.1, function()
                                    if needs_ollama then
                                        local choice = hs.dialog.blockAlert(
                                            "Installation requise",
                                            "Pour utiliser l’IA, il faut installer Ollama.\n"
                                            .. "Souhaitez-vous procéder" .. NBSP .. "?",
                                            "Installer", "Plus tard", "informational"
                                        )
                                        if choice == "Installer" then
                                            check_system_and_install(state.llm_model, disable_llm)
                                        else
                                            disable_llm()
                                        end
                                    else
                                        check_system_and_install(state.llm_model, disable_llm)
                                    end
                                end)
                            end
                        )
                    end or nil,
                },
                { title = "-" },
                {
                    title    = "Modèle" .. NBSP .. ": " .. state.llm_model,
                    disabled = paused or nil,
                    menu     = models_menu,
                },
                {
                    title    = "Délai avant suggestion IA" .. NBSP .. ": " .. debounce_ms .. " ms…",
                    disabled = paused or nil,
                    fn       = not paused and function()
                        local btn, raw = hs.dialog.textPrompt(
                            "Délai avant suggestion IA",
                            "L’IA s’active après ce temps d’inactivité au clavier (ex: 500 = une demi-seconde).\n\n⚠️ L’IA locale demande beaucoup de ressources :\n• Court (ex: 200) : Très réactif, mais fait chauffer le Mac et vide la batterie.\n• Long (ex: 1000) : Plus discret, préserve l’autonomie et la température.\n\nDélai (en ms)" .. NBSP .. ":",
                            tostring(debounce_ms), "OK", "Annuler"
                        )
                        if btn ~= "OK" then return end
                        local val = tonumber(raw)
                        if not val or val < 0 or val ~= math.floor(val) then
                            hs.notify.new({ title = "Délai invalide",
                                informativeText = "Veuillez saisir un entier ≥ 0." }):send()
                            return
                        end
                        state.llm_debounce = val / 1000
                        if keymap and keymap.set_llm_debounce then
                            keymap.set_llm_debounce(state.llm_debounce)
                        end
                        save_prefs(); update_menu()
                    end or nil,
                },
                { title = "-" },
                {
                    title    = "Paramètres avancés…",
                    disabled = paused or nil,
                    menu     = advanced_menu,
                }
            },
        }
    end

-- ======================================
-- ======================================
-- ======================================
-- ========== 8. STARTUP CHECK ==========
-- ======================================
-- ======================================
-- ======================================

    local function check_startup()
        if not state.llm_enabled then return end
        llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
            hs.timer.doAfter(1, function()
                if needs_ollama then
                    local choice = hs.dialog.blockAlert(
                        "Ollama absent",
                        "Pour utiliser l’IA, il faut installer Ollama.\n"
                        .. "Souhaitez-vous l’installer maintenant" .. NBSP .. "?",
                        "Installer", "Plus tard", "informational"
                    )
                    if choice == "Installer" then
                        check_system_and_install(state.llm_model, disable_llm)
                    else
                        disable_llm()
                    end
                else
                    check_system_and_install(state.llm_model, disable_llm)
                end
            end)
        end)
    end

-- ===================================
-- ===================================
-- ===================================
-- ========== 9. PUBLIC API ==========
-- ===================================
-- ===================================
-- ===================================

    return {
        build_item    = build_item,
        check_startup = check_startup,
    }
end

return M
