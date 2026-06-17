# Rapport d'Audit Expert - ErgoptiPlus Hammerspoon

Ce rapport contient une analyse extrêmement fine et approfondie de la base de code ErgoptiPlus (particulièrement la version macOS Hammerspoon et les modules partagés). Il met en lumière des bugs critiques, des conditions de course (race conditions), des fuites de mémoire (memory/watcher leaks), des comportements inattendus, ainsi que des goulots d'étranglement de performance.

Pour chaque découverte, une explication du bug, le correctif à appliquer (code snippet) et des tests de non-régression à implémenter sont fournis.

---

## 1. Conditions de course (Race Conditions) et Async

### 1.1. Désynchronisation de la frappe asynchrone (`keymap/init.lua`)

**Découverte (Le bug) :**
Dans les fenêtres ignorées, les déclencheurs de hotstrings sont évalués de manière asynchrone via `hs.timer.doAfter(0, ...)` pour éviter de bloquer les événements natifs de l'OS. Bien que la closure capture correctement la touche frappée, elle ne capture **pas** l'état du buffer (`CoreState.buffer`). Étant donné que `Expander.try_auto_expand` lit `CoreState.buffer` de manière synchrone, si un utilisateur tape très rapidement (ex: tape "A" puis "B"), le buffer avance avant que le timer de "A" ne s'exécute. L'extenseur vérifiera alors la *nouvelle* fin du buffer ("B") et échouera à faire correspondre "A". Pire encore, s'il trouve une correspondance erronée, les retours arrière (backspaces) effaceront les mauvais caractères.

**Comment corriger :**
Capturer un *snapshot* du buffer au moment où la touche est interceptée, et le substituer temporairement lors de l'exécution asynchrone. Si l'expansion modifie le buffer, il faut fusionner les nouveaux caractères qui ont pu arriver pendant l'attente.

```lua
if is_ignored then
    local snap_buf = CoreState.buffer
    hs.timer.doAfter(0, (function(chars, len, dt, mult, ign, snap)
        return function()
            local real_buf = CoreState.buffer
            CoreState.buffer = snap
            
            _tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored = chars, len, dt, mult, ign
            run_trigger_checks()
            
            -- Si l'Expander a muté le buffer, on restaure la mutation + on ajoute ce qui a été tapé entre temps
            if CoreState.buffer ~= snap then
                local suffix = real_buf:sub(#snap + 1)
                CoreState.buffer = CoreState.buffer .. suffix
            else
                CoreState.buffer = real_buf
            end
        end
    end)(_tc_chars, _tc_char_len, _tc_dt, _tc_complex_mult, _tc_is_ignored, snap_buf))
```

**Tests de non-régression à implémenter :**
- **Test de Stabilité de Buffer Async :** Simuler une frappe asynchrone à haute fréquence (ex: `a` suivi immédiatement de `b` et `c`) dans une fenêtre ignorée avec un alias `a` -> `foo`. Vérifier que l'expansion se déclenche pour `a`, ne supprime ni `b` ni `c`, et que le buffer final soit bien `foobc`.

---

## 2. Fuites de mémoire et de watchers (Memory & Tap Leaks)

### 2.1. Fuites massives de callbacks `hs.window.filter` (`keymap/utils.lua` et `llm_bridge.lua`)

**Découverte (Le bug) :**
Le cycle de vie des watchers n'est pas complètement nettoyé lorsque le module est arrêté/rechargé.
1. Dans `keymap/utils.lua`, `ensure_ignored_win_watchers` s'abonne au filtre global `hs.window.filter.default` mais ne s'en désabonne jamais. Comme c'est un objet global partagé, chaque rechargement de module (reload) ajoute un callback dupliqué, créant une fuite de mémoire et une chute drastique des performances au fil du temps.
2. Dans `llm_bridge.lua`, le tap `_escape_trap` n'est pas stoppé lors d'un `M.stop()`. S'il est actif et que le module keymap est arrêté, il interceptera la touche Échap de façon permanente et "fantôme".

**Comment corriger :**
Exposer des méthodes `stop()` dans les sous-modules et les appeler.

```lua
-- Dans llm_bridge.lua :
function M.stop()
    if _escape_trap then
        _escape_trap:stop()
        _escape_trap = nil
    end
end

-- Dans utils.lua :
function M.stop()
    if _ignored_win_app_watcher then
        _ignored_win_app_watcher:stop()
        _ignored_win_app_watcher = nil
    end
    if _ignored_win_win_filter then
        _ignored_win_win_filter:unsubscribe(invalidate_ignored_win_cache)
        _ignored_win_win_filter = nil
    end
end

-- Appeler le tout depuis keymap/init.lua :
function M.stop()
    -- ...
    LLMBridge.stop()
    km_utils.stop()
end
```

