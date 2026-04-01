--- ui/menu/menu_llm/models_manager_mlx.lua

local M = {}
local notifications = require("lib.notifications")

local ok_dw, download_window = pcall(require, "ui.download_window")
if not ok_dw then download_window = nil end

function M.new(deps, presets)
    local obj = {}
    deps.active_tasks = deps.active_tasks or {}

    function obj.get_mlx_repo(model_name)
        for _, group in ipairs(presets) do
            for _, m in ipairs(group.models) do
                if m.name == model_name then return m.mlx_repo end
            end
        end
        return nil
    end

    function obj.get_installed_models()
        local installed = {}
        local home = os.getenv("HOME")
        local hub_dir = home .. "/.cache/huggingface/hub/"
        for _, group in ipairs(presets) do
            for _, m in ipairs(group.models) do
                if m.mlx_repo then
                    local safe_repo = "models--" .. m.mlx_repo:gsub("/", "--")
                    local snapshots_dir = hub_dir .. safe_repo .. "/snapshots"
                    local attr = hs.fs.attributes(snapshots_dir)
                    if attr and attr.mode == "directory" then
                        local is_valid = false
                        for commit in hs.fs.dir(snapshots_dir) do
                            if commit ~= "." and commit ~= ".." then
                                -- VÉRIFICATION 100% STRICTE :
                                -- Si au moins un fichier .safetensors ou .bin est là, le téléchargement a réussi/partiellement réussi.
                                local commit_dir = snapshots_dir .. "/" .. commit
                                local attr_c = hs.fs.attributes(commit_dir)
                                if attr_c and attr_c.mode == "directory" then
                                    for file in hs.fs.dir(commit_dir) do
                                        if file:match("%.safetensors$") or file:match("%.bin$") then
                                            -- hs.fs.attributes follows symlinks; nil = symlink brisé ou blob absent
                                            local fattr = hs.fs.attributes(commit_dir .. "/" .. file)
                                            if fattr and fattr.size and fattr.size > 10000 then
                                                is_valid = true
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            if is_valid then break end
                        end
                        if is_valid then
                            installed[m.name] = true
                        end
                    end
                end
            end
        end
        return installed
    end

    function obj.start_server(target_model, on_success)
        local repo = obj.get_mlx_repo(target_model)
        if not repo then return end

        -- Arrête le process Lua managé si un autre modèle tournait
        if deps.active_tasks and deps.active_tasks["mlx_server"] then
            local existing = deps.active_tasks["mlx_server"]
            local running = type(existing.isRunning) == "function" and existing:isRunning()
            if running and obj._server_target == target_model then
                -- Même modèle déjà en cours dans cette session Lua → réutilisation
                if on_success then pcall(on_success) end
                return
            end
            if running then pcall(function() existing:terminate() end) end
            deps.active_tasks["mlx_server"] = nil
        end

        -- Cas fréquent : Hammerspoon rechargé, le process Python survit au reload (orphelin).
        -- On probe l'endpoint avant de relancer pour éviter "Address already in use".
        hs.http.asyncGet("http://127.0.0.1:8080/v1/models", {}, function(probe_status, _)
            if probe_status == 200 then
                -- Serveur orphelin actif → on le réutilise directement
                obj._server_target = target_model
                pcall(notifications.notify, "✅ Serveur MLX prêt", target_model .. " est actif.")
                if on_success then pcall(on_success) end
                return
            end

            -- Serveur absent → nettoie tout processus restant sur le port 8080 avant de démarrer
            obj._server_target = target_model
            pcall(notifications.notify, "🚀 Démarrage serveur MLX", "Chargement de " .. target_model .. " en mémoire...")

            local bash_cmd =
                "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; " ..
                "export SSL_CERT_FILE=/etc/ssl/cert.pem; " ..
                "export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem; " ..
                "export HF_HUB_DISABLE_XET=1; " ..
                "export PYTHONUNBUFFERED=1; " ..
                -- Tue les processus mlx_lm orphelins encore attachés au port 8080
                "lsof -tiTCP:8080 -sTCP:LISTEN 2>/dev/null | xargs kill -9 2>/dev/null; sleep 0.3; " ..
                "python3 -m mlx_lm server --model " .. repo

            local task = hs.task.new("/bin/bash", function(code)
                if obj._server_target == target_model then obj._server_target = nil end
                print("MLX server exited with code " .. code)
            end, function(_, stdout, stderr)
                local out = (stdout or "") .. (stderr or "")
                -- Real startup message from mlx_lm ThreadingHTTPServer
                if out:find("Starting httpd at") then
                    pcall(notifications.notify, "✅ Serveur MLX prêt", target_model .. " est actif.")
                    if on_success then pcall(on_success) on_success = nil end
                end
                return true
            end, { "-c", bash_cmd })

            if task then
                deps.active_tasks["mlx_server"] = task
                pcall(function() task:start() end)
            else
                pcall(notifications.notify, "Erreur", "Impossible de démarrer le serveur MLX.")
            end
        end)
    end

    function obj.pull_model(target_model, repo, on_success)
        local function do_cancel()
            local t = deps.active_tasks and deps.active_tasks["download"]
            if t and type(t) == "userdata" and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
        end

        -- Estime la taille de téléchargement depuis presets pour initialiser le total
        -- download_gb = trafic réseau, disk_gb = empreinte finale sur disque
        local estimated_bytes_total = 0
        for _, group in ipairs(presets) do
            for _, m in ipairs(group.models) do
                if m.name == target_model then
                    if type(m.download_gb) == "number" then
                        estimated_bytes_total = math.floor(m.download_gb * 1e9)
                    elseif type(m.disk_gb) == "number" then
                        estimated_bytes_total = math.floor(m.disk_gb * 1e9)
                    elseif type(m.ram_gb) == "number" then
                        -- Fallback : les poids 4bit pèsent ~14% des paramètres en RAM
                        estimated_bytes_total = math.floor(m.ram_gb * 0.14 * 1e9)
                    end
                    break
                end
            end
        end

        local clean_repo = repo:gsub("[%c%s]", "")
        local script_path = "/tmp/hs_mlx_dl_" .. tostring(math.random(1000,9999)) .. ".sh"
        
        local f = io.open(script_path, "w")
        if not f then 
            pcall(notifications.notify, "Erreur", "Écriture du script Bash impossible dans /tmp")
            return 
        end
        f:write("#!/bin/bash\n")
        f:write("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n")
        f:write("export HF_HUB_DISABLE_SYMLINKS_WARNING=1\n")
        f:write("export PYTHONUNBUFFERED=1\n")
        f:write("export HF_HUB_ENABLE_HF_TRANSFER=0\n")
        -- macOS system cert bundle (inclut les certs proxy d'entreprise via MDM)
        f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
        f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
        -- Désactive XetHub (protocole bloqué par les proxies d'entreprise)
        -- XetHub redirige les gros fichiers vers cas-bridge.xethub.hf.co
        f:write("export HF_HUB_DISABLE_XET=1\n")
        -- Nettoyage du cache incomplet EN BASH avant de lancer Python
        -- Évite la race condition : rmtree pendant que snapshot_download écrit
        local safe_repo_bash = "models--" .. clean_repo:gsub("/", "--")
        f:write("HUB_DIR=\"$HOME/.cache/huggingface/hub\"\n")
        f:write("SNAP_DIR=\"$HUB_DIR/" .. safe_repo_bash .. "/snapshots\"\n")
        f:write("HAS_WEIGHTS=0\n")
        f:write("if [ -d \"$SNAP_DIR\" ]; then\n")
        f:write("  for commit_dir in \"$SNAP_DIR\"/*/; do\n")
        f:write("    for wf in \"$commit_dir\"*.safetensors \"$commit_dir\"*.bin; do\n")
        f:write("      [ -s \"$wf\" ] && HAS_WEIGHTS=1 && break 2\n")
        f:write("    done\n")
        f:write("  done\n")
        f:write("fi\n")
        f:write("if [ \"$HAS_WEIGHTS\" = '0' ] && [ -d \"$HUB_DIR/" .. safe_repo_bash .. "\" ]; then\n")
        f:write("  echo 'Cache incomplet détecté, nettoyage...'\n")
        f:write("  rm -rf \"$HUB_DIR/" .. safe_repo_bash .. "\"\n")
        f:write("fi\n")
        f:write("echo 'Démarrage du téléchargement de " .. clean_repo .. "...'\n")
        f:write("python3 -u -c \"\n")
        f:write("import sys, os, threading\n")
        f:write("try:\n")
        f:write("    import truststore\n")
        f:write("    truststore.inject_into_ssl()\n")
        f:write("except Exception:\n")
        f:write("    pass\n")
        f:write("from huggingface_hub import snapshot_download\n")
        f:write("_hub_dir = os.path.expanduser('~/.cache/huggingface/hub')\n")
        f:write("_model_cache = os.path.join(_hub_dir, '" .. safe_repo_bash .. "')\n")
        f:write("_stop_evt = threading.Event()\n")
        f:write("def _size_watcher():\n")
        f:write("    while True:\n")
        f:write("        _total = 0\n")
        f:write("        try:\n")
        f:write("            for _dp, _, _fns in os.walk(_model_cache, followlinks=False):\n")
        f:write("                for _fn in _fns:\n")
        f:write("                    if not _fn.endswith('.lock'):\n")
        f:write("                        _fp = os.path.join(_dp, _fn)\n")
        f:write("                        if not os.path.islink(_fp):\n")
        f:write("                            try: _total += os.path.getsize(_fp)\n")
        f:write("                            except: pass\n")
        f:write("        except: pass\n")
        f:write("        print('__BYTES__:' + str(_total), flush=True)\n")
        f:write("        if _stop_evt.wait(2): break\n")
        f:write("_watcher = threading.Thread(target=_size_watcher, daemon=True)\n")
        f:write("_watcher.start()\n")
        f:write("try:\n")
        f:write("    snapshot_download('" .. clean_repo .. "', max_workers=2)\n")
        f:write("except Exception as e:\n")
        f:write("    err_str = str(e).lower()\n")
        f:write("    if '401' in err_str or '403' in err_str or 'gated' in err_str or 'unauthorized' in err_str:\n")
        f:write("        print('\\n❌ ERREUR : Ce modèle est PRIVÉ (Gated) par son créateur.')\n")
        f:write("        print('Pour le télécharger, vous devez :')\n")
        f:write("        print('1. Créer un compte sur HuggingFace.co et accepter les conditions du modèle.')\n")
        f:write("        print('2. Ouvrir le Terminal de votre Mac et taper : huggingface-cli login')\n")
        f:write("    else:\n")
        f:write("        print('\\n--- ERREUR HUGGINGFACE ---')\n")
        f:write("        import traceback\n")
        f:write("        traceback.print_exc()\n")
        f:write("    _stop_evt.set()\n")
        f:write("    sys.exit(1)\n")
        f:write("_stop_evt.set()\n")
        f:write("\"\n")
        f:write("exit_code=$?\n")
        f:write("if [ $exit_code -eq 0 ]; then\n")
        f:write("  echo 'Terminé !'\n")
        f:write("fi\n")
        f:write("exit $exit_code\n")
        f:close()
        
        os.execute("chmod +x " .. script_path)

        if download_window then 
            pcall(download_window.show, target_model, do_cancel, script_path) 
        end
        pcall(deps.update_icon, "📥 MLX")
        
        local _bytes_done, _bytes_total = 0, estimated_bytes_total
        local _current_pct = 0

        local last_progress_time = os.time()
        local function reset_timeout()
            last_progress_time = os.time()
        end
        local function check_timeout()
            if deps.active_tasks and deps.active_tasks["download"] then
                if os.difftime(os.time(), last_progress_time) > 300 then -- 5 minutes sans progrès
                    pcall(notifications.notify, "⏳ Téléchargement MLX bloqué", "Aucun progrès détecté depuis 5 minutes. Abandon.")
                    if download_window then pcall(download_window.complete, false, target_model) end
                    pcall(function() deps.active_tasks["download"]:terminate() end)
                    deps.active_tasks["download"] = nil
                else
                    hs.timer.doAfter(60, check_timeout)
                end
            end
        end
        hs.timer.doAfter(60, check_timeout)

        local task = hs.task.new(script_path, function(code)
            if deps.active_tasks then deps.active_tasks["download"] = nil end
            pcall(deps.update_icon)
            
            if code == 15 then
                pcall(notifications.notify, "🛑 Annulé", "Téléchargement de " .. target_model .. " interrompu.")
                if download_window then pcall(download_window.complete, false, target_model) end
                return
            end

            if code == 0 then
                pcall(notifications.notify, "🟢 MODÈLE MLX INSTALLÉ", target_model .. " est prêt !")
                if download_window then pcall(download_window.complete, true, target_model) end
                deps.state.llm_model = target_model
                if deps.keymap and type(deps.keymap.set_llm_model) == "function" then pcall(deps.keymap.set_llm_model, target_model) end
                pcall(deps.save_prefs)
                obj.start_server(target_model, function() 
                    if on_success then pcall(on_success) else pcall(hs.reload) end 
                end)
            else
                if download_window then pcall(download_window.complete, false, target_model) end
                pcall(notifications.notify, "❌ Échec MLX", "Vérifiez les logs dans la fenêtre.")
            end
        end, function(_, stdout, stderr)
            local out = (stdout or "") .. (stderr or "")
            local found_progress = false

            local function parse_hf_size(s)
                if not s then return nil end
                local val, unit = s:match("([%d%.]+)([kMGT]?B)")
                val = tonumber(val)
                if not val then return nil end
                if unit == "GB" then return val * 1e9
                elseif unit == "MB" then return val * 1e6
                elseif unit == "kB" then return val * 1e3 end
                return val
            end

            -- Source principale : thread Python qui scanne le cache disque toutes les 2 secondes
            local b_str = out:match("__BYTES__:(%d+)")
            if b_str then
                local b = tonumber(b_str)
                if b and b > _bytes_done then
                    _bytes_done = b
                    found_progress = true
                end
            end

            -- Calcule le % uniquement à partir des octets, jamais depuis la barre fichiers
            if _bytes_total > 0 then
                _current_pct = math.min(99, math.floor(_bytes_done / _bytes_total * 100))
            end

            if found_progress then reset_timeout() end
            if download_window and out ~= "" then
                local last_line = ""
                for line in out:gmatch("([^\n\r]+)") do
                    last_line = line
                end
                local clean_line = last_line:gsub("[%r%n]", "")
                pcall(download_window.update, _current_pct, _bytes_done, _bytes_total, clean_line)
            end
            if _current_pct > 0 then pcall(deps.update_icon, "📥 " .. _current_pct .. "%") end
            return true
        end)
        
        if task then
            deps.active_tasks["download"] = task
            pcall(function() task:start() end)
        end
    end

    function obj.check_requirements(target_model, on_success, on_cancel)
        if not target_model or target_model == "" then 
            if type(on_success) == "function" then on_success() end
            return 
        end

        local function do_check()
            local installed = obj.get_installed_models()
            if installed[target_model] then
                obj.start_server(target_model, on_success)
            else
                local repo = obj.get_mlx_repo(target_model)
                if not repo then 
                    pcall(notifications.notify, "❌ Modèle MLX non disponible", "Ce modèle n’est pas compatible MLX ou n’a pas de dépôt MLX configuré.")
                    if on_cancel then on_cancel() end 
                    return 
                end
                
                if type(deps.shared_system_check) == "function" then
                    deps.shared_system_check(target_model, "Apple MLX", repo, function()
                        obj.pull_model(target_model, repo, on_success)
                    end, on_cancel)
                else
                    obj.pull_model(target_model, repo, on_success)
                end
            end
        end

        local check_task = hs.task.new("/bin/bash", function(code)
            if code == 0 then
                do_check()
            else
                local function cancel_install()
                    local t = deps.active_tasks and deps.active_tasks["install"]
                    if t and type(t) == "userdata" and type(t.terminate) == "function" then pcall(function() t:terminate() end) end
                end

                local script_path = "/tmp/hs_mlx_deps.sh"
                local f = io.open(script_path, "w")
                if not f then return end
                f:write("#!/bin/bash\n")
                f:write("export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\n")
                f:write("export SSL_CERT_FILE=/etc/ssl/cert.pem\n")
                f:write("export REQUESTS_CA_BUNDLE=/etc/ssl/cert.pem\n")
                f:write("export PIP_CERT=/etc/ssl/cert.pem\n")
                f:write("export HF_HUB_DISABLE_XET=1\n")
                f:write("echo 'Installation des dépendances MLX...'\n")
                f:write("python3 -u -m pip install --user mlx-lm huggingface_hub truststore\n")
                f:close()
                os.execute("chmod +x " .. script_path)

                if download_window then 
                    pcall(download_window.show, "Dépendances MLX", cancel_install, script_path) 
                end

                local install_task = hs.task.new(script_path, function(icode)
                    if deps.active_tasks then deps.active_tasks["install"] = nil end
                    os.remove(script_path)
                    
                    if icode == 15 then
                        pcall(notifications.notify, "🛑 Annulé", "Installation interrompue.")
                        if download_window then pcall(download_window.complete, false, "Dépendances") end
                        if on_cancel then on_cancel() end
                        return
                    end

                    if icode == 0 then
                        if download_window then pcall(download_window.complete, true, "Dépendances") end
                        hs.timer.doAfter(1.5, do_check)
                    else
                        pcall(notifications.notify, "Erreur", "Échec de l'installation des dépendances.")
                        if download_window then pcall(download_window.complete, false, "Dépendances") end
                        if on_cancel then on_cancel() end
                    end
                end, function(_, stdout, stderr)
                    local out = (stdout or "") .. (stderr or "")
                    if download_window and out ~= "" then
                        pcall(download_window.update, 0, nil, nil, out:gsub("[%r%n]", ""))
                    end
                    return true
                end)
                
                if install_task then
                    deps.active_tasks["install"] = install_task
                    pcall(function() install_task:start() end)
                end
            end
        end, {"-c", "export PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"; python3 -c 'import mlx_lm; import huggingface_hub; import truststore; import jinja2; import safetensors'"})
        
        pcall(function() check_task:start() end)
    end

    function obj.delete_model(model_name)
        if not model_name or model_name == "" then return end
        local repo = obj.get_mlx_repo(model_name)
        if not repo then return end
        local home = os.getenv("HOME")
        local safe_repo = "models--" .. repo:gsub("/", "--")
        local path = home .. "/.cache/huggingface/hub/" .. safe_repo
        os.execute("rm -rf " .. path)
        pcall(notifications.notify, "🗑️ Supprimé (MLX)", model_name)
        pcall(deps.update_menu)
    end

    return obj
end

return M
