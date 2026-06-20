# AUDIT HAMMERSPOON 2026-06-20

## Mission
Auditer le driver ErgoptiPlus Hammerspoon (static/ergopti_plus/macos/) et le BLINDER contre les erreurs asynchrones avalées, les états partagés instables, et les fuites de scope Lua (notamment le problème de la variable locale évaluée à nil global).

## 1. Revue de la Watch-List (`PROJECT_MEMORY.md`)

**Bilan du foot-gun "Closure linked to GLOBAL NIL" :**
La mémoire signalait un incident où `os.remove(tmp_path)` plantait dans un callback de `hs.task` car la variable locale `tmp_path` était déclarée après la closure.
- **Vérification du fix (`api_ollama.lua` et `api_mlx.lua`)** : Le fix est toujours en place. `tmp_path` et `_tmp_base` sont correctement déclarés et résolus *avant* les callbacks asynchrones qui s'en servent.

## 2. Chasse : La "Même Classe" de bug ailleurs

J'ai traqué le même pattern de bug partout où `hs.task.new` ou d'autres callbacks asynchrones sont utilisés et capturent la référence de la tâche courante (par exemple pour gérer l'épinglage Garbage Collector avec `M._active_tasks[task] = nil`).

**Analyse du bug :**
```lua
local task = hs.task.new(..., function()
    -- ERREUR : `task` est évalué au global nil car la déclaration de `local task`
    -- ne prend effet qu'À LA FIN de l'instruction entière.
    M._active_tasks[task] = nil
end)
```
Si la tâche essaie de s'enlever de la table `_active_tasks`, elle fait `_active_tasks[nil] = nil`, ce qui jette l'erreur fatale `table index is nil`. Cette erreur étant levée dans le runtime asynchrone C de Hammerspoon, elle est avalée par le pcall interne de `hs.task` et n'apparaît que dans la console (pas dans le logger Ergopti), créant un blocage fantôme.

**Résultats de la traque :**
J'ai identifié **9 occurrences exactes** de ce bug mortel, réparées via "forward declaration" (`local task; task = hs.task.new(...)`) :

1. `modules/karabiner/onboarding.lua` (4 occurrences)
   - `verify_sha256_async`
   - `download_async`
   - `mount_dmg_async`
   - `run_pkg_with_sudo_async`
2. `ui/menu/menu_apps.lua` (1 occurrence)
   - Lancement d'applications asynchrones
3. `ui/menu/menu_llm/models_manager_mlx.lua` (3 occurrences)
   - Nettoyage asynchrone des serveurs zombies (sweep)
   - Vérification de la disponibilité du port local
   - Terminaison de bash et effacement depuis `deps.active_tasks["mlx_server"] == task` (bug conditionnel qui empêchait la libération du state).
4. `ui/menu/menu_llm/models_manager_ollama.lua` (1 occurrence)
   - Rafraîchissement asynchrone du cache des modèles installés.

**Exceptions saines :**
- `adapters/shell_runner.lua` était déjà protégé contre cette erreur : il déclare `local _task = nil` tout en haut, puis l'affecte avec le résultat de `pcall(hs.task.new, ...)`. Le GC pin release est donc robuste.

## 3. Recommandations et Tests Ajoutés

L'état du Driver Hammerspoon est désormais blindé contre les freezes asynchrones causés par le `nil` scope closure sur `hs.task.new`. Tous les usages instables ont été mis à jour dans le code de production.
