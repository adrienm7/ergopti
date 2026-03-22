-- ui/menu_llm.lua
-- Factory for the LLM (Ollama) menu section.

local M = {}

local llm_mod = require("modules.llm")

local NBSP  = "\194\160"      -- U+00A0
local NNBSP = "\226\128\175"  -- U+202F

-- Default values (mirrors state defaults in menu.lua)
local DEFAULT_LLM_CONTEXT_LENGTH = 500
local DEFAULT_LLM_TEMPERATURE    = 0.1
local DEFAULT_LLM_MAX_PREDICT    = 40

-- ================================
-- ========== 1. FACTORY ==========
-- ================================

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
-- ========== 2. SYSTEM DETECTION ==========
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
-- ========== 3. MODEL REQUIREMENTS ==========
-- ===========================================

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
-- ========== 4. INSTALLATION PIPELINE ==========
-- ==============================================

    local function make_progress_bar(pct)
        local p      = math.max(0, math.min(100, tonumber(pct) or 0))
        local filled = math.floor(p / 10)
        return string.rep("\226\150\160", filled) .. string.rep("\226\150\161", 10 - filled)
    end

    local function pull_model(target_model)
        local ollama_bin = get_ollama_path()
        if not ollama_bin then
            notify("\226\141\140 Ollama introuvable", "Impossible de localiser l'ex\195\169cutable ollama.")
            return
        end

        notify("\226\143\167 T\195\169l\195\169chargement d\195\169marr\195\169", target_model .. " se t\195\169l\195\169charge en arri\195\168re-plan\226\128\166")
        update_icon("\240\159\147\165 D\195\169marrage\226\128\166")

        local task_id = "download"
        local task = hs.task.new(
            ollama_bin,
            function(exit_code, stdout, stderr)
                active_tasks[task_id] = nil
                update_icon(); update_menu()

                if exit_code == 15 then
                    notify("\240\159\155\145 Annul\195\169", "T\195\169l\195\169chargement de " .. target_model .. " interrompu.")
                    return
                end

                local output    = (stdout or "") .. (stderr or "")
                local has_error = output:lower():find("not found") or output:lower():find("error")

                if exit_code == 0 and not has_error then
                    state.llm_model = target_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(target_model) end
                    save_prefs()
                    notify("\240\159\159\162  MOD\195\136LE INSTALL\195\137", target_model .. " est pr\195\170t \195\160 l'emploi.")
                    hs.timer.doAfter(1, hs.reload)
                else
                    notify("\226\141\140 \195\137chec du t\195\169l\195\169chargement", target_model .. " \226\128\148 " .. output:sub(1, 80))
                    hs.dialog.blockAlert(
                        "Erreur de mod\195\168le",
                        "Le mod\195\168le [" .. target_model .. "] n'a pas pu \195\170tre t\195\169l\195\169charg\195\169.\n\n"
                        .. "D\195\169tails" .. NBSP .. ": " .. output:sub(1, 150) .. "\226\128\166",
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
                    update_icon("\240\159\147\165 R\195\169cup\195\169ration\226\128\166")
                end
                return true
            end,
            { "pull", target_model }
        )

        active_tasks[task_id] = task
        update_menu()
        task:start()
    end

    local function install_ollama_then_pull(target_model)
        notify("\195\137tape 1/2" .. NBSP .. ": Installation", "T\195\169l\195\169chargement de l'application Ollama\226\128\166")
        local task_id = "install"
        local task = hs.task.new("/bin/bash", function(code)
            active_tasks[task_id] = nil
            if code == 0 then
                notify("\240\159\159\162 Ollama install\195\169", "Lancement du t\195\169l\195\169chargement du mod\195\168le\226\128\166")
                pull_model(target_model)
            else
                notify("\226\141\140 \195\137chec installation", "L'installation d'Ollama a \195\169chou\195\169.")
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
-- ========== 5. SYSTEM CHECKS ==========
-- ======================================

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
                "\226\154\160\239\184\143 RAM" .. NBSP .. ": %d Go (requiert ~%d Go). Risque de lenteur.",
                sys_ram_gb, req_ram))
        else
            table.insert(warnings, string.format(
                "\240\159\159\162 RAM" .. NBSP .. ": %d Go OK (requiert ~%d Go).", sys_ram_gb, req_ram))
        end

        if free_disk_gb > 0 then
            local remaining = free_disk_gb - req_disk
            if remaining < 2 then
                is_critical = true
                table.insert(warnings, string.format(
                    "\226\141\140 Disque" .. NBSP .. ": seulement %d Go restant apr\195\168s installation. Bloqu\195\169.", remaining))
            elseif remaining < 15 then
                table.insert(warnings, string.format(
                    "\226\154\160\239\184\143 Disque" .. NBSP .. ": %d Go restants (poids" .. NBSP .. ": ~%d Go).",
                    remaining, req_disk))
            else
                table.insert(warnings, string.format(
                    "\240\159\159\162 Disque" .. NBSP .. ": OK (poids" .. NBSP .. ": ~%d Go).", req_disk))
            end
        end

        local msg = "Mod\195\168le cibl\195\169" .. NBSP .. ": " .. target_model .. "\n\n"
                    .. table.concat(warnings, "\n")

        hs.timer.doAfter(0.1, function()
            if is_critical then
                hs.dialog.blockAlert("T\195\169l\195\169chargement bloqu\195\169", msg, "Annuler", nil, "critical")
                if on_cancel then on_cancel() end
                return
            end

            local alert_type = (msg:find("\226\154\160\239\184\143"))
                                and "warning" or "informational"
            local choice = hs.dialog.blockAlert(
                "Installation requise",
                msg .. "\n\nCe mod\195\168le n'est pas install\195\169.\n"
                .. "Voulez-vous lancer le t\195\169l\195\169chargement en arri\195\168re-plan" .. NBSP .. "?",
                "T\195\169l\195\169charger", "Annuler", alert_type
            )

            if choice == "T\195\169l\195\169charger" then
                if get_ollama_path() then pull_model(target_model)
                else install_ollama_then_pull(target_model) end
            else
                if on_cancel then on_cancel() end
            end
        end)
    end

