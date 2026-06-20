# Audit Profond et Détection de Bugs - ErgoptiPlus (AutoHotkey)

Cet audit a été réalisé en analysant minutieusement le code source par composants (Core, Keylogger, LLM, Modules AHK et Tests End-to-End). Plusieurs problèmes critiques ont été découverts : conditions de course (race conditions), fuites de mémoire, effacements de données, goulots d'étranglement de performance et vulnérabilités liées à l'uptime.

Voici les découvertes détaillées, les correctifs recommandés et les tests de non-régression à implémenter.

---

## 1. Module `Keylogger` (Critique)

### 1.1 Perte de données silencieuse dans `KL_FlushBuffer` (`keylogger.ahk`)
**Le problème :** `KL_FlushBuffer` est appelé par un timer (qui s'exécute dans un pseudo-thread normal). Il lit `Keylogger.buffer_events` puis exécute `Keylogger.buffer_events := []`. Cependant, les callbacks de type `InputHook` (`KL_Hook_OnChar`) sont `Critical` par défaut en AHK v2 et peuvent interrompre le thread du timer à tout moment. Si une touche est capturée juste après la création de l'objet Map mais avant l'effacement du buffer, la frappe est supprimée et perdue silencieusement.
**Le correctif :** Prendre un snapshot atomique sous `Critical("On")` avant le traitement.
```autohotkey
KL_FlushBuffer() {
    if !Keylogger.initialized
        return
        
    Critical("On")
    events  := Keylogger.buffer_events
    text    := Keylogger.buffer_text
    clicks  := Keylogger.session_clicks
    scrolls := Keylogger.session_scrolls
    dist    := Keylogger.mouse_distance
    
    Keylogger.buffer_events    := []
    Keylogger.buffer_text      := ""
    Keylogger.rich_chunks      := []
    Keylogger.session_clicks   := 0
    Keylogger.session_scrolls  := 0
    Keylogger.mouse_distance   := 0
    Critical("Off")

    if (events.Length = 0 && clicks = 0 && scrolls = 0)
        return
    ; Traiter avec les variables locales `events`, `text`, etc.
}
```
**Test de non-régression :** Créer un mock `InputHook` qui déclenche `KL_Hook_OnChar` 10 000 fois dans une boucle de haute priorité, pendant qu'un timer séparé appelle `KL_FlushBuffer` en continu. Vérifier qu'exactement 10 000 événements ont été enregistrés sans aucune perte.

### 1.2 Perte d'événements de scroll dans `KL_Mouse_FlushScroll` (`keylogger_mouse.ahk`)
**Le problème :** La fonction lit `KLMouse.scroll_ticks`, appelle `MF_ShouldFilter()` (qui peut prendre du temps ou céder le thread), puis remet `KLMouse.scroll_ticks := 0`. Tous les scrolls effectués *pendant* l'évaluation de `MF_ShouldFilter()` sont écrasés.
**Le correctif :** Sauvegarder et réinitialiser les compteurs de manière atomique sous `Critical("On")` *avant* d'évaluer le filtre de confidentialité.
**Test de non-régression :** Injecter un `Sleep 50` dans `MF_ShouldFilter()`. Simuler `KL_Mouse_AccumScroll` pendant le flush et vérifier qu'aucun tick n'est perdu.

### 1.3 Bug catastrophique des 49 Jours d'Uptime (`A_TickCount`)
**Fichiers :** `keylogger_watchers.ahk`, `keylogger_mouse.ahk`, `keylogger_clipboard.ahk`, `keylogger_ergonomics.ahk`
**Le problème :** En AHK v2, les entiers sont signés sur 64 bits. Lors du dépassement (rollover) de `A_TickCount` tous les ~49.7 jours (qui passe de `0xFFFFFFFF` à `0`), une soustraction comme `A_TickCount - KLHook.last_tick` va renvoyer un nombre négatif gigantesque (ex: `-4294967280`) au lieu de la différence réelle. Cela cassera de manière irréversible les machines à état de session, le calcul des mots par minute (WPM), et les détections de burst, jusqu'au redémarrage.
**Le correctif :** Forcer un wrapping sur 32 bits non-signés pour tous les calculs de durée avec l'opérateur bitwise `& 0xFFFFFFFF`.
```autohotkey
gap := (A_TickCount - KLHook.last_tick) & 0xFFFFFFFF
```
**Test de non-régression :** Mocker `A_TickCount` pour passer de `0xFFFFFFF0` à `0x00000010`. Déclencher un calcul d'inactivité et assert que la durée vaut bien `32` millisecondes.

### 1.4 Goulot d'étranglement de performance O(N) au démarrage (`keylogger.ahk`)
**Le problème :** Lors de l'initialisation, `KL_ScanMaxEventId` lit tout `data.sql` (qui peut faire plus de 100 Mo) et boucle en cherchant avec `RegExMatch` depuis la position 1. Lire et itérer sur un texte de 100 Mo des centaines de milliers de fois bloque l'interface utilisateur pendant plusieurs secondes au lancement.
**Le correctif :** Le fichier étant en mode "append-only", le max ID se trouve à la fin. Parcourir le fichier à l'envers via `InStr(..., -1)` passe la complexité à O(1).
**Test de non-régression :** Générer un fichier `data.sql` fictif de 200Mo. Assurer que le calcul de max ID se fait en < 10ms.

---

## 2. Core et Base (`ErgoptiPlus.ahk`)

### 2.1 Faille de suppression (Data-Loss) dans `SaveFullConfig`
**Le problème :** `FileDelete(ConfigurationFile)` est exécuté juste avant `TOML_BatchWrite`. Si le thread est interrompu entre les deux (ex: par `CheckKeyboardLayoutChange` appelant `Reload()`), le fichier utilisateur est définitivement supprimé.
**Le correctif :** Retirer le `FileDelete`. `TOML_BatchWrite` implémente déjà une écriture atomique saine (fichiers temporaires puis renommage). Englober le write dans un bloc `try ... finally` avec `Critical("On")`.

### 2.2 Race Condition dans `ToggleSuspend`
**Le problème :** La fonction suspend, puis manipule les hooks et `_LastSuspendState`. Si le timer d'arrière-plan `_SuspendStateWatchdog` se réveille juste après `Suspend(-1)`, il applique la même logique en double, entraînant une exécution redondante et une potentielle race condition.
**Le correctif :** `ToggleSuspend` devrait faire le `Suspend(-1)` puis appeler directement le `_SuspendStateWatchdog()`.

### 2.3 Toggling Asymétrique de Fonctionnalités dans `ToggleAllFeatures`
**Le problème :** Désactiver les fonctionnalités (`!Bool`) traverse toutes les configurations de façon profonde via `EmitFlip`. Les réactiver (`Bool`) utilise une double-boucle codée en dur très peu profonde qui oublie toutes les sous-options imbriquées (comme `distances_reduction.space_around_symbols` ou `shortcuts.personal`).
**Le correctif :** Utiliser `EmitFlip` inconditionnellement pour réactiver ET désactiver tous les niveaux imbriqués.

### 2.4 Fuite d'état globale dans `BuildTrayMenuDeferred`
**Le problème :** Le script désactive `_DriverReady := false` pendant le build du menu. Si `initMenu()` lève une exception non gérée (I/O, Parsing), l'état ne sera jamais remis à `true`, ce qui bloquera silencieusement toutes les sauvegardes asynchrones et vérifications à l'avenir.
**Le correctif :** Envelopper `initMenu()` dans un bloc `try ... finally { _DriverReady := true }`.

### 2.5 Code mort / Optimisation mémoire dans `ReloadWithDefaultConfig`
**Le problème :** La fonction appelle `_GlobalRestoreFactoryBindings` pour remettre à zéro des centaines de variables mémoire juste avant de lancer `Reload()`. Cela ne sert strictement à rien puisque le rechargement va nettoyer toute la mémoire de toute façon.
**Le correctif :** Supprimer `_GlobalRestoreFactoryBindings`. Effacer simplement les fichiers de config et lancer `Reload()`.

---

## 3. Module `LLM`

### 3.1 Effacement Aléatoire d'appels API (Race Condition dans le Registre)
**Fichiers :** `api_ollama.ahk`, `api_remote.ahk`
**Le problème :** `_LLM_Ollama_TrimAsyncRegistry` supprime les anciennes requêtes en s'appuyant sur l'ordre d'itération d'un objet `Map` via `for`. Or, en AHK v2, l'itération d'un `Map` ne garantit *pas* l'ordre d'insertion. Le système peut donc tuer et supprimer des requêtes asynchrones aléatoirement (y compris la requête récente en cours de complétion).
**Le correctif :** Itérer pour chercher le plus petit identifiant `min_id` manuellement et le supprimer.
**Test de non-régression :** Envoyer 20 requêtes simultanées et vérifier que seules les requêtes 1 à 4 sont annulées.

### 3.2 Bug de "leftover" et Streaming vide (`api_ollama.ahk`)
**Le problème :** Si `curl` termine et que la dernière ligne JSON n'a pas de retour à la ligne (`\n`), celle-ci reste bloquée dans `state["leftover"]` à tout jamais. De plus, la logique de "flush lag" de `_LLM_Ollama_StreamFinalFlush` est inversée : elle ne retry pas si le fichier est vide (`0 bytes`), mais elle retry inutilement si `state["acc"]` a échoué. Cela déclenche souvent l'erreur "Streaming finished with empty response".
**Le correctif :** Inverser la condition `more_to_read` pour réessayer uniquement si le fichier de sortie est vraiment vide (`FileGetSize = 0`). Traiter de force la variable `leftover` dans le nettoyage final.

### 3.3 Défaut d'encadrement Batch Output (`prediction_engine.ahk`)
**Le problème :** Dans `_LLM_Engine_SplitBatchBlocks`, le texte est séparé sur les "===" via RegEx, mais la fonction ne respecte pas le `n_predictions` attendu. Si le LLM hallucine des boucles, il peut créer 20 blocs "===", saturant la mémoire du parser ou de l'interface graphique.
**Le correctif :** Forcer la limite à `n_predictions` (soit dans le `SplitBatchBlocks`, soit dans le Parser associé).

### 3.4 PID Collision de Curl (Fuite de stream)
**Le problème :** `_LLM_Ollama_RemoveStreamHandle` filtre l'ActiveStreams en vérifiant l'égalité des `PID` au lieu des objets eux-mêmes. Windows réutilise massivement les PID des processus de très courte durée. Si `curl` crashe vite, son PID peut être récupéré par une nouvelle requête, qui sera à son tour supprimée du registre par erreur.
**Le correctif :** Comparer par la référence d'objet (`h != handle`).

---

## 4. Modules AHK (`gestures.ahk`, `layout.ahk`, `hotstrings.ahk`)

### 4.1 Race Condition d'E/S (Disk I/O Bottleneck) dans `GestureScreenshotInstant`
**Fichier :** `gestures.ahk`
**Le problème :** La fonction écrit un script PowerShell temporaire `hs_screenshot.ps1` à chaque appel. S'il est déclenché rapidement, le fichier est écrasé pendant que le premier `powershell.exe` le lit encore (crash). De plus, aucun nettoyage de fichier n'est effectué.
**Le correctif :** Refactoriser pour utiliser `GestureCaptureRegion` qui execute le payload C# directement via l'argument `-Command` sans fichier temporaire.
**Test de non-régression :** Déclencher 3 fois le raccourci en < 100ms. Vérifier que 3 PNG sont créés sans aucune erreur de verrouillage de fichier.

### 4.2 EndKeys Avalés Silencieusement par `DeadKey`
**Fichier :** `layout.ahk`
**Le problème :** `DeadKey` utilise un `InputHook` pour écouter des EndKeys (`Enter`, `BackSpace`, `Escape`). Sans l'option "V", l'InputHook avale la frappe. Si l'utilisateur tape une touche morte (ex: `^`) et appuie sur `Enter`, le saut de ligne disparaît, cassant le workflow.
**Le correctif :** Vérifier `if (ih.EndReason = "EndKey")` et renvoyer la frappe supprimée via `Send("{" ih.EndKey "}")`.

### 4.3 Faux-positifs de recherche de fenêtre Notepad dans `GestureTakeNote`
**Fichier :** `gestures.ahk`
**Le problème :** Le script utilise `SetTitleMatchMode(2)` pour activer `Notes.txt`. Si l'utilisateur a un répertoire "Notes.txt" ouvert ou qu'il navigue sur internet, la fonction volera le focus d'une mauvaise fenêtre au lieu de rouvrir le Notepad.
**Le correctif :** Matcher le nom du programme explicitement: `WMExists(FileName . " ahk_exe notepad.exe")`.

### 4.4 Fuite de Hooks Redondants dans les Touches Mortes
**Fichier :** `hotstrings.ahk`
**Le problème :** Lors du clonage de la Map `DeadkeyMappingCircumflex`, la boucle de nettoyage supprime les voyelles minuscules (`a`, `e`, `i`, `o`, `u`), mais oublie leurs équivalents MAJUSCULES (`A`, `E`, `I`...). Résultat, `RegisterAllHotstrings` perd du temps CPU à installer des hotstrings en double pour des lettres déjà traitées nativement.
**Le correctif :** Ajouter les versions majuscules à la fonction de nettoyage de `DeadkeyMappingCircumflexModified.Delete()`.

### 4.5 Code Mort `_UIA_EMPTY_SEL_CACHE`
**Fichier :** `layout.ahk`
**Le problème :** Le cache pour la sélection vide `_UIA_EMPTY_SEL_CACHE` est déclaré mais jamais utilisé ou populé, relique d'une version passée où l'UIA n'était pas gérée par un polling en background à 500ms.
**Le correctif :** Retirer les définitions globales liées à `_UIA_EMPTY_SEL_CACHE`.

---

## 5. Stratégie E2E et Tests de Non-Régression (Suite de Tests)

Le framework de tests actuel contient des *anti-patterns* massifs nécessitant des actions correctives pour éviter l'illusion de couverture.

### 5.1 "Fake Test" Anti-Pattern
Plus de **60 tests** (dans `test_llm_prediction_engine`, `test_logger`, etc.) se contentent de faire `AssertTrue(true, "Description")` sans rien tester. C'est dangereux et fausse les métriques de fiabilité du code. À supprimer ou à implémenter sérieusement.

### 5.2 Flaky Tests causés par des `Sleep`
Les tests comme `test_hse_conform_double_fire.ahk` ou `run_e2e.ahk` utilisent des durées fixes (`Sleep 100`, `Sleep 150`) en espérant qu'un timer ou que l'interface ait réagi. Sur un CI très sollicité, le test échouera à cause de cette attente trop rigide.
**Correctif :** Passer à une boucle de *Polling* qui assert l'état toutes les 10ms jusqu'à un timeout de sécurité.

### 5.3 Débordement d'états (State Leakage) dans le Framework
Le framework (`Test()`) ne possède pas d'architecture `SetUp` / `TearDown`. Les variables globales (ex: `_LLM_Engine`, `LastSentCharacterKeyTime`) sont polluées. Un crash d'un test modifie le contexte pour tous les autres, cassant la suite en cascade.
**Correctif :** Implémenter un système de Hooks pour isoler proprement l'état global avant de lancer chaque fonction de test.

### 5.4 Tests End-to-End (E2E) Manquants
Le fichier `run_e2e.ahk` manque de cas complexes. La couverture E2E devrait obligatoirement inclure :
1. **Intégration Tooltip/LLM** : Déclencher un LLM, valider le background `curl`, le timeout, et le texte affiché.
2. **Interruptions d'Application** (`HSE_Suppress`).
3. **Complex Hotstrings** : Naviguer avec les flèches directionnelles au milieu d'un trigger et vérifier l'annulation ou la correction.
4. **Pointer / Gestures Lifecycle**.

---
*Fin de l'audit ErgoptiPlus*
