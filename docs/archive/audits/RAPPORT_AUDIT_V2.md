# RAPPORT AUDIT V2 - Détection de Bugs Avancés (ErgoptiPlus)

Suite aux précédentes corrections, cet audit en profondeur de la base de code AHK v2 révèle que **plusieurs bugs critiques subsistent**. Certains correctifs demandés ont été mal implémentés (code mort, tests fallacieux), et des comportements inattendus graves ont été détectés dans l'UI et la gestion de la mémoire.

Voici le rapport détaillé des bugs trouvés, comment les corriger de manière définitive, et les tests de non-régression à implémenter.

---

## 1. Module `LLM` (Prediction Engine & Parser)

### 1.1 Code Mort et OOM : Bug de SplitBatchBlocks non appliqué
**Le problème :** L'audit précédent demandait de plafonner le split des requêtes batch pour éviter les débordements mémoire si le LLM hallucine des milliers de séparateurs `===`. La fonction `_LLM_Engine_SplitBatchBlocks(raw, max_count)` a été correctement écrite et couverte par 10 tests unitaires. **Cependant, elle n'est jamais appelée en production !** Le script continue d'appeler l'ancien `LLM_Parser_SplitBlocks(raw)` non borné dans `LLM_Parser_ParseResponse`.
**Le fix :** Dans `parser.ahk` ou `prediction_engine.ahk`, modifier l'appel pour utiliser la nouvelle fonction bornée :
```autohotkey
for _, block in _LLM_Engine_SplitBatchBlocks(raw, n_predictions)
```
**Test de non-régression :** Un test E2E qui injecte une réponse API falsifiée contenant 5000 fois `===`. Vérifier que l'allocation se coupe instantanément après 3 blocs sans impacter la mémoire.

### 1.2 TrimAsyncRegistry tue toujours des requêtes aléatoirement
**Fichiers :** `api_ollama.ahk`, `api_remote.ahk`
**Le problème :** Le bug du nettoyage de registre n'a pas été corrigé. Le code itère encore avec `for oldest_id, oldest_entry in _LLM_Ollama_Async` avec un commentaire stipulant faussement que *« Maps preserve insertion order in AHK v2 »*. C'est faux : en AHK v2, l'itération d'un Map **ne garantit pas** l'ordre. Conséquence : des requêtes en cours de streaming sont tuées arbitrairement.
**Le fix :** Les clés de la Map sont des entiers (`request_id`). Il faut chercher manuellement le plus petit entier :
```autohotkey
min_id := 0xFFFFFFFFFFFFFFFF
for id in _LLM_Ollama_Async
    if (id < min_id)
        min_id := id
```
Puis supprimer `_LLM_Ollama_Async[min_id]`.
**Test de non-régression :** Insérer les requêtes d'ID `4`, `1`, `9`. Appeler le Trim et s'assurer que c'est strictement la `1` qui est tuée, peu importe l'ordre de hachage de la Map.

### 1.3 Test Unitaire Fallacieux forçant des régressions (`test_stream_handle_type.ahk`)
**Le problème :** L'audit V1 a exigé que `_LLM_Ollama_RemoveStreamHandle` compare les handles par référence (`h != handle`) et non par PID, pour éviter les collisions système de Windows. Le développeur a écrit le correctif, **mais** a ajouté le test `test_stream_handle_type.ahk` nommé `_SHT_AssertPidComparison` qui exige littéralement que la fonction fasse une comparaison par PID (`Assert(InStr(Body, "Pid") > 0)`). Ce test trompeur force conceptuellement le bug à exister et sème la confusion.
**Le fix :** Modifier le test pour s'assurer que `h != handle` est présent, et renommer le test pour refléter la bonne sémantique (comparaison d'objets, pas de PIDs).

---

## 2. Base & Utilitaires (A_TickCount & Hotstrings)

### 2.1 Gel UI Critique (500ms) sur la copie d'images (`GetSelection`)
**Fichier :** `lib/hotstrings/hotstring_engine.ahk`
**Le problème :** La fonction `GetSelection()` fait `ClipWait(GET_SELECTION_TIMEOUT_SEC)` (donc `0.5`s). Par défaut en AHK, `ClipWait` n'attend **que du texte ou des fichiers**. Si l'utilisateur sélectionne une image, une région native, ou un calque, et qu'une action appelle `GetSelection()`, l'interface et le clavier entier gèleront pendant 500ms avant de subir un timeout.
**Le fix :** Utiliser `ClipWait(GET_SELECTION_TIMEOUT_SEC, 1)` pour autoriser la détection de TOUT type de données binaire. L'attente réussira instantanément, puis le cast texte `Text := A_Clipboard` renverra `""` de façon gracieuse sans freeze.
**Test de non-régression :** Injecter des données binaires (`CF_DIB`) dans le presse-papier. Lancer `GetSelection()` et vérifier (via `A_TickCount`) que l'exécution a pris < 10ms.

