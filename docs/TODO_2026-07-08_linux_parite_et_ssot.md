# TODO — Linux 100 % parité + finition SSoT (2026-07-08)

> **But.** Doc de travail **exécutable en autonomie**. Un agent doit pouvoir suivre
> cette todo item par item sans re-deviner le contexte. Chaque item : quoi faire,
> `chemin:ligne` réels, où est la logique partagée, et le test de régression à livrer.
>
> **Règle d'or (mainteneur).** Zéro duplication de code / de valeur entre les 3
> drivers (`windows/` AHK, `macos/` Hammerspoon, `linux/` LuaJIT). Toute valeur ou
> logique qui gouverne un comportement vit **une seule fois** dans `_shared/`, lue
> en fail-fast. Les 3 drivers doivent avoir **exactement** les mêmes features et le
> même comportement.
>
> **Discipline (§5.9).** Chaque bug corrigé et chaque item structurel embarque son
> **test de régression** (rouge avant / vert après). Vérifier avec les VRAIES suites
> avant de committer (`npm run build:domain`, `npm run test:js`, `cd macos && lua
> tests/run.lua`, `cd linux && lua tests/run.lua`) — jamais « ça compile ».
> Un commit conventionnel par item. **Ne rien pusher.**
>
> **Contexte machine.** Le mainteneur est sous **Windows** : le driver Linux ne peut
> pas encore tourner nativement ici (pas de GTK/D-Bus/evdev/luajit). Les items 🐧
> marqués *daemon-only* ne sont vérifiables qu'à l'exécution sur une vraie machine
> Linux — leur « fait » signifie **code écrit + testé unitairement avec mocks**, pas
> « vérifié en run ». Ne pas cocher « fait » comme si c'était vérifié en prod.

---

## 0. État réel vérifié au 2026-07-08

Les 26 items du plan `PLAN_2026-07-01_mise_en_commun_linux.md` ont été **écrits et
committés**, mais leur livraison a laissé **7 défauts sur les plateformes testables**
(tous corrigés depuis) et **le driver Linux ne tourne pas** (pipeline de saisie mort,
voir Priorité 1). Correctifs déjà appliqués (2 commits) :

- `a4624a741` — **bug de prod** : `macos/ui/menu/menu_karabiner.lua` appelait
  `_load_left_hand_from_catalog()` **au-dessus** de sa définition `local function`
  (non hoistée en Lua) → crash au chargement du menu à chaque build (macOS). +
  test de régression comportemental.
- `0bb95a26c` — remise au vert des 6 tests rouges : escape `\\n\\n` du vecteur DL-1
  (Lua + JS), fixture DL-1 sans `batch = true`, garde poll-timer healthcheck
  (fenêtre 1200-char fragile → ancrée), 2 baselines OS-call (DC-4 priority.json), 3
  en-têtes de fichier Linux (`linux/lib/...` → `lib/...`).

Suites au vert : **build:domain 15/15 · test:js 44/44 · macOS 2836/0 · Linux 678/0**.

⚠️ **Motif systémique détecté.** Le même bug « variable/`local function` utilisée
avant sa définition → nil global » existe dans **3 fichiers** de la livraison
(menu_karabiner corrigé ; `linux/modules/llm/prediction_engine.lua` et
`linux/adapters/tray_menu.lua` restants — voir P1.2). Signe que le Lua livré n'a
**jamais été exécuté**. Tout nouveau `.lua` doit être chargé au moins une fois
(via son test unitaire) avant commit.

---

## PRIORITÉ 0 — Finir la mutualisation / SSoT (base solide AVANT toute feature)

> Ces items suppriment des duplications **réelles et déjà divergentes**. À faire en
> premier : un driver Linux construit sur des valeurs dupliquées héritera des bugs.
> Chaque item = 1 commit + test (une assertion de parité ou un test single-source).

### P0-A — Géométrie des webviews : canonique mort + 9 dérives actives *(Tier 0, pire cas)*

