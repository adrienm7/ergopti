# Rapport d'Audit Expert - ErgoptiPlus Hammerspoon

## 1. Introduction & Méthodologie

En tant qu'expert sénior en détection de bugs, j'ai procédé à une analyse approfondie du code source d'ErgoptiPlus (en particulier la partie macOS / Hammerspoon). L'audit a été mené module par module, en examinant attentivement l'interaction asynchrone entre l'event loop de Hammerspoon (Lua monothread) et l'exécution de processus externes, ainsi que la gestion de la mémoire, les race conditions, et la concurrence.

Mes conclusions confirment la présence d'une faille architecturale **critique** qui a été partiellement corrigée dans certaines parties du code, mais reproduite partout ailleurs. Si elle n'est pas traitée, elle causera des comportements aléatoires, des installations échouées et des freezes inexpliqués dans l'interface.

## 2. Découverte Critique : La "Mort Silencieuse" des Processus par le Garbage Collector (GC)

### Le Problème
Hammerspoon implémente `hs.task.new` de manière très spécifique : si l'objet `hs.task` généré par cette fonction n'est pas assigné à une variable persistante (ex: une table globale ou au niveau du module), le **Garbage Collector de Lua le détruira silencieusement lors de son prochain cycle de nettoyage**. 
La destruction de l'objet Lua entraîne l'envoi immédiat d'un signal `SIGTERM` au processus sous-jacent. Étant donné que le GC tourne de façon non déterministe, les tâches asynchrones courtes peuvent parfois survivre, tandis que les plus longues (téléchargements, extractions) échoueront de manière purement aléatoire.

Le composant `adapters/shell_runner.lua` a bien été patché dans le passé pour empêcher cela (grâce à `M._active_tasks[_task] = true`). **Cependant, le reste de la base de code n'utilise pas `ShellRunner.spawn()` et appelle `hs.task.new()` directement avec des variables locales.**

### Fichiers et Lignes Impactés :
J'ai identifié que ce bug est généralisé dans tout le projet :

1. **`macos/ui/menu/menu_about.lua` (lignes 199, 241)** :
   * `local task = hs.task.new("/usr/bin/unzip", ...); task:start()`
   * *Conséquence :* Lors d'une mise à jour logicielle "One-Click", l'extraction du zip via `unzip` peut être tuée au milieu. L'application reste corrompue et le menu affiche "Installation..." indéfiniment.
2. **`macos/ui/menu/menu_llm/models_manager_ollama.lua` (ligne 227)** :
   * `local task = hs.task.new(bin, ... , {"list"})`
   * *Conséquence :* La fonction `refresh_installed_async()` met `_installed_loading = true` (un lock). Si le GC tue la tâche `ollama list`, la fonction de callback n'est jamais appelée, la variable `_installed_loading` reste bloquée à `true` à vie, et l'interface Ollama est définitivement "bloquée".
3. **`macos/ui/menu/menu_llm/models_manager_mlx.lua` (lignes 573, 630...)** :
   * Plusieurs sondes Curl et scripts de nettoyage (sweep) sont lancés de cette manière.
   * *Conséquence :* Des ports peuvent ne pas être libérés car le script de nettoyage bash est tué prématurément par le GC.
4. **`macos/modules/karabiner/onboarding.lua` (lignes 239, 271, 287, 344)** :
   * *Conséquence :* Les téléchargements via `curl` ou l'installation via `hdiutil` échoueront aléatoirement en plein onboarding de l'utilisateur.
5. **`macos/ui/menu/menu_apps.lua` (ligne 246) & `macos/lib/dialog_util.lua` (ligne 64)** :
   * *Conséquence :* Les lancements d'applications utilitaires peuvent échouer de temps à autre.

### 🛠 Comment Fix / Résoudre :
Deux solutions s'offrent à vous, par ordre de préférence :
1. **Remplacer systématiquement tous les appels à `hs.task.new(...)` par `ShellRunner.spawn(...)`.** L'adaptateur a été conçu pour gérer la rétention du GC, il faut donc l'utiliser.
2. Si vous devez utiliser `hs.task.new` (par ex. pour l'API de flux asynchrone non supportée par ShellRunner), assignez toujours la tâche à une table persistante :
   ```lua
   M._active_tasks = M._active_tasks or {}
   local task = hs.task.new(...)
   M._active_tasks[task] = true
   -- Puis, dans le callback de fin de tâche :
   M._active_tasks[task] = nil
   task:start()
   ```

## 3. Revue des correctifs précédents

Durant l'audit, j'ai également vérifié les modules ciblés par les développements antérieurs :
- **`models_manager_ollama.lua` (Concurrence / Freeze UI) :** La boucle de vérification bloquante via `hs.timer.usleep` a bien été remplacée par `hs.timer.doAfter`. L'UI et les "EventTaps" ne sont plus figés durant l'attente du serveur Ollama. **Validé.**
- **`toml_codec/writer.lua` (Écritures concurrentes) :** L'approche atomique utilisant un fichier `.tmp` suivi d'un `os.rename` est propre et empêche la corruption en cas de plantage. **Validé.**
- **`macos/adapters/shell_runner.lua` (Rétention) :** Le root GC a bien été corrigé et nettoyé dynamiquement à la fin des tâches (la mémoire ne fuit plus). **Validé.**

## 4. Analyse des "EventTaps" & Mémoire

Les "EventTaps" créés par `hs.eventtap.new` dans `macos/modules/keymap/init.lua` (pour les raccourcis clavier, gestion du shift et clics de souris) :
- Ils sont assignés à des variables du module (`tap`, `shift_tap`, `mouse_tap`).
- Parce qu'ils sont au niveau de la racine du module, ils ne sont pas éligibles au Garbage Collector. Il n'y a donc pas de fuite mémoire ou de désactivation involontaire de cette partie-là.
- De plus, un `tap_watchdog` a été intelligemment implémenté pour réactiver les taps si macOS les désactive en raison d'un timeout (si l'exécution prend > 300ms).
**Conclusion : le système de touches est robuste et protégé contre les race conditions.**

## 5. Tests de Non-Régression à Implémenter

Pour vous prémunir contre ces dysfonctionnements à l'avenir, implémentez les tests suivants dans la suite de tests (`busted` / Hammerspoon test framework) :

### Test 1 : Stress GC sur les processus asynchrones (Critique)
Ce test doit s'assurer que chaque composant lanceur de tâche maintient une référence forte.
1. Mock la fonction `hs.task.new` pour simuler une tâche très lente (ex: un sleep de 2 secondes).
2. Lancez l'action asynchrone (ex: `refresh_installed_async()` du module Ollama).
3. Au bout de 500ms, forcez explicitement un nettoyage de la mémoire via : `collectgarbage("collect")`.
4. Affirmez (Assert) que la tâche est toujours active et non terminée.
5. Une fois complétée, affirmez que la tâche a bien été enlevée de la table de cache pour ne pas créer de memory leak.

### Test 2 : Deadlock sur un état asynchrone
1. Injectez une fausse erreur dans l'exécution de `unzip` (module `menu_about`).
2. Vérifiez que la variable d'état globale de mise à jour (`Updater.get_update_state()`) passe bien de `"installing"` à `"idle"`.
3. Vérifiez qu'une alerte bloquante est générée et que l'interface ne reste pas verrouillée.