### 2.2 Propagation du Bug de Débordement `A_TickCount` (49 jours)
**Le problème :** L'audit précédent avait trouvé que le Keylogger s'effondrait au bout de 49 jours (wrap du DWord `A_TickCount` vers 0). Ce fix n'a pas été appliqué partout. Il est encore présent dans :
- `layout.ahk` (`AppState_TouchLastSentKey`): Les frappes ne seront jamais effacées du buffer si `A_TickCount` dépasse `0`.
- `hotstring_engine.ahk` (`IsTimeActivationExpired`): Tous les Timeouts d'activation des hotstrings seront cassés.
- `metrics_filters.ahk`, `wpm_widget.ahk`, `tooltip.ahk`, `logger.ahk`.
**Le fix :** Partout où une durée est calculée, utiliser une fonction utilitaire safe ou l'opération :
```autohotkey
elapsed := ((Now - LastTick) & 0xFFFFFFFF)
```
**Test de non-régression :** Mocker un `A_TickCount` juste avant le débordement (0xFFFFFFFA), attendre quelques millisecondes pour générer le débordement binaire (0x0000000A), taper une touche, et vérifier que la durée est calculée positivement à 16ms.

---

## 3. Adaptateurs & Données

### 3.1 Fuite de Handle et Perte de Tâches (`TimerScheduler.TimerAfter`)
**Fichier :** `adapters/timer_scheduler.ahk`
**Le problème :** Dans le wrapper `_TimerAdapterMakeOneShot`, si le callback d'un `TimerAfter` se déclenche pendant que le script est suspendu (`A_IsSuspended == true`), le script fait un `return` silencieux. Étant donné que `SetTimer` est un "one-shot" avec un délai négatif, il ne se relancera jamais.
Conséquences : la tâche différée est perdue pour toujours, et l'identifiant du timer reste piégé indéfiniment dans la table globale `_TIMER_ADAPTER_REGISTRY` (fuite de mémoire croissante).
**Le fix :** Si `A_IsSuspended` est vrai pour un `TimerAfter`, il faut soit le reprogrammer (ex: `SetTimer(BoundFn, -500)`), soit au moins effacer l'objet de la `_TIMER_ADAPTER_REGISTRY` pour éviter la fuite avant d'annuler.
**Test de non-régression :** Mocker `A_IsSuspended := true`. Déclencher `TimerAfter(0.1, Callback)`. Vérifier qu'après 500ms, le registre `_TIMER_ADAPTER_REGISTRY` est bien vide.

### 3.2 Corruption Non Atomique du Cache TSV des Hotstrings
**Fichier :** `lib/hotstrings/hotstrings_cache.ahk`
**Le problème :** Lors de la régénération du cache (`_HotstringsCacheWriteTsv`), le code fait `FileDelete(TsvPath)` puis `FileAppend(Content, TsvPath)`. Ces deux opérations ne sont pas protégées. Si le script crash, que la machine perd le courant, ou qu'une autre instance démarre exactement en même temps, le cache sera corrompu ou supprimé.
**Le fix :** Utiliser la technique classique d'écriture de fichier atomique : écrire le résultat dans un `hotstrings.tsv.tmp`, puis appeler `FileMove("hotstrings.tsv.tmp", TsvPath, 1)`.
**Test de non-régression :** Faire exécuter la fonction de build du TSV par plusieurs processus AHK simultanément sur un même sous-répertoire de test et s'assurer que le fichier produit n'est ni vide, ni corrompu.

---

## 4. Polling Réseau & Exceptions COM

### 4.1 Boucle Infinie (Busy Loop 50ms) sur Exception COM
**Fichiers :** `modules/llm/api_ollama.ahk`, `modules/llm/api_remote.ahk`
**Le problème :** Lors de l'attente d'une réponse asynchrone, le script poll la connexion via `try ready := http.WaitForResponse(0)`. Si la connexion réseau lâche au milieu (coupure WiFi, redémarrage du serveur Ollama), `WaitForResponse` lève une erreur COM. Le `try` l'avale silencieusement, laissant `ready` à `false`. Le script relance alors un Timer à 50ms, qui redéclenchera la même exception instantanément, créant une boucle infinie saturant le CPU toutes les 50ms jusqu'au timeout global de 3 minutes.
**Le fix :** Catcher explicitement l'erreur pour abandonner la requête réseau immédiatement :
```autohotkey
try {
    ready := http.WaitForResponse(0)
} catch as err {
    ; Coupure réseau ou erreur COM - abandon précoce
    on_fail := entry["on_fail"]
    _LLM_Ollama_Async.Delete(req_id)
    try on_fail()
    return
}
```
**Test de non-régression :** Lancer une requête, puis fermer sauvagement le processus Ollama. Vérifier que la fonction `on_fail` est appelée immédiatement (< 50ms) sans spammer la boucle interne pendant 3 minutes.

---

## 5. Stabilité des Hooks Claviers

### 5.1 Désactivation Silencieuse du Hook Clavier (InputHook) par Exception Non Catchée
**Fichier :** `modules/keylogger/keylogger_hook.ahk`
**Le problème :** Un crash dans un callback d'un `InputHook` arrête définitivement ce hook, ce qui neutralise le keylogger. Le code de `KL_Hook_OnChar` n'enveloppe qu'une partie de sa logique dans un bloc `try`. Toute erreur de type, dépassement de mémoire sur la concaténation de texte (`Keylogger.buffer_text .= c`), ou un tableau mal initialisé plantera le thread de façon critique, paralysant toutes les frappes suivantes.
**Le fix :** Mettre un bloc global `try { ... } catch { }` englobant *l'intégralité* de `KL_Hook_OnChar` et `KL_Hook_OnKeyDown`.
**Test de non-régression :** Injecter volontairement une instruction invalide (`Throw Error("Mock")`) au milieu de `KL_Hook_OnChar`. Taper des lettres au clavier, et s'assurer que l'exception ne désactive pas le hook (les frappes suivantes doivent continuer à appeler le callback).