`_shared/ui/apps.manifest.json` définit `width/height/min_*` des 14 fenêtres et
prétend être « lu par les 3 hosts ». **Il n'est lu par aucun chemin vivant** : le
reader Windows `WebViewHost` (`windows/lib/webview_utils.ahk:127-257`) n'est jamais
appelé ; macOS ne le référence pas ; Linux stub. Résultat : chaque taille définie
3× et **9 ont déjà dérivé** (l'app a une taille différente macOS vs Windows).

- [x] **P0-A.1** Câbler macOS `ui_builder` (`macos/ui/ui_builder.lua`,
  `M.get_app_geometry(id)`) pour lire la géométrie depuis `apps.manifest.json`
  **par id d'app** ; les 10 modules UI résolvent leur taille à l'ouverture (plus
  aucun littéral macOS). Test lua `tests/unit/ui/test_ui_builder_geometry.lua`.
- [~] **P0-A.2** Host Windows : **partiel**. Migration des 14 modules AHK vers
  `WebViewHost` (`windows/lib/webview_utils.ahk:127`, qui lit déjà le manifeste)
  **reportée** — trop risquée sans exécution AHK possible ici. À la place : la seule
  dérive Windows (changelog) est corrigée et **toutes** les valeurs Windows sont
  épinglées au manifeste par le gate P0-A.4 (rouge si un littéral dérive). Le reader
  `WebViewHost` reste la cible de migration (pas supprimé : c'est la bonne archi).
- [x] **P0-A.3** Réconcilier les **9 dérives** sur la valeur manifeste (source de
  vérité) — 8 dérives macOS supprimées par câblage (P0-A.1), dérive Windows
  changelog `h560→h580` corrigée :

  | App | Canonique (`apps.manifest.json`) | Windows | macOS (à corriger) |
  |---|---|---|---|
  | hotstring_editor | 960×640 (`:40-43`) | 960×640 `windows/ui/personal_toml_editor_webview.ahk:99,103,109` | **760**×640 `macos/ui/hotstring_editor/init.lua:372` |
  | healthcheck | 740×560 (`:26-29`) | 740 `windows/ui/healthcheck/core.ahk:257,299,317` | **700×600** `macos/ui/healthcheck/core.lua:420` |
  | changelog | 860×580 (`:12-15`) | **h560** `windows/ui/changelog/init.ahk:119,125,131` | 860×580 `macos/ui/changelog/init.lua:39-40` |
  | model_browser | 900×580 (`:61-64`) | 900×580 `windows/ui/model_browser/init.ahk:380,384,388` | **880×560** `macos/ui/model_browser/init.lua:33-34` |
  | hotstrings_config_window | 740×660 (`:33-36`) | 740×660 `windows/ui/hotstrings_config_window/webview.ahk:67-68,102` | **720×640** `macos/ui/hotstrings_config_window/init.lua:57-58` |
  | prompt_editor | 560×500 (`:89-92`) | 560×500 `windows/ui/prompt_editor/init.ahk:71-72,110` | **550×480** `macos/ui/prompt_editor/init.lua:39-40` |
  | onboarding | 480×560 (`:68-71`) | 480×560 `windows/ui/onboarding/webview.ahk:129,133,142` | **460×520** `macos/ui/onboarding/init.lua:594-595` |
  | paths_editor | 720×300 (`:75-78`) | 720×300 `windows/ui/paths_editor/init.ahk:77,81,87` | **700×220** `macos/ui/menu/menu_paths.lua:552-553` |
  | personal_info_editor | 560×680 (`:82-85`) | 560×680 `windows/ui/personal_info_editor/init.ahk:76,80,85` | **h720** `macos/ui/personal_info_editor/init.lua:189-190` |

  Triplications latentes (concordent aujourd'hui, vont dériver) : **download_window**
  460×380 (`macos/ui/download_window/init.lua:233-234` + `windows/modules/llm/ollama_webview.ahk:37-38`,
  dont le commentaire admet « matches the Hammerspoon proportions ») ; **action_picker**
  460×560 (`windows/ui/action_picker_webview.ahk:67-68` + `macos/ui/action_picker/init.lua:45-46`).
  **Ne PAS unifier** metrics_typing / metrics_apps (volontairement écran-relatifs).
- [x] **P0-A.4** Test : `tools/test/test-webview-geometry-single-source.cjs` (dans
  `run-js-suite`) — macOS défère à `get_app_geometry`, littéraux Windows == manifeste
  (20 checks). Rouge prouvé sur dérive, vert après.

### P0-B — Sous-système LLM Linux qui contourne `_shared` *(Tier 1)*

Linux importe déjà `linux_bridge`/`defaults.json` mais re-hardcode des valeurs.
Corriger côté Linux pour lire les canoniques.

- [ ] **P0-B.1** `keep_alive = "30m"` **hardcodé dans les 3 drivers, aucun canonique**.
  Créer le canonique (`_shared/modules/llm/inference.json` ou `defaults.json`
  clé `llm_ollama_keep_alive`), lu par : macOS `modules/llm/api_ollama.lua:172,373,514`,
  Windows `modules/llm/api_ollama/ollama_payload.ahk:120`, shared
  `_shared/lua/llm/linux_bridge.lua:272`. Test single-source.
- [ ] **P0-B.2** Port Ollama `11434` : canonique `defaults.json llm_ollama_port` (lu
  par macOS+Windows). Linux hardcode 4× : `linux/modules/llm/profiles.lua:69,74`
  (+ `localhost` au lieu de `127.0.0.1`), `linux/modules/llm/prediction_engine.lua:110,171`,
  UI `linux/modules/menu/menu_builder.lua:117`. Router via
  `HttpBridge.OLLAMA_DEFAULT_PORT`/`OLLAMA_DEFAULT_HOST` (déjà importé). Note :
  `_shared/lua/llm/linux_bridge.lua:24,27` duplique aussi host/port — les faire lire
  `defaults.json`.
- [ ] **P0-B.3** Température : canonique `0.1` (`defaults.json llm_temperature`).
  Linux a **deux** valeurs divergentes : `prediction_engine.lua:188` = `0.3`,
  `linux_bridge.lua:34` = `0.7`. Réconcilier les deux au canonique.
- [ ] **P0-B.4** Context length : canonique `500` (`defaults.json llm_context_length`).
  Linux `prediction_engine.lua:78` = `2000`. Lire le canonique.
- [ ] **P0-B.5** `max_tokens` : canonique `DEFAULT_MAX_TOKENS = 150`
  (`_shared/lua/llm/prompt_builder.lua:42`). Linux `prediction_engine.lua:188` = `200`.

### P0-C — Duplication interne au tree `_shared/` *(Tier 2)*

- [ ] **P0-C.1** `linux_bridge.lua` redéfinit des constantes qu'il devrait lire de
  `prompt_builder` (qu'il `require` déjà, ligne 14) : `CONTEXT_TAIL_WORDS`
  (`linux_bridge.lua:37` vs canon `prompt_builder.lua:39`) et `DEFAULT_MAX_TOKENS`
  (`linux_bridge.lua:250` vs canon `prompt_builder.lua:42`). Utiliser `PromptBuilder.*`.

### P0-D — Timeouts Linux non branchés sur le registre Timings *(Tier 2)*

- [ ] **P0-D.1** curl `--max-time 30` (`linux/modules/llm/api_ollama.lua:116`) et
  `DEFAULT_TIMEOUT_MS = 30000` (`linux/adapters/http_client.lua:38`) → lire
  `Timings.sec("llm","request_timeout_ms")` (canon
  `_shared/modules/timings/constants.toml [llm] request_timeout_ms = 30000`, déjà
  lisible via `linux/lib/timings.lua`).

### P0-E — Tables keycode + version triplicées côté Linux *(Tier 2)*

- [ ] **P0-E.1** Table keycode→char triplée : `linux/modules/hotstrings/input_reader.lua:149-207`
  (fallback), `linux/adapters/keyboard_hook.lua:328-365` (copie complète, morte — voir
  P1.1), `_KEYCODE_MAP` `keyboard_hook.lua:182-207` (dup de `input_reader.lua:65-73`).
  Source unique = `_shared/data/keycodes/evdev.json` (déjà chargé par
  `input_reader.lua:91-135`). Supprimer les copies mortes après P1.1.
- [ ] **P0-E.2** Version `"3.0.0"` triplée : `linux/modules/menu/menu_builder.lua:38`,
  `linux/modules/ui/bridge_handlers/healthcheck_bridge.lua:79` (ignore `ctx._version`),
  `linux/ergopti_hotstrings.lua:389`. Source unique (util version partagée ou stamp
  au build, comme `BUNDLE_VERSION` macOS/Windows).

### P0-F — Cap buffer hotstring divergent *(Tier 2/3)*

- [ ] **P0-F.1** Cap du buffer glissant : shared Lua `_shared/lua/hotstring_engine/init.lua:56`
  = `256` (macOS+Linux) ; Windows hardcode `64` dans **2** fichiers
  (`windows/lib/hotstrings/hotstring_inputhook.ahk:64` `_MAX_BUFFER_LEN`,
  `windows/lib/hotstrings/hotstring_engine_main.ahk:62` `HSE_MAX_BUFFER_LEN`, le
  commentaire admet qu'ils doivent concorder). Décider la valeur correcte, single-sourcer
  (canon `_shared`), + test de parité. (Intra-Windows : au minimum les 2 lire une constante.)

### P0-G — Logique métier dupliquée cross-driver (aucun module partagé NI corpus)

> Ces items sont issus de l'audit de **duplication de logique** (pas de valeurs). Une
> logique réimplémentée dans 2-3 drivers sans (a) module `_shared/lua/` requis par les
> drivers Lua, ni (b) corpus de parité certifiant les copies AHK, **dérive en silence**.
> Le corpus cross-driver `_shared/tests/corpus/` n'existe aujourd'hui que pour :
> `dynamic_hotstrings, hotstrings, llm, prompt_builder, security, tap_hold, toml`.

- [ ] **P0-G.1 — [CRITIQUE] Agrégation keylogger par frappe + flush SQL (macOS↔AHK,
  hand-mirror, zéro corpus).** ⚠️ **LNX-8 est faussement coché « fait ».** Seuls les
  *leaf helpers* ont été extraits (`_shared/lua/keylogger/aggregator_helpers.lua`,
  consommé **uniquement par macOS** `aggregator/core.lua:22,229-291` ; Linux ne fait que
  le tester en isolation). La **machine à états du walk** (~500 lignes) et les **2 couches
  SQL** restent des copies main-à-main byte-for-byte :
  - macOS : `macos/modules/keylogger/aggregator/events.lua` (`walk_typing` :35-389),
    `core.lua` (constantes), `sql.lua` (UPSERT). En-têtes `MIRRORS: windows/…`
    (`core.lua:11`, `events.lua:14`, `sql.lua:13`).
  - Windows : `windows/modules/keylogger/keylogger_walker_events.ahk`
    (`KLW_WalkTypingEntry` :34-500, en-tête « mirrors the Lua …**byte-for-byte** »),
    `keylogger_walker_core.ahk` (re-déclare **toutes** les constantes partagées en
    `KLWConst` : `CASCADE_MIN_BS:=3` :57, `MIN_BURST_FOR_CPM:=10` :52,
    `SESSION_DURATIONS_CAP:=100` :55, `BURST_LENGTH_BUCKETS` :54, `UI_PAUSE_BUCKETS_MS` :43),
    `keylogger_walker_sql.ahk`.
  - **Fix** : ajouter `_shared/tests/corpus/keylogger/aggregation_vectors.json` (batches
    d'events JSONL typing/app_switch/window_switch/system → batch sérialisé attendu :
    `app_day`, `ngram.*`, `bursts`, `sessions`, `ergo`, `errors`, `hourly`, `app_buckets`,
    `kc_hold`, `system_day`). Épingler **les deux** : test macOS (replay via `events.lua`,
    asserter `S.agg_batch`) **et** test AHK (replay via `KLW_WalkTypingEntry`, asserter
    `KLW.batch`) — pattern déjà utilisé pour le parser LLM. Optionnel : extraire le walk
    vers `_shared/lua/keylogger/aggregator_walk.lua` que macOS `require` (single-source le
    côté Lua). Ne PAS toucher `KLW_VK_FINGER` (exception documentée
    `project-dc1-windows-vk-finger-map-gap`). **Corriger la case LNX-8 du plan.**

- [ ] **P0-G.2 — [HIGH] Builder du snapshot healthcheck (macOS↔AHK dupliqué + Linux
  divergent).** UI-A1 n'a partagé que le *frontend* HTML/CSS/JS, **pas** le builder du
  modèle de données. Duplication déjà **dérivée** (16 vs 23 adaptateurs, flag `wired`
  macOS-only, `script.js` branche déjà sur des noms de champs divergents
  `ahk_version` vs `hs_version`, `ram_total_gb` vs `ram_total`, `dpi_scale` vs `dpi`,
  `cpu_name` vs `cpu_model`) :
  - Windows : `windows/ui/healthcheck/core.ahk` (`_HealthCheck_AdapterSpecs` :40,
    `HealthCheck_Run` :105, `HealthCheck_FormatPlain` :466) + `helpers.ahk`.
  - macOS : `macos/ui/healthcheck/core.lua` (`ADAPTER_SPECS` :82, `M.run` :222,
    `M.format_plain` :572) + `helpers.lua`.
  - Linux : `linux/modules/ui/bridge_handlers/healthcheck_bridge.lua:18` — forme
    **complètement différente** (`modules={engine,keylogger,config,llm,layout}`).
  - **Fix** : extraire le builder de modèle vers `_shared/lua/healthcheck/` (macOS +
    Linux `require`, noms de champs unifiés) + corpus
    `_shared/tests/corpus/healthcheck/snapshot_vectors.json` (résultats de probe →
    modèle + `format_plain` attendus) épinglant le builder AHK ; converger `script.js`
    sur un seul schéma de champs.

- [ ] **P0-G.3 — [HIGH] Parsing du JSON de release updater (macOS↔AHK, non certifié).**
  Le **compare de versions** est bien partagé + corpus (`_shared/lua/updater/version.lua`
  + `version_vectors.json`, macOS délègue `updater.lua:109-127`) — **ne pas y toucher,
  c'est fait**. Mais les **parsers** (tag / notes / asset-URL / prerelease / split
  releases / pick latest-prerelease) sont dupliqués sans corpus, avec **dérive déjà
  observée** (unescape des notes ; nom d'asset `"ErgoptiPlus.app.zip"` vs
  `"ErgoptiPlus.exe"`) — chemin critique « y a-t-il une MAJ / quelle URL télécharger » :
  - Windows : `windows/lib/updater/core.ahk` (`Updater_ParseTagName` :844,
    `Updater_ParseBody` :859, `_Updater_SplitReleasesArray` :750,
    `_Updater_ParsePrerelease` :793, `_Updater_UnwrapLatestPrerelease` :686),
    `self_update.ahk:34` `_Updater_FindAssetUrl`.
  - macOS : `macos/lib/updater.lua` (`split_releases_array` :167,
    `parse_prerelease_flag` :196, `pick_latest_prerelease_json` :203, + parse_tag/notes/asset_url ~:266-291).
  - **Fix** : extraire les parsers vers `_shared/lua/updater/` (macOS/Linux délèguent) +
    `_shared/modules/updater/release_parse_vectors.json` épinglant AHK/macOS/JS — miroir
    exact de ce qui existe déjà pour `compare_versions`. (Recoupe LNX-9, plus large que la case.)

- [ ] **P0-G.4 — [MED-HIGH] Cascade de résolution locale (triplée ; 2 copies Lua
  byte-identiques).** Fallback `locale active → EN → FR → clé brute`, substitution
  `★`→trigger, warm de cache `ensure_loaded`, invalidation `set_locale` :
  - Windows : `windows/lib/locale.ahk` (`t()` :283-299, `ensure_loaded` :255-270,
    substitution ★ :120-121/:203-206) + `windows/lib/i18n.ahk:210-221`.
  - macOS : `macos/lib/locale.lua` (`M.get` :129-150, `ensure_loaded` :97-112, ★ :146,
    `set_locale` :164-172).
  - Linux : `linux/lib/locale.lua` (`M.get` :135-152, `ensure_loaded` :107-121, ★ :148,
    `set_locale` :164-170) — **fork quasi-verbatim** de la copie macOS (seuls diffèrent le
    décodeur JSON + le résolveur de chemin).
  - **Fix** : fusionner les 2 copies Lua identiques dans `_shared/lua/locale/` (macOS +
    Linux `require`), puis corpus-épingler le `t()` AHK contre
    `_shared/tests/corpus/locale/resolution_vectors.json` (clé + tables chargées → string
    attendue, exerçant la cascade active→en→fr→clé et la substitution ★).

- [ ] **P0-G.5 — [LOW-MED] Tooltip layout/geometry + dequeue (hand-porté 2 côtés ; seul
  `tint` est certifié).** Le spec `_shared/modules/tooltip/` expose
  `layout.js:316 layoutTestVectors()` et `dequeue.js:195 dequeueTestVectors()` mais
  **`layoutTestVectors` n'est consommé par aucun test driver** (position/clamp/geometry
  hand-porté non certifié : Windows `ui/tooltip/helpers.ahk` `_TooltipResolvePosition` :749,
  `_TooltipClampToScreen` :65 ↔ macOS `ui/tooltip/renderer.lua`) et **`dequeue` n'est
  épinglé que côté macOS** (`test_tooltip_dequeue_contract.lua`). `tint` EST certifié des
  2 côtés (ne pas toucher). **Fix** : promouvoir `layoutTestVectors`/`dequeueTestVectors`
  en JSON partagé chargé par les 2 suites + ajouter le test dequeue AHK manquant + les
  tests layout des 2 drivers.

- [ ] **P0-G.6 — [LOW-MED, borderline] Coercion scalaire TOML qui contourne le codec
  partagé.** 4 sites hand-roll la coercion (strip quotes, unescape, bool/number, split
  array quote-aware) au lieu de passer par `_shared/lua/toml_codec/` : macOS
  `lib/config_overrides.lua:74` `M.coerce` ; Windows `lib/config_shortcuts.ahk:107`
  `CS_CoerceValue`, `lib/toml/toml_loader.ahk:631` `TomlCoerceValue`,
  `lib/toml/toml_config_loader.ahk:64` `TomlCoerceValueExt` (commentaire :69 admet « same
  algorithm as CS_CoerceValue »). Le corpus TOML partagé est parser-level seulement.
  **Fix** : router les 4 via `toml_codec` (ou y ajouter la coercion) + étendre le corpus
  toml avec des vecteurs de coercion. ⚠️ **Confirmer avec le mainteneur** si la coercion
  doit vivre dans le codec partagé avant d'agir.

- [ ] **P0-G.7 — [LOW] Formatters de libellés de menu cosmétiques.** Petites dérivations
  dupliquées macOS↔AHK (Linux 3ᵉ copie divergente) : map libellé+emoji du niveau de log
  (`windows/ui/menu/menu_rebuild.ahk:106/:129` ↔ `macos/ui/menu/builder.lua:487`) ;
  formateur de compte avec séparateur de milliers (`windows/lib/menu_helpers.ahk:199`
  `FmtCount` ↔ `macos/ui/menu/hotstring_counter.lua:51` `fmt_grand`) ; décoration
  d'en-tête de section (`menu_helpers.ahk:217` ↔ `macos/lib/i18n.lua:286`) ; toggle de
  catégorie (`windows/ui/menu/menu_gestures.ahk:125` ↔ `macos/ui/menu/menu_utils.lua:25`).
  Linux `menu_builder.lua:69` ajoute un `" ✓"` littéral, sans manifeste ni i18n.
  **Basse priorité** (cosmétique, stable). Optionnel : `_shared/lua/menu/labels.lua` +
  mini-corpus. NB : le **graphe de grisage `disabled_when` (MG-1)** est **déjà fermé**
  (résolu depuis le manifeste par les 2 drivers via `resolve_disabled_when`) — ne PAS
  rouvrir.

### P0-H — Duplications intra-Linux mineures *(Tier 3, à faire en passant)*

- [ ] **P0-H.1** Cap ring WPM `2000` : `linux/modules/keylogger/metrics_collector.lua:60`
  (`WPM_RING_CAPACITY`, nommé) vs `linux/modules/keylogger/keylogger.lua:153` (littéral
  brut). Référencer la constante ; envisager hoist vers
  `_shared/lua/keylogger/metrics.lua` (`M.DEFAULT_WPM_RING_CAPACITY`, à côté de
  `DEFAULT_CHARS_PER_WORD`).
- [ ] **P0-H.2** Liste apps « champ sécurisé » définie 3× côté Linux, divergente :
  `linux/modules/keylogger/keylogger.lua:50-53` **et** re-typée `:85`, + liste
  divergente `linux/adapters/secure_field_detector.lua:41-52` (`keepass` vs
  `keepassxc`…). Faire déléguer `keylogger.lua` à l'adaptateur. (Pas de partage
  cross-driver : identifiants OS-spécifiques.)

*(Exceptions ACCEPTÉES — ne PAS re-signaler : littéraux updater AHK sous drift-gate
`test-updater-constants-single-source`; noms de modèles LLM par plateforme
(`defaults.json:27`); tunables OS-only Linux (délais ydotool, poll process_lifecycle,
ping 8.8.8.8, batch pump 50); bornes de port 1024/65535 ; `text_sender`
CLIPBOARD_THRESHOLD miroir d'un spec JS ; fallbacks `"fr"`/`"qwerty"` défensifs
basse sévérité. Détail dans l'audit SSoT.)*

---

## PRIORITÉ 1 — Rendre le daemon Linux FONCTIONNEL (il est inerte aujourd'hui)

> Le driver Linux (~13 k lignes) **ne fait rien à l'exécution** : la saisie clavier
> n'atteint jamais les features. Ces bugs sont petits mais bloquants — les corriger
> fait passer hotstrings + keylogger + LLM de « morts » à « fonctionnels ». Tous
> vérifiables par test unitaire (chargement de module + mock), pas besoin de Linux réel
> sauf mention *daemon-only*.

- [ ] **P1.1 — 🔴 CRITIQUE : pipeline de saisie mort.** `linux/adapters/keyboard_hook.lua:306`
  fait `if ch and _on_char then pcall(_on_char, ch)` mais **`ch` n'est jamais
  assigné** dans `_pump_one()` (236-311) ; le helper `_resolve_char(code)`
  (`:319-373`) n'est **jamais appelé**. Aucun caractère n'atteint `on_char` → hotstrings,
  keylogger, LLM reçoivent zéro entrée. **Fix** : soit assigner
  `local ch = _resolve_char(ev.code)` avant `:306`, soit (préférable) câbler le reader
  evdev **déjà complet et testé** `linux/modules/hotstrings/input_reader.lua`
  (`M.new(...)` → `reader:start()`, ouvre `/dev/input/eventN`, décode, résout via
  layout partagé, fire `on_char` `:354`) dans `linux/ergopti_hotstrings.lua:369` à la
  place du `keyboard_hook` cassé. Puis dé-dupliquer (P0-E.1). Test : charger le daemon
  avec un evdev mocké, injecter un event, asserter que `on_char` reçoit le caractère.
- [ ] **P1.2 — nil-global (même classe que menu_karabiner).** Déplacer les définitions
  au-dessus de leurs usages + test de chargement par module :
  - `linux/modules/llm/prediction_engine.lua:244,262` : `_build_system_prompt` /
    `_build_user_context` (`local function`) définis **après** `M.predict` (`:151`)
    qui les utilise (`:174-175`) → `predict()` plante.
  - `linux/adapters/tray_menu.lua` : `_registry` (`:110`) et `_signal_file` (`:113`)
    déclarés **après** `_serialize_menu` (`:94,:99`) qui les lit → erreur au 1ᵉʳ `setMenu`.
- [ ] **P1.3 — bugs d'arguments de câblage daemon** (`linux/ergopti_hotstrings.lua`) :
  - `:340` `prediction_engine.on_char(ch)` sans l'arg `buffer` → `prediction_engine.lua:128-130`
    early-return → LLM ne prédit jamais. Passer le buffer.
  - `:308` `window_info.getActiveAppID()` — **méthode inexistante** (l'adaptateur
    expose `getFocused`) → `app_id` toujours nil → stats par app + garde password vides.
- [ ] **P1.4 — regex Ollama en syntaxe PCRE dans un motif Lua.** `linux/modules/llm/api_ollama.lua:138`
  `'"content"%s*:%s*"(([^"\\]|\\")*)"'` : `|` est un littéral en motif Lua → parse
  streaming cassé. Utiliser le `json` partagé / `_shared/lua/llm/parser.lua`.
- [ ] **P1.5 — 🐧 boucle d'événements absente.** `linux/ergopti_hotstrings.lua:420-425`
  est un `while … pump()` busy-loop **sans `luv.run()`** ; `linux/adapters/timer_scheduler.lua`
  ne marche qu'avec `luv` (`:53`, sinon `after()` dropé silencieusement `:71,106`) ;
  `linux/adapters/process_lifecycle.lua:207` `M.tick()` jamais appelé. Adopter une
  boucle `luv` (ou intégrer luv au pump) et pumper `process_lifecycle.tick`. Sans ça :
  debounce, warmup LLM, updater bg, timers d'inactivité, focus-poll = morts.
- [ ] **P1.6 — 🐧 dépendances Lua non vendorisées** (`vendor/` absent du repo, cf.
  `linux/README.md:78`). Vendoriser/déclarer : **luv** (boucle+timers, P1.5), **luaposix**
  (`posix.signal`, hot-reload/shutdown `ergopti_hotstrings.lua:230-254`), **lgi**
  (GTK/WebKit2GTK P2.2/P2.4 + GDBus SNI P2.1), **lfs** (optionnel), lua-http (async
  prévu). Tant qu'elles manquent, timers/signaux/webviews/tray SNI ne peuvent pas
  fonctionner même une fois câblés. Documenter l'install (script `install.sh` +
  paquets .deb/.rpm/AUR déjà présents — ajouter les deps).
- [ ] **P1.7 — mismatch `:` vs `.`** `linux/modules/menu/menu_builder.lua:67,72`
  appelle `config:is_group_enabled`/`config:toggle_group` (self implicite) mais les
  fonctions sont plates (`linux/modules/hotstrings/hotstrings_config.lua:179,188`).

---

## PRIORITÉ 2 — Parité feature-by-feature Linux (viser 100 % macOS/Windows)

> Cible de parité = inventaire complet des drivers mûrs (voir `PLAN` + inventaires
> Windows/macOS). Statut Linux : **A** = fait + partage `_shared` ; **B** = partiel ;
> **C** = stub (natif manquant) ; **D** = absent. La plupart des gaps sont du
> **câblage d'adaptateur** — la logique `_shared` existe déjà (vérifié). Ordre =
> centralité produit. Presque tout est 🐧 *daemon-only* (vérifiable seulement sur Linux réel).

### P2.1 — Tray SNI/dbusmenu (remplacer le shell-out `yad`) — statut **C/B**
- Actuel : `linux/adapters/tray_menu.lua` = `yad --notification` + `--menu` plat,
  callbacks par fichier-signal + `pump()` ; `:23` « no-ops si yad absent » ; `:90`
  placeholder bash. Menu **plat** avec faux en-têtes `"… ▼"` désactivés
  (`linux/modules/menu/menu_builder.lua:291,299,307,315,323`) ; la plupart des actions
  ne font que `Logger.info` (changement layout `:394`, restart `:220,226`, stats `:166`).
  **Aucun item n'ouvre d'éditeur / updater / picker de langue / config tap-hold.**
- Logique partagée **existe** : `_shared/lua/linux/tray_protocol.lua` construit le XML
  **StatusNotifierItem / com.canonical.dbusmenu** récursif (`build_menu_item_xml:27`,
  `build_dbus_menu_xml:67`) — ignoré par l'adaptateur.
- [ ] **À faire** : remplacer yad par SNI/dbusmenu via `tray_protocol.lua` + enregistrement
  D-Bus (gdbus/dbus-send ou lgi/GDBus) + boucle d'événements (P1.5) ; corriger le
  scoping `_registry`/`_signal_file` (P1.2) ; construire **l'arbre de menu complet**
  (miroir macOS §9 : Disposition/Hotstrings/IA/Métriques/Raccourcis/Karabiner→kanata/
  Gestes/Apps/Actions globales/Langue/Config/Assistant/Version/Recharger/Quitter/Débogage)
  avec items qui lancent réellement les webviews (P2.2). Test conformité adaptateur.

### P2.2 — Host WebKitGTK (rendu des 14 éditeurs) — statut **C→D (injoignable)**
- Les 14 apps `_shared/ui/*` existent ; le **rendu est stubbé** :
  `linux/modules/ui/webview_manager.lua:274` « _create_gtk_window: stub … would load »,
  `:282` destroy stub, `:289` focus stub ; probe GTK exige lgi (`:51-63`, absent).
  `linux/ui/webkit_host.lua:6-8` dit que les vrais appels GTK « vivent dans
  l'entry point natif (ergopti.lua) » — **`ergopti.lua` n'existe pas.** Le daemon ne
  `require` jamais `webview_manager`/`webkit_host` → chaque éditeur est **D** pour l'utilisateur.
- Logique partagée **existe** : `webkit_host.build_app_html` (HTML+i18n) est réel ;
  `toml_codec.writer` (persistance) existe.
- [ ] **À faire** : implémenter la vraie création de fenêtre lgi/WebKit2GTK dans
  `webview_manager._create_gtk_window` (+ destroy/focus) ; enregistrer les
  `script-message-handler` pour les 14 bridges (`webkit_host.lua:25-40`) ; câbler
  `webview_manager` dans le daemon + les items de menu (P2.1). 🐧 *daemon-only*.

### P2.3 — Bridge handlers webview (8 manquants + persistance stubbée) — statut **C**
- 6/14 handlers existent (`linux/modules/ui/bridge_handlers/` : action_picker,
  hotstrings_config, healthcheck, onboarding, prompt_editor, metrics_typing). **8
  manquants** (registry `webkit_host.lua:25-40`) : `changelog_bridge`, `dl_bridge`,
  `hsEditor` (hotstring editor), `hsPaths`, `hsPersonalInfo`, `model_browser_bridge`,
  `token_bridge`, `personal_toml_editor`. Et les écritures existantes sont fausses :
  `hotstrings_config_bridge.lua:85-94` (add/delete → log + `{added=true}`, pas d'écriture
  TOML), `prompt_editor_bridge.lua:73-76` (save → log), `onboarding_bridge.lua:28-50`
  (chaque étape → `{accepted=true}`, pas de persistance),
  `action_picker_bridge.lua:34-37` (execute → log, retourne nil). Bug : nom
  `metrics_typing_bridge.lua:10` = `"metrics_apps_bridge"` (mismatch).
- [ ] **À faire** : écrire les 8 handlers manquants ; faire persister les écritures via
  `toml_codec.writer` (existe) ; corriger le nom du bridge metrics.

### P2.4 — Tooltip de prédiction (cairo/GTK) — statut **C**
- `linux/adapters/tooltip_renderer.lua` = popup **yad/zenity par affichage** (`:126`),
  n'extrait que `.text` des draw_calls partagés (`:109-118`) — pas de couleurs/layout,
  impraticable pour du streaming par frappe. `linux/adapters/graphics_renderer.lua:36`
  `_renderer_available = false` ; `:53` « no native renderer — returning stub » ; tout
  no-op (`:61-84`). `README.md:124` admet cairo non fait.
- Modèle de dessin tooltip partagé **existe** (`_shared/modules/tooltip/*`).
- [ ] **À faire** : vrai overlay cairo/GTK layer-shell (ou canvas lgi) consommant
  `_shared/modules/tooltip/{draw_calls,layout,tint,lifecycle}`. 🐧 *daemon-only*.

### P2.5 — Tap-hold / home-row-mods via kanata — statut **B/C**
- Design (`README.md:49,119`) : déléguer à **kanata** (daemon Rust, /dev/input+uinput).
  `.kbd` **statique** shippé (`static/ergopti_plus/kanata/kanata.kbd`) ; `install.sh:177-199`
  télécharge le binaire, `:255-269` symlinke le `.kbd`. **Aucune orchestration** :
  personne n'appelle le générateur partagé `_shared/lua/tap_hold/kanata_generator.lua`
  (`generate(keys,opts)`) ; le `.kbd` n'est pas généré depuis le TOML utilisateur ;
  `install.sh` ne **lance** jamais kanata (pas de `kanata.service`) ; pas de menu/onboarding.
- Générateur partagé **existe** (testé `tests/unit/meta/test_kanata_generator.lua`).
- [ ] **À faire** : module Linux qui lit `tap_hold.toml` → `kanata_generator.generate`
  → écrit le `.kbd` → gère le process kanata (unit systemd) + câblage menu/onboarding
  (réglage des temps d'activation par touche). 🐧 *daemon-only*.

### P2.6 — Dynamic hotstrings / perso-info (@-tags) — statut **D**
- Aucun module Linux (`dynamic_hotstring|personal_info` → seulement tests/README).
  Moteur partagé `_shared/lua/dynamic_hotstrings/init.lua` **existe**, jamais câblé.
- [ ] **À faire** : module Linux qui charge `personal_info.toml` (schéma
  `_shared/core/config_schema/examples/personal_info.example.toml`), alimente le moteur
  partagé, injecte (via `injector.lua` existant) ; + éditeur (bridge P2.3).

### P2.7 — Raccourcis clavier (wrap-symbols, casse, capsword, manip texte) — statut **D**
- Aucun module Linux (`wrap_symbol|capsword|case` → tests/README). Données partagées
  existent (`_shared/modules/wrap_symbols/wrap_symbols.json`, `_shared/lua/text_utils/init.lua`,
  `_shared/lua/keymap/utils.lua`). Cible : macOS `modules/shortcuts/*`.
- [ ] **À faire** : module raccourcis Linux (nécessite un grab clavier intercept —
  dépend de P1.1 + evtest --grab ou une couche kanata). 🐧 *daemon-only*.

### P2.8 — Keylogger → schéma SQLite partagé — statut **B**
- Collecte pure-Lua réelle (WPM/ngrams/perApp/password) et partage `keylogger.metrics`
  + `lib.timings`. Mais persiste en JSON (`linux/modules/keylogger/keylogger.lua:263`)
  au lieu du schéma SQLite partagé (`_shared/data/db/…`) que lit le dashboard ; `app_id`
  jamais peuplé (bug P1.3).
- [ ] **À faire** : brancher le keylogger sur le schéma SQLite partagé (ou faire lire le
  JSON par le dashboard) ; corriger `getActiveAppID` (P1.3). Dépend de P1.1.

### P2.9 — Updater / self-update — statut **D**
- Aucun module updater Linux. `_shared/lua/updater/version.lua` **existe** (compare de
  versions ; macOS délègue déjà, vérifié). Cible : macOS `lib/updater.lua` (canaux
  main/dev, download, intégrité, timer bg).
- [ ] **À faire** : updater Linux (check release GitHub via `http_client` curl,
  download+vérif, self-replace, switch canal, câblage menu). Dépend de P1.5 (timer bg).

### P2.10 — i18n / locale (21 langues) — statut **B (réel mais non câblé)**
- `linux/lib/locale.lua` réel (charge `_shared/data/locales/<code>.json`, fallback
  en→fr, substitution ★ `:135-152`) ; `linux/lib/i18n.lua` wrapper. Mais jamais utilisé
  par daemon/menu (strings tray en dur en français `menu_builder.lua`) ;
  `locale.set_trigger_provider` jamais appelé → ★ non substitué ;
  `i18n.set_locale_injector` no-op documenté (`i18n.lua:63-66`) ; pas de picker langue ;
  pas de persistance (utiliser `linux/adapters/storage.lua`, existe, non utilisé).
- [ ] **À faire** : router les strings menu/UI via `i18n.get`, injecter le trigger
  provider, ajouter la sélection de langue + persister via `storage`.

### P2.11 — Gestes trackpad (libinput) — statut **D** *(basse priorité)*
- Absent. Moteur de gestes **macOS-only** (pas de logique partagée). Nécessiterait une
  intégration libinput touchpad from scratch. 🐧 *daemon-only*. À traiter en dernier.

### P2.12 — Dashboards métriques (charts/heatmap) — statut **C**
- Même blocage rendu que P2.2. `metrics_typing_bridge` lit des stats réelles mais
  payload minimal (`_build_initial_payload:18-46`) vs dashboard partagé plus riche.
- [ ] **À faire** : rendu GTK (P2.2) + payload adossé au SQLite partagé (P2.8).

### P2.13 — Diagnostics de parité (optionnel) — statut **D**
- Pas de crash reporter (macOS `lib/crash_reporter`), pas de profilers boot/hotpath,
  pas de vscode bridge, pas de keep-awake. Parité « nice-to-have ».
- [ ] **À faire** (optionnel/tard) : porter crash_reporter + profilers si parité stricte voulue.

---

## Récapitulatif des dépendances / ordre conseillé

1. **Priorité 0** (SSoT) — indépendant, faisable tout de suite, testable sur Windows.
   Commencer par P0-A (géométrie webview, 9 dérives actives) et P0-B (LLM Linux).
2. **Priorité 1** dans l'ordre : P1.6 (vendoriser luv/lgi/posix) → P1.5 (boucle
   d'événements) → P1.1 (saisie) → P1.2/P1.3/P1.4/P1.7 (bugs). Après ça le daemon
   **fonctionne** (hotstrings + keylogger + LLM).
3. **Priorité 2** : P2.1 (tray, débloque l'accès aux features) → P2.2/P2.3 (webviews +
   handlers) → P2.5 (kanata) → P2.6/P2.8/P2.9/P2.10 → P2.4 (tooltip) → P2.12 → P2.7 →
   P2.11/P2.13.

## Tests / gates à livrer (règle §5.9)

- Parité géométrie webview (P0-A.4) ; single-source keep_alive/port/temp/context (P0-B) ;
  single-source constantes prompt_builder (P0-C) ; timeouts Timings (P0-D) ; keycode/version
  single-source (P0-E) ; buffer-cap parité (P0-F) ; corpus keylogger agrégation (P0-G).
- Chargement-sans-crash par module pour tout `.lua` Linux touché (P1.1/P1.2) — attrape la
  classe nil-global. Test daemon : event evdev mocké → `on_char` reçoit le char (P1.1).
- Conformité adaptateurs Linux : chaque méthode de port appelée, pas d'erreur (déjà
  partiellement en place — étendre au tray SNI, tooltip cairo, webview host).
- Golden corpus kanata (existe, `test-kanata-defalias-parity`) — étendre à la génération
  depuis le TOML utilisateur (P2.5).