-- =================================================
-- ========== 6. INSTALLED MODELS CATALOG ==========
-- =================================================

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
-- ========== 7. MENU BUILDER ==========
-- =====================================

    local PRESET_GROUPS = {
        { "llama3.2:1b",  "llama3.2",    "llama3.1"     },
        { "qwen2.5:0.5b", "qwen2.5:1.5b","qwen2.5:7b",  "qwen2.5:14b" },
        { "mistral",      "mixtral:8x7b" },
        { "gemma2:2b",    "gemma2",       "gemma2:27b"   },
        { "phi3",         "phi3:14b"      },
    }

    local function build_item()
        local paused      = script_control and script_control.is_paused() or false
        local debounce_ms = math.floor(state.llm_debounce * 1000 + 0.5)
        local default_debounce_ms = math.floor((llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5) * 1000 + 0.5)
        local installed   = get_installed_models()

        -- ======================================
        -- ======= 7.1 Model Switch Logic =======
        -- ======================================

        local function switch_model(new_model)
            notify("\226\143\167 V\195\169rification\226\128\166", "Contr\195\180le du mod\195\168le " .. new_model .. "\226\128\166")

            llm_mod.check_availability(new_model,
                function()
                    state.llm_model = new_model
                    if keymap and keymap.set_llm_model then keymap.set_llm_model(new_model) end
                    save_prefs(); update_menu()
                    notify("\240\159\159\162  MODELE CHANGE", new_model .. " est actif.")
                end,
                function(needs_ollama)
                    hs.timer.doAfter(0.1, function()
                        if needs_ollama then
                            hs.dialog.blockAlert("Ollama absent",
                                "Ollama ne semble pas \195\170tre lanc\195\169 ou install\195\169.", "OK")
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

        if active_tasks["download"] then
            table.insert(models_menu, {
                title = "\240\159\155\145 Annuler le t\195\169l\195\169chargement en cours",
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
                                is_installed and "\240\159\159\162 " or "  ", m, ram),
                    checked = (state.llm_model == m),
                    fn      = not paused and function() switch_model(m) end or nil,
                })
            end
            if i < #PRESET_GROUPS then table.insert(models_menu, { title = "-" }) end
        end

        table.insert(models_menu, { title = "-" })
        table.insert(models_menu, {
            title = "  Autre mod\195\168le (saisie manuelle)\226\128\166",
            fn    = not paused and function()
                local btn, raw = hs.dialog.textPrompt(
                    "Mod\195\168le IA personnalis\195\169",
                    "Entrez le nom exact du mod\195\168le Ollama" .. NBSP .. ":",
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

        local advanced_menu = {}

        -- Context length
        table.insert(advanced_menu, {
            title    = "Contexte" .. NBSP .. ": " .. state.llm_context_length .. " derniers caract\195\168res.",
            disabled = paused or nil,
            fn       = not paused and function()
                local btn, raw = hs.dialog.textPrompt("Longueur du contexte",
                    "Entrez le nombre de caract\195\168res gard\195\169s en m\195\169moire (ex\194\160: 500)" .. NBSP .. ":",
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
            title    = "   \226\134\179 R\195\169initialiser (d\195\169faut" .. NBSP .. ": " .. DEFAULT_LLM_CONTEXT_LENGTH .. ")",
            disabled = (paused or state.llm_context_length == DEFAULT_LLM_CONTEXT_LENGTH) or nil,
            fn       = (not paused and state.llm_context_length ~= DEFAULT_LLM_CONTEXT_LENGTH) and function()
                state.llm_context_length = DEFAULT_LLM_CONTEXT_LENGTH
                if keymap and keymap.set_llm_context_length then
                    keymap.set_llm_context_length(state.llm_context_length)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(advanced_menu, { title = "-" })

        -- Reset on nav
        table.insert(advanced_menu, {
            title    = "Reset contexte sur clic/fl\195\168ches",
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

        -- Temperature
        table.insert(advanced_menu, {
            title    = "Temp\195\169rature" .. NBSP .. ": " .. state.llm_temperature,
            disabled = paused or nil,
            fn       = not paused and function()
                local btn, raw = hs.dialog.textPrompt("Temp\195\169rature du LLM",
                    "Nombre d\195\169cimal entre 0.0 (pr\195\169visible) et 1.0 (cr\195\169atif)" .. NBSP .. ":",
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
            title    = "   \226\134\179 R\195\169initialiser (d\195\169faut" .. NBSP .. ": " .. DEFAULT_LLM_TEMPERATURE .. ")",
            disabled = (paused or state.llm_temperature == DEFAULT_LLM_TEMPERATURE) or nil,
            fn       = (not paused and state.llm_temperature ~= DEFAULT_LLM_TEMPERATURE) and function()
                state.llm_temperature = DEFAULT_LLM_TEMPERATURE
                if keymap and keymap.set_llm_temperature then
                    keymap.set_llm_temperature(state.llm_temperature)
                end
                save_prefs(); update_menu()
            end or nil,
        })

        table.insert(advanced_menu, { title = "-" })

        -- Max predict
        table.insert(advanced_menu, {
            title    = "Longueur max. de pr\195\169diction" .. NBSP .. ": " .. state.llm_max_predict .. " tokens",
            disabled = paused or nil,
            fn       = not paused and function()
                local btn, raw = hs.dialog.textPrompt("Pr\195\169diction maximale",
                    "Nombre maximum de mots/tokens g\195\169n\195\169r\195\169s par l'IA (ex\194\160: 40)" .. NBSP .. ":",
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
            title    = "   \226\134\179 R\195\169initialiser (d\195\169faut" .. NBSP .. ": " .. DEFAULT_LLM_MAX_PREDICT .. " tokens)",
            disabled = (paused or state.llm_max_predict == DEFAULT_LLM_MAX_PREDICT) or nil,
            fn       = (not paused and state.llm_max_predict ~= DEFAULT_LLM_MAX_PREDICT) and function()
                state.llm_max_predict = DEFAULT_LLM_MAX_PREDICT
                if keymap and keymap.set_llm_max_predict then
                    keymap.set_llm_max_predict(state.llm_max_predict)
                end
                save_prefs(); update_menu()
            end or nil,
        })

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
                                    notify("\240\159\159\162 ACTIV\195\137", "Suggestions IA activ\195\169es.")
                                else
                                    notify("\240\159\148\180 D\195\137SACTIV\195\137", "Suggestions IA d\195\169sactiv\195\169es.")
                                end
                            end,
                            function(needs_ollama)
                                hs.timer.doAfter(0.1, function()
                                    if needs_ollama then
                                        local choice = hs.dialog.blockAlert(
                                            "Installation requise",
                                            "Pour utiliser l'IA, il faut installer Ollama.\n"
                                            .. "Souhaitez-vous proc\195\169der" .. NBSP .. "?",
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
                    title    = "Mod\195\168le" .. NBSP .. ": " .. state.llm_model,
                    disabled = paused or nil,
                    menu     = models_menu,
                },
                {
                    title    = "D\195\169lai avant suggestion IA" .. NBSP .. ": " .. debounce_ms .. " ms\226\128\166",
                    disabled = paused or nil,
                    fn       = not paused and function()
                        local btn, raw = hs.dialog.textPrompt(
                            "D\195\169lai avant suggestion IA",
                            "L'IA s'active apr\195\168s ce temps d'inactivit\195\169 au clavier (ex\194\160: 500 = une demi-seconde).\n\n"
                            .. "\226\154\160\239\184\143 L'IA locale demande beaucoup de ressources\194\160:\n"
                            .. "\226\128\162 Court (ex\194\160: 200)\194\160: Tr\195\168s r\195\169actif, mais fait chauffer le Mac et vide la batterie.\n"
                            .. "\226\128\162 Long (ex\194\160: 1000)\194\160: Plus discret, pr\195\169serve l'autonomie et la temp\195\169rature.\n\n"
                            .. "D\195\169lai (en ms)" .. NBSP .. ":",
                            tostring(debounce_ms), "OK", "Annuler"
                        )
                        if btn ~= "OK" then return end
                        local val = tonumber(raw)
                        if not val or val < 0 or val ~= math.floor(val) then
                            hs.notify.new({ title = "D\195\169lai invalide",
                                informativeText = "Veuillez saisir un entier \226\137\165 0." }):send()
                            return
                        end
                        state.llm_debounce = val / 1000
                        if keymap and keymap.set_llm_debounce then
                            keymap.set_llm_debounce(state.llm_debounce)
                        end
                        save_prefs(); update_menu()
                    end or nil,
                },
                -- Reset debounce to default
                {
                    title    = "   \226\134\179 R\195\169initialiser (d\195\169faut" .. NBSP .. ": " .. default_debounce_ms .. " ms)",
                    disabled = (paused or debounce_ms == default_debounce_ms) or nil,
                    fn       = (not paused and debounce_ms ~= default_debounce_ms) and function()
                        state.llm_debounce = llm_mod.DEFAULT_LLM_DEBOUNCE or 0.5
                        if keymap and keymap.set_llm_debounce then
                            keymap.set_llm_debounce(state.llm_debounce)
                        end
                        save_prefs(); update_menu()
                    end or nil,
                },
                { title = "-" },
                {
                    title    = "Param\195\168tres avanc\195\169s\226\128\166",
                    disabled = paused or nil,
                    menu     = advanced_menu,
                },
            },
        }
    end

-- ======================================
-- ========== 8. STARTUP CHECK ==========
-- ======================================

    local function check_startup()
        if not state.llm_enabled then return end
        llm_mod.check_availability(state.llm_model, nil, function(needs_ollama)
            hs.timer.doAfter(1, function()
                if needs_ollama then
                    local choice = hs.dialog.blockAlert(
                        "Ollama absent",
                        "Pour utiliser l'IA, il faut installer Ollama.\n"
                        .. "Souhaitez-vous l'installer maintenant" .. NBSP .. "?",
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

    return {
        build_item    = build_item,
        check_startup = check_startup,
    }
end

return M