**Tests de non-régression à implémenter :**
- Lancer `keymap.start()` et `keymap.stop()` 10 fois de suite. Affirmer que le nombre de callbacks enregistrés sur `hs.window.filter.default` n'augmente pas et que la touche Échap fonctionne normalement quand stoppé.

### 2.2. Watchers "Fantômes" dans Gestures (`gestures/init.lua`)

**Découverte (Le bug) :**
Dans `gestures/init.lua`, `hs.timer.doAfter` est utilisé pour lancer la `STARTUP_SAFETY_PROBE_SEC`. Si le module est arrêté (`gestures.stop()`) avant la fin du timer, ce dernier s'exécutera quand même. `recycle_watchers()` sera alors invoqué *après* que le module ait été stoppé, faisant "ressusciter" des watchers qui tourneront en arrière-plan et exécuteront des méthodes potentiellement erronées.

**Comment corriger :**
Ajouter une vérification de l'état du module dans les callbacks asynchrones.

```lua
hs.timer.doAfter(STARTUP_SAFETY_PROBE_SEC, function()
    if not CoreState.enabled or _G.ERGOPTI_GESTURES_RECEIVED_FIRST_FRAME then return end
    kickstart_hid()
    recycle_watchers()
end)
```

**Tests de non-régression à implémenter :**
- Appeler `gestures.start()` suivi immédiatement de `gestures.stop()`. Attendre la durée du délai de *safety probe* et vérifier qu'aucun watcher lié à la *trackpad* ne se réveille.

---

## 3. Comportements inattendus et Crashs potentiels

### 3.1. Risque de crash fatal au démarrage (`init.lua`)

**Découverte (Le bug) :**
Dans `static/ergopti_plus/macos/init.lua`, la fonction `hs.fs.dir(hotstrings_dir)` est appelée de façon synchrone sans `pcall`. Si ce dossier est supprimé ou corrompu (permissions système), cela lève une erreur Lua native qui fera crasher silencieusement et définitivement tout le processus d'initialisation de Hammerspoon. 

**Comment corriger :**
```lua
local ok_dir, dir_iter = pcall(hs.fs.dir, hotstrings_dir)
if ok_dir then
    for fname in dir_iter do
        -- ...
    end
else
    Logger.error(LOG, "Impossible d'accéder au dossier hotstrings : %s", tostring(hotstrings_dir))
end
```

### 3.2. Disparition silencieuse des callbacks de l'API LLM (`llm/api_mlx.lua`)

**Découverte (Le bug) :**
Dans `api_mlx.lua`, lors du "discovery" des endpoints MLX, la fonction gère une pile de callbacks asynchrones : `_discovery_pending_callbacks`. Cependant, lors de la finition de cette procédure (`finish_discovery`), la fonction écrase intentionnellement TOUS les callbacks sauf le tout dernier (`cbs[#cbs]`). 
*Conséquence :* Si deux processus / sous-systèmes différents (ex: UI Menu et Moteur de Prédiction) tentent un "warmup" pendant que le serveur démarre, l'un des deux sera jeté à la poubelle silencieusement. Le verrou `_warmup_in_flight` restera potentiellement bloqué à `true` indéfiniment si le callback d'annulation a été détruit.

**Comment corriger :**
Au lieu de supprimer les callbacks précédents, itérer sur tous pour leur fournir le statut de réussite.

```lua
local function finish_discovery(success)
    _endpoint_probe_in_flight = false
    -- ...
    local cbs = _discovery_pending_callbacks
    _discovery_pending_callbacks = {}
    for _, cb in ipairs(cbs) do
        pcall(cb, success)
    end
end
```

**Tests de non-régression à implémenter :**
- Lancer simultanément deux requêtes `discover_endpoints` avec deux fonctions de callback distinctes. Mocker la réponse HTTP et affirmer que les DEUX callbacks ont bien été appelés.

### 3.3. Clics synthétiques bloqués (`gestures/init.lua`)

**Découverte (Le bug) :**
`gestures.stop()` n'appelle pas `Actions.force_cleanup()`. Si l'utilisateur est en train de maintenir un clic artificiel actif (via une gesture type `left_click_toggle`) lorsque le module s'arrête (ou lors d'un *reload*), l'OS reste coincé avec un clic de souris virtuel indéfiniment enfoncé.

