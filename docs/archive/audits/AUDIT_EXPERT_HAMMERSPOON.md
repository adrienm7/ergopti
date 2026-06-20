# Audit Profond et Détection de Bugs - ErgoptiPlus (Hammerspoon/Lua)

Cet audit a été réalisé en analysant minutieusement le code source de l'intégration Hammerspoon (`macos/` et `_shared/lua/`). En se concentrant sur les spécificités du moteur Lua de Hammerspoon, de la gestion asynchrone, et des événements système, plusieurs bugs critiques ont été détectés, dont des suppressions silencieuses de tâches, le gel de la boucle d'événements, et des risques majeurs de perte de données.

Voici les découvertes détaillées, les correctifs recommandés, et les tests de non-régression à implémenter.

---

## 1. Module `ShellRunner` (Critique - Exécutions Silencieusement Tuées)

### 1.1 Tâches Système (Tasks) victimes du Garbage Collector
**Fichier :** `macos/adapters/shell_runner.lua`
**Le problème :** La méthode `ShellRunner.spawn()` instancie un `hs.task` et le retourne enveloppé dans une table Lua `handle`. Dans le code appelant (par exemple, `kill_task` ou `curl_task` dans `api_mlx.lua`, `kill_handle` et `serve_handle` dans `api_ollama.lua`), le retour est assigné à une variable locale (`local kill_task = ...`). Une fois que `.start()` est appelé, la variable locale sort du scope et devient éligible au Garbage Collector (GC) de Lua. 
En Hammerspoon, si l'objet `hs.task` n'est plus référencé globalement, il est détruit par le GC, ce qui **tue instantanément et silencieusement le sous-processus en cours** (le `curl`, la découverte de modèles, ou même le démarrage d'Ollama). Cela rend l'ensemble des appels système asynchrones "flaky" et imprévisibles.
**Le correctif :** `ShellRunner` doit retenir une référence forte aux tâches en cours d'exécution.
```lua
-- adapters/shell_runner.lua
M._active_tasks = {} -- Référence globale pour prévenir le GC

function M.spawn(executable, args, on_done, on_chunk)
	-- [...]
	local function wrapped_on_done(task, exit_code, stdout, stderr)
		M._active_tasks[task] = nil -- Libère la tâche une fois terminée
		if type(on_done) == "function" then
			pcall(on_done, exit_code, stdout, stderr)
		end
	end
	
	local ok, task_or_err
	if type(on_chunk) == "function" then
		ok, task_or_err = pcall(hs.task.new, executable, wrapped_on_done, on_chunk, args)
	else
		ok, task_or_err = pcall(hs.task.new, executable, wrapped_on_done, args)
	end
	
	if ok then 
		_task = task_or_err
		M._active_tasks[_task] = true -- Protège la tâche du GC
	end
	-- [...]
end
```
**Test de non-régression :** Créer un script bash `sleep 5 && touch success.txt`. L'exécuter via `local t = ShellRunner.spawn(...) ; t.start()`. Forcer un appel à `collectgarbage("collect")` immédiatement après. Si `success.txt` n'est pas créé au bout de 5 secondes, c'est que la tâche a été tuée.

---

## 2. Module `Menu LLM` (Critique - Blocage du RunLoop macOS)

### 2.1 Freeze du Thread Principal (`hs.timer.usleep`)
**Fichier :** `macos/ui/menu/menu_llm/models_manager_ollama.lua` (Ligne ~207)
**Le problème :** La fonction `wait_for_ollama_api(retries)` effectue une boucle jusqu'à 20 itérations contenant `hs.timer.usleep(200 * 1000)`. Lua s'exécutant sur le *main thread* (Thread principal) de Hammerspoon, ce `usleep` bloque de manière synchrone l'intégralité de la boucle d'événements pendant potentiellement **4 secondes entières**. 
Ce gel a des conséquences dramatiques : l'interface utilisateur de Hammerspoon freeze (apparition de la roue de la mort / beachball), et les `hs.eventtap` (utilisés pour les Hotstrings et le Keylogger) sont suspendus. Le système macOS risque de désactiver de force le tap clavier, provoquant **l'arrêt définitif de l'enregistrement des touches** jusqu'au prochain rechargement.
**Le correctif :** Ne jamais utiliser `hs.timer.usleep`. Remplacer la boucle synchrone par un polling asynchrone utilisant le module `TimerScheduler`.
```lua
local function wait_for_ollama_api(retries, current_attempt, on_success)
	current_attempt = current_attempt or 1
	-- [Vérification curl non bloquante via HttpClient ou hs.task]
	if success then
		update_progress_ui(100, i18n.get("ollama.service_ready"))
		if on_success then on_success() end
	elseif current_attempt < retries then
		TimerScheduler.after(0.2, function()
			wait_for_ollama_api(retries, current_attempt + 1, on_success)
		end)
	end
end
```
**Test de non-régression :** Ajouter un Linter strict (par exemple via `.luacheckrc` ou une recherche dans la CI) interdisant strictement l'usage du pattern `hs.timer.usleep` dans les composants UI ou les Event Taps.

---

## 3. Module `TOML Codec` et Configuration (Critique - Perte de Données)

### 3.1 Sauvegarde Destructrice et Non-Atomique
**Fichier :** `_shared/lua/toml_codec/writer.lua` (ainsi que `hotstrings_config.lua` et `menu_paths.lua`)
**Le problème :** Lors de l'enregistrement du dictionnaire TOML de l'utilisateur, le script exécute `local ok, fh = pcall(io.open, path, "w")`. Ce mode `"w"` **vide immédiatement le fichier** (troncature à 0 octet). Si une erreur d'écriture survient dans les microsecondes qui suivent, ou si l'utilisateur recharge Hammerspoon à ce moment exact, la configuration complète de l'utilisateur est effacée et irrémédiablement perdue.
Le module `log_manager.lua` gère très bien l'écriture des fichiers `.json` de manière atomique, mais cette sécurité a été oubliée pour les configurations clés.
**Le correctif :** Implémenter le pattern d'écriture atomique via un fichier temporaire :
```lua
local tmp_path = path .. ".tmp"
local ok, fh = pcall(io.open, tmp_path, "w")
if not ok or not fh then return false, "Erreur" end

fh:write(table.concat(L, "\n"))
fh:close()

-- L'opération de déplacement est atomique au niveau de l'OS (POSIX)
os.rename(tmp_path, path)
```
**Test de non-régression :** Mocker `fh:write` pour qu'il jette une erreur (throw). Lancer une sauvegarde du TOML. Assurer que le fichier `.toml` original est resté intact, avec tout son contenu précédent.

---

## 4. Stratégie E2E et Optimisations

1. **Audit des Tâches Asynchrones (hs.task / hs.timer) :** 
   Vérifier systématiquement que tout retour d'appel système ou de timer différé est stocké dans une variable persistante du module et non dans le scope local. Si l'objet est nettoyé, le timer ou le processus est purement et simplement abandonné.
2. **Hammerspoon EventTap Garbage Collection :**
   Dans le fichier `macos/modules/shortcuts/actions/system.lua`, les méthodes comme `bind_layer_scroll` retournent un objet `tap` non assigné à un niveau global, s'attendant à ce que l'appelant (`script_control.lua`) le stocke (ce qui est actuellement le cas). Assurez-vous via les tests E2E que si vous rechargez la configuration dynamiquement, vous libérez bien les anciens EventTaps via `.stop()` pour ne pas accumuler des hooks système fantômes (Memory Leak).
3. **Optimisation WPM :** 
   Le calcul `hs.timer.absoluteTime() / 1000000` est sécuritaire contre le dépassement sur des décennies (contrairement au `A_TickCount` d'AHK). L'ingestion du Keylogger sous Lua est très saine, en grande partie grâce à l'usage intelligent du format JSONL pour contourner les lock SQLite. Aucun blocage I/O n'est à craindre sur le flux de frappe.