**Comment corriger :**
```lua
function M.stop()
    CoreState.enabled = false
    if Actions and type(Actions.force_cleanup) == "function" then
        pcall(Actions.force_cleanup)
    end
    -- ...
end
```

---

## 4. Optimisations des performances

### 4.1. Mutation partagée de tables et corruption d'axes (`gestures/engine.lua`)

**Découverte (Le bug) :**
Dans `gestures/engine.lua`, les positions sont assignées par référence de table : `gs.startPos = pos; gs.lastFirePos = pos`. Lorsque le nombre de doigts change (ex: pose d'un nouveau doigt), la compensation modifie `gs.startPos.x` en place. Étant donné qu'il s'agit du **même** objet en mémoire, `gs.lastFirePos.x` est muté involontairement. Le suivi des axes s'en trouve totalement corrompu, déclenchant des *reversals* (changements de direction) imaginaires.

**Comment corriger :**
Cloner systématiquement les tables de coordonnées lors de l'assignation.
```lua
gs.startPos    = {x = pos.x, y = pos.y}
gs.lastFirePos = {x = pos.x, y = pos.y}
-- Et appliquer la compensation de saut séparément
if n ~= gs.lastN and gs.endPos then
    local jumpX = pos.x - gs.endPos.x
    local jumpY = pos.y - gs.endPos.y
    gs.startPos.x = gs.startPos.x + jumpX
    -- gs.lastFirePos doit aussi sauter, mais de façon isolée
    if gs.lastFirePos then
        gs.lastFirePos.x = gs.lastFirePos.x + jumpX
    end
end
```

### 4.2. Goulot d'étranglement O(N) sur l'extraction des suffixes (`hotstring_engine/init.lua`)

**Découverte (Le bug) :**
Dans la boucle principale pure-Lua évaluant les frappes `engine:on_char()`, la méthode `tail_codepoints(_buf_cps, tlen)` extrait la fin du buffer pour le comparer au déclencheur. Cette opération très lourde alloue un nouveau tableau et concatène une chaîne pour *chaque* déclencheur du "bucket" actif (qui peut en contenir des dizaines). C'est un goulot d'étranglement majeur ($O(N)$ par bucket pour chaque frappe).

**Comment corriger :**
Mémoïser l'extraction des fins de buffers par **taille**. Plusieurs hotstrings ont la même taille, il ne faut appeler `tail_codepoints` qu'une seule fois par longueur pour chaque itération de la boucle de frappe.

```lua
local buf_len = #_buf_cps
local tail_cache = {}

for _, mapping in ipairs(bucket) do
    local tlen = mapping.tlen
    if buf_len >= tlen then
        local buf_tail = tail_cache[tlen]
        if not buf_tail then
            buf_tail = tail_codepoints(_buf_cps, tlen)
            tail_cache[tlen] = buf_tail
        end
        -- ...
```

## 5. Intégration Karabiner et Shortcuts

### 5.1. Touches modificatrices bloquées durant le "Bridging" (`shortcuts/script_control.lua`)

**Découverte (Le bug) :**
Lorsque l'utilisateur bascule l'état de pause du script (via `AltGr+Enter`) ou force un rechargement (`AltGr+Backspace`), il maintient physiquement la touche `Right Command` enfoncée. Pendant ce temps, Karabiner-Elements permute sa configuration active (passant des règles Ergopti aux règles natives). 
Puisque la touche est maintenue pendant ce "swap", Karabiner change sa logique de remapping en cours de frappe : macOS reçoit un évènement `keyDown` pour l'ancien mapping, mais lors du relâchement, Karabiner envoie un évènement `keyUp` pour le *nouveau* mapping.
Conséquence : le modificateur d'origine reste coincé à l'état "ENFONCÉ" dans macOS jusqu'à ce que l'utilisateur retape manuellement cette même touche. De plus, `script_control.lua` n'intercepte que les évènements `keyDown`, laissant les `keyUp` passer à travers de manière asymétrique.

**Comment corriger :**
Intercepter à la fois les `keyDown` et `keyUp`, et forcer la réinitialisation des modificateurs de l'OS via `hs.eventtap.keyModifiers({})` juste avant de déclencher l'action de swap.

```lua
-- Hook both keyDown and keyUp
local ok, new_tap = pcall(hs.eventtap.new, {
    hs.eventtap.event.types.keyDown, 
    hs.eventtap.event.types.keyUp
}, handle_key)

-- Inside handle_key: Consume both, but only dispatch on down
local is_down = (e:getType() == hs.eventtap.event.types.keyDown)

if code == KEYCODE_BACKSPACE_SENTINEL then
    if is_down then
        log_shortcut_if_available("Alt+Backspace")
        -- Clear modifiers to prevent stuck state during config swap
        hs.eventtap.keyModifiers({})
        dispatch_action(_key_actions.backspace)
    end
    return true
end
```

**Tests de non-régression à implémenter :**
- **Test de Relâchement au Swap :** Maintenir `Right Command`, presser `Backspace` pour déclencher un rechargement. Vérifier via `hs.eventtap.checkKeyboardModifiers()` qu'aucun modificateur ne reste coincé artificiellement une fois l'opération terminée.

### 5.2. Fuites de raccourcis clavier et Taps orphelins (`shortcuts/script_control.lua` & `keyboard_shortcuts.lua`)

**Découverte (Le bug) :**
Si les fonctions `start()` des modules shortcuts sont appelées plusieurs fois (par exemple lors d'un hot-reload non protégé), elles créent de nouvelles instances de watchers sans détruire les anciennes. 
- Dans `script_control.lua`, `M.start()` écrase inconditionnellement la variable locale `_tap`. L'ancien event tap continue de tourner indéfiniment en arrière-plan, dupliquant toutes les interceptions (ex: deux pauses simultanées).
- Dans `keyboard_shortcuts.lua`, `M.start()` boucle sur les `_actions` et lie les hotkeys sans `unbind` les précédents, laissant des objets `hs.hotkey` actifs en orbite.

**Comment corriger :**
Ajouter des gardes (guards) vérifiant si le module a déjà démarré avant de tout réinstancier.

```lua
-- Dans shortcuts/script_control.lua :
function M.start(...)
    if _tap then
        Logger.warn(LOG, "script_control already started — ignoring.")
        return
    end
    -- ...
end

-- Dans shortcuts/keyboard_shortcuts.lua :
function M.start()
    if _started then
        Logger.warn(LOG, "Keyboard shortcuts already started — ignoring.")
        return
    end
    -- ...
end
```

### 5.3. Processus CapsWord fantôme (Race condition async dans `karabiner/watchers.lua`)

**Découverte (Le bug) :**
Dans `watchers.lua`, `deactivate_capsword()` installe un verrou (`_capsword_check_pending = true`) avant de lancer le CLI de Karabiner de manière asynchrone pour éviter de spammer le CLI à chaque micro-mouvement de trackpad. Cependant, il enchaîne immédiatement `:start()` sur la tâche hs.task. Si `hs.task:start()` échoue de façon synchrone (ex: binaire introuvable, permissions refusées), le callback asynchrone ne sera **jamais** exécuté. Le verrou restera donc sur `true` pour toute la session, empêchant définitivement CapsWord de se désactiver au trackpad.

**Comment corriger :**
Évaluer la valeur de retour de `:start()` et relâcher le verrou en cas d'échec d'instanciation.

```lua
local task = hs.task.new(KARABINER_CLI, function(exit_code, stdout, _)
    _capsword_check_pending = false
    -- ...
end, {"--get-variable", "capsword"})

if not task:start() then
    _capsword_check_pending = false
    Logger.error(LOG, "Failed to start CapsWord check task.")
end
```

### 5.4. Écrasement d'état global du layout clavier (`karabiner/watchers.lua`)

**Découverte (Le bug) :**
Dans `karabiner/watchers.lua`, la fonction `M.stop_input_source_watcher()` exécute brutalement `hs.keycodes.inputSourceChanged(nil)`. 
Hammerspoon ne maintient qu'un seul et unique callback global pour l'évènement de changement de source d'entrée (input source). Mettre ceci à `nil` écrase silencieusement et détruit n'importe quel autre script tiers ou module Ergopti qui aurait pu légitimement s'abonner à ce même évènement.

**Comment corriger :**
Il faudrait au minimum stocker la référence au callback préexistant lors du démarrage, et la restaurer à l'arrêt.

```lua
-- Au démarrage :
_old_input_callback = hs.keycodes.inputSourceChanged(function() ... end)

-- À l'arrêt :
pcall(function() hs.keycodes.inputSourceChanged(_old_input_callback) end)
```

---

*Fin du rapport d'audit expert généré par Antigravity.*
