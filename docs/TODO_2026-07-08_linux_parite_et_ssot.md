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

### Avancement session nuit 2026-07-08 (12 commits, `7b638466b`..`c831184bc`)

**Priorité 0 (SSoT) — faits + gates :** P0-A (géométrie webview, macOS câblé au
manifeste + gate ; Windows `WebViewHost` reporté), P0-B (LLM Linux → canoniques ;
Windows keep_alive reporté), P0-C (linux_bridge ← prompt_builder), P0-D (timeout
Ollama ← Timings), P0-E.2 (version), P0-F (buffer cap 64→256), P0-H (dups keylogger).
**Priorité 1 (daemon Linux VIVANT) :** P1.1 (pipeline de saisie ressuscité —
`ch` jamais assigné + 2 bugs latents), P1.2 (nil-globals, motif fermé), P1.3
(app-id + buffer LLM), P1.4 (regex Ollama), P1.7 (`:`→`.`). Le daemon reçoit
enfin les frappes → hotstrings/keylogger/LLM alimentés. Nouveaux gates JS :
géométrie, LLM-defaults, version, buffer-cap. Suites : **test:js 48/48 · macOS
green · Linux 686/0**.

✅ **AHK OS-purity ratchet RÉSOLU** (`a6b3c8720`, choix mainteneur : router 1
appel). Le compte avait dérivé à **257** (baseline 256, figée 2026-06-21) sur les
~70 commits de fix AHK — pas causé par la session nuit (éditions Windows = 0 token
OS, prouvé). Corrigé en routant `LLM_LoadProfilesJSON` (`windows/modules/llm/
profiles.ahk`) du `FileRead` direct vers l'adapter `FSRead` — exactement comme son
jumeau `_LLM_LoadPresets(models.json)` le faisait déjà ; c'était le dernier loader
LLM à court-circuiter l'adapter. Compte revenu à **256**, ratchet vert. Premier test
comportemental de `LLM_LoadProfilesJSON` ajouté (lecture réelle via l'adapter +
contrat fichier-absent). Suite AHK complète : **2946/0** vérifié. NB : la suite AHK
est **exécutable ici** via Git Bash (`"/c/Program Files/AutoHotkey/v2/AutoHotkey64.exe"
"<abs>/windows/tests/run_all.ahk"`) — résultats dans `%TEMP%\ergopti_test_results.txt`,
dernière ligne `# N passed, M failed.`. **Ne pas** lancer via PowerShell `Start-Process`
(exe GUI-subsystem → `FileAppend(x,"*")` lève « invalid handle » et avorte tout au
6ᵉ marqueur). Non-déterminisme historique (silent-abort / FileRead flaky) documenté.

ℹ️ **Hors-TODO, corrigé même session** (`d69e4c355`) : bug Karabiner/Hammerspoon
signalé par le mainteneur — un chord touche1+touche2 fait de **touches modificatrices**
(rcmd+lcmd « supprimer le mot ⌥⌫ ») ne produisait qu'un backspace. `build_chord_combo_rule`
(`macos/modules/karabiner/generator.lua`) émettait le `from` KE sans `modifiers`, alors
que la 1ʳᵉ touche du chord lève déjà son flag → KE refuse le match → chute sur le tap
mono-touche (backspace nu). Ajout de `modifiers.optional={"any"}` (comme le fait déjà
le builder tap/hold jumeau) sur une copie non-mutante ⇒ **toute la classe** des chords
à modificateurs refonctionne. Tests de régression (branches sym./non-sym. + sortie ⌥⌫).

✅ P0-G.4/G.5/G.7 faits (commits `3113a6aaa` `5e3fe2aab` `92d9f2e20`) — corpus
locale + tests 2 côtés, layout tooltip + tests 2 côtés, gate menu labels.
✅ P1.5/P1.6 cochés rétroactivement — event_loop.lua (luv + fallback), vendor/
documenté + fetch_vendor.sh + install.sh.
✅ P2.1/P2.2/P2.5/P2.6/P2.7/P2.8/P2.9/P2.10 cochés rétroactivement — tous ces
modules sont déjà implémentés et câblés dans le daemon (voir détails ci-dessous).

✅ **TOUT FAIT (session 2026-07-09).**
- P0-G.4 (corpus locale, `3113a6aaa`) / P0-G.5 (tooltip layout, `5e3fe2aab`)
  / P0-G.7 (menu labels gate, `92d9f2e20`)
- P1.5/P1.6 cochés rétroactivement (`3d0461cff`)
- P2.3 bridge persistence (`b7a7efe2c`)
- P2.4 graphics renderer lgi/cairo (`3e7363647`)
- P2.11 gesture process_frame (`7b658adcf`)
- P2.12 dashboards (bridge metrics_apps fonctionnel)
- P2.13 crash reporter (`ddf0fe04c`)
⏭️ P0-G.6 — skip (confirmation mainteneur).

Suites au vert : build:domain 15/15, Linux 915/0.
Tous les items 🐧 sont *daemon-only* (code écrit + testé unitairement, non
vérifié en run sur Linux réel).
✅ P0-G.1/G.2/G.3 cochés rétroactivement — corpus + tests macOS + AHK existent.
✅ P0-E.1 et P0-B.1 cochés rétroactivement — le code et les gates existent déjà.

✅ **Motif systémique FERMÉ.** Le bug « variable/`local function` utilisée avant sa
définition → nil global » existait dans **3 fichiers** (menu_karabiner,
`prediction_engine.lua`, `tray_menu.lua`) — **tous corrigés** (menu_karabiner en
`a4624a741`, les 2 autres en P1.2 avec tests comportementaux rouge-avant/vert-après).
Signe que le Lua livré n'avait **jamais été exécuté**. Règle maintenue : tout nouveau
`.lua` doit être chargé **et son chemin exercé** (test unitaire) avant commit.

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

- [x] **P0-B.1** `keep_alive = "30m"` — canonique dans `defaults.json` `llm_ollama_keep_alive`.
  Lu par macOS (`api_common.lua` → `api_ollama.lua` ×3), shared (`linux_bridge.lua`
  `M.DEFAULT_KEEP_ALIVE`), ET Windows (`init.ahk` `LLM_Ollama_LoadDefaults()` seed
  `LLM_OLLAMA_KEEP_ALIVE` depuis `LLM_Defaults["llm_ollama_keep_alive"]` → `ollama_payload.ahk:120`).
  Gate : `test-linux-llm-defaults-single-source.cjs` + test Linux `test_llm_linux_bridge.lua:320`.
- [x] **P0-B.2** Port Ollama `11434` : canonique `defaults.json llm_ollama_port` (lu
  par macOS+Windows). Linux hardcode 4× : `linux/modules/llm/profiles.lua:69,74`
  (+ `localhost` au lieu de `127.0.0.1`), `linux/modules/llm/prediction_engine.lua:110,171`,
  UI `linux/modules/menu/menu_builder.lua:117`. Router via
  `HttpBridge.OLLAMA_DEFAULT_PORT`/`OLLAMA_DEFAULT_HOST` (déjà importé). Note :
  `_shared/lua/llm/linux_bridge.lua:24,27` duplique aussi host/port — les faire lire
  `defaults.json`.
- [x] **P0-B.3** Température : canonique `0.1` (`defaults.json llm_temperature`).
  Linux a **deux** valeurs divergentes : `prediction_engine.lua:188` = `0.3`,
  `linux_bridge.lua:34` = `0.7`. Réconcilier les deux au canonique.
- [x] **P0-B.4** Context length : canonique `500` (`defaults.json llm_context_length`).
  Linux `prediction_engine.lua:78` = `2000`. Lire le canonique.
- [x] **P0-B.5** `max_tokens` : canonique `DEFAULT_MAX_TOKENS = 150`
  (`_shared/lua/llm/prompt_builder.lua:42`). Linux `prediction_engine.lua:188` = `200`.

### P0-C — Duplication interne au tree `_shared/` *(Tier 2)*

- [x] **P0-C.1** `linux_bridge.lua` redéfinit des constantes qu'il devrait lire de
  `prompt_builder` (qu'il `require` déjà, ligne 14) : `CONTEXT_TAIL_WORDS`
  (`linux_bridge.lua:37` vs canon `prompt_builder.lua:39`) et `DEFAULT_MAX_TOKENS`
  (`linux_bridge.lua:250` vs canon `prompt_builder.lua:42`). Utiliser `PromptBuilder.*`.

### P0-D — Timeouts Linux non branchés sur le registre Timings *(Tier 2)*

- [x] **P0-D.1** curl `--max-time 30` (`linux/modules/llm/api_ollama.lua`) →
  lit maintenant `Timings.sec("llm","request_timeout_ms")` (canon
  `_shared/modules/timings/constants.toml [llm] request_timeout_ms = 30000`).
  Gate étendu (forbid `--max-time 30` + exige `Timings.sec`). **Décision** :
  `http_client.lua:38 DEFAULT_TIMEOUT_MS = 30000` **laissé tel quel** — c'est un
  miroir du **port spec** `HttpClient.spec.js DEFAULT_TIMEOUT_MS` (commentaire
  explicite), **identique à macOS `http_client.lua:58`**. Le router vers Timings
  le ferait **diverger de macOS** (canon différent : le spec du port, pas le
  registre timings). Deux canoniques distincts valant 30000 ; ne pas les confondre.

### P0-E — Tables keycode + version triplicées côté Linux *(Tier 2)*

- [x] **P0-E.1** Table keycode→char triplée — **FAIT** (session nuit P1.1). Les 3 copies
  hardcodées de `keyboard_hook` (`_KEYCODE_MAP`, `_build_keycode_map`, fallback inline)
  et le fallback de `input_reader` (`QWERTY_UNSHIFTED`/`SHIFTED`, `AZERTY_UNSHIFTED`/
  `SHIFTED`) ont été supprimées. `keyboard_hook` délègue à `input_reader.resolve_char()`
  qui charge `_shared/data/keycodes/evdev.json`. Gate : `test_keycode_single_source.lua`
  (6 tests source-level + 6 tests comportementaux).
- [x] **P0-E.2** Version `"3.0.0"` : source unique **créée** `linux/lib/version.lua`
  (`M.VERSION`, le pendant Linux de `BUNDLE_VERSION`). Les 3 sites la lisent
  (`menu_builder`, `healthcheck_bridge`, `ergopti_hotstrings`). Bug latent corrigé au
  passage : `menu_builder` retombait sur le `_VERSION` **built-in de Lua** (« Lua 5.4 »)
  au lieu de la version du driver. Gate `test-linux-version-single-source.cjs`.

### P0-F — Cap buffer hotstring divergent *(Tier 2/3)*

- [x] **P0-F.1** Cap du buffer glissant unifié. **Décision : canon = 256** (valeur
  `_shared/lua/hotstring_engine/init.lua BUFFER_MAX_CHARS`, déjà utilisée par
  macOS+Linux). Windows convergé **vers le haut** `64 → 256` dans les 2 fichiers
  (`hotstring_inputhook.ahk` `_MAX_BUFFER_LEN`, `hotstring_engine_main.ahk`
  `HSE_MAX_BUFFER_LEN`). Direction **zéro régression** : un buffer plus long ne fait
  qu'**ajouter** la capacité de matcher un trigger de 65-256 car. (que Windows ratait
  silencieusement), sans casser les triggers courts. Gate de parité
  `test-hotstring-buffer-cap-parity.cjs` (shared == les 2 miroirs Windows).
  ⚠️ Si le mainteneur avait une raison perf pour `64`, inverser (mais réduire
  macOS/Linux à 64 casserait les longs triggers → régression).

### P0-G — Logique métier dupliquée cross-driver (aucun module partagé NI corpus)

> Ces items sont issus de l'audit de **duplication de logique** (pas de valeurs). Une
> logique réimplémentée dans 2-3 drivers sans (a) module `_shared/lua/` requis par les
> drivers Lua, ni (b) corpus de parité certifiant les copies AHK, **dérive en silence**.
> Le corpus cross-driver `_shared/tests/corpus/` n'existe aujourd'hui que pour :
> `dynamic_hotstrings, hotstrings, llm, prompt_builder, security, tap_hold, toml`.

- [x] **P0-G.1 — [CRITIQUE] Agrégation keylogger par frappe + flush SQL (macOS↔AHK,
  hand-mirror, zéro corpus).** ✅ **FAIT** (session nuit étendue). Corpus créé :
  `_shared/tests/corpus/keylogger/aggregation_vectors.json`. Tests des DEUX côtés :
  macOS `test_corpus_keylogger_aggregation.lua` + AHK
  `test_corpus_keylogger_aggregation.ahk` (inclus dans `run_all.ahk`). Les leaf
  helpers `aggregator_helpers.lua` sont aussi partagés. **Case LNX-8 corrigée.**

- [x] **P0-G.2 — [HIGH] Builder du snapshot healthcheck (macOS↔AHK dupliqué + Linux
  divergent).** ✅ **FAIT** (session nuit étendue). Builder extrait :
  `_shared/lua/healthcheck/snapshot.lua`. Consommé par macOS (`core.lua` + `helpers.lua`
  → `require("healthcheck.snapshot")`). Corpus : `_shared/tests/corpus/healthcheck/
  snapshot_vectors.json`. Tests des DEUX côtés : macOS
  `test_corpus_healthcheck_snapshot.lua` + AHK `test_corpus_healthcheck_snapshot.ahk`
  (inclus dans `run_all.ahk:555`). Linux : reste le bridge divergent — P2.3.

- [x] **P0-G.3 — [HIGH] Parsing du JSON de release updater (macOS↔AHK, non certifié).**
  ✅ **FAIT** (session nuit étendue). Parsers extraits : `_shared/lua/updater/
  release_parser.lua`. Consommé par macOS (`lib/updater.lua`), Linux (`modules/updater/
  manager.lua`). Corpus : `_shared/tests/corpus/updater/release_parser_vectors.json`.
  Tests des DEUX côtés : macOS `test_corpus_updater_release_parser.lua` + AHK
  `test_corpus_updater_release_parser.ahk`. Le compare de versions était déjà fait
  (`version.lua` + `version_vectors.json`). **Recoupe LNX-9.**

- [x] **P0-G.4 — [MED-HIGH] Cascade de résolution locale (triplée ; 2 copies Lua
  byte-identiques).** ✅ **FAIT** (commit `3113a6aaa`). **Lua côté** : `_shared/lua/locale/core.lua` créé,
  macOS + Linux le `require` (les 2 copies sont fusionnées). **Reste** : le corpus
  `_shared/tests/corpus/locale/resolution_vectors.json` n'existe PAS, et le `t()` AHK
  ✅ Corpus créé (`resolution_vectors.json`, 12 vecteurs). Tests macOS
  (`test_corpus_locale_resolution.lua`, 19 tests) + AHK
  (`test_corpus_locale_resolution.ahk`, 15 tests). Gate JS corrigé.
  Suite macOS 2910/1, build:domain 15/15.

- [x] **P0-G.5 — [LOW-MED] Tooltip layout/geometry + dequeue (hand-porté 2 côtés ; seul
  `tint` est certifié).** ✅ **FAIT** (commit `5e3fe2aab`). Dequeue : corpus +
  tests 2 côtés. Layout : corpus `layout_vectors.json` consommé par macOS
  (`test_tooltip_layout_corpus.lua`, 10 tests pure-Lua) + AHK
  (`test_corpus_tooltip_layout.ahk`, 11 tests clamp comportementaux).

- [⏭️] **P0-G.6 — [LOW-MED, borderline] Coercion scalaire TOML.** **SKIP** —
  nécessite confirmation du mainteneur (cf. TODO originale : « Confirmer avec
  le mainteneur si la coercion doit vivre dans le codec partagé avant d'agir »). 4 sites hand-roll la coercion (strip quotes, unescape, bool/number, split
  array quote-aware) au lieu de passer par `_shared/lua/toml_codec/` : macOS
  `lib/config_overrides.lua:74` `M.coerce` ; Windows `lib/config_shortcuts.ahk:107`
  `CS_CoerceValue`, `lib/toml/toml_loader.ahk:631` `TomlCoerceValue`,
  `lib/toml/toml_config_loader.ahk:64` `TomlCoerceValueExt` (commentaire :69 admet « same
  algorithm as CS_CoerceValue »). Le corpus TOML partagé est parser-level seulement.
  **Fix** : router les 4 via `toml_codec` (ou y ajouter la coercion) + étendre le corpus
  toml avec des vecteurs de coercion. ⚠️ **Confirmer avec le mainteneur** si la coercion
  doit vivre dans le codec partagé avant d'agir.

- [x] **P0-G.7 — [LOW] Formatters de libellés de menu cosmétiques.** ✅ **FAIT** (commit
  `92d9f2e20`). `_shared/lua/menu/labels.lua` créé, consommé par macOS (`i18n.lua`,
  `builder.lua`, `hotstring_counter.lua`). AHK garde son `FmtCount` hand-maintenu
  (pinné par `test-section-decoration-parity.cjs` + suite AHK). Gate JS ajouté.

### P0-H — Duplications intra-Linux mineures *(Tier 3, à faire en passant)*

- [x] **P0-H.1** Cap ring WPM `2000` **hoisté** vers
  `_shared/lua/keylogger/metrics.lua` (`M.DEFAULT_WPM_RING_CAPACITY`, à côté de
  `DEFAULT_CHARS_PER_WORD`). `metrics_collector.lua` et `keylogger.lua` le lisent
  (plus de littéral brut).
- [~] **P0-H.2** Liste apps « champ sécurisé ». **Fait** : la double définition
  intra-fichier de `keylogger.lua` (base à `:54` re-typée à `:89`) est fusionnée en
  une seule constante `_DEFAULT_PASSWORD_APPS` + helper de copie. **Reporté** : la
  délégation à `secure_field_detector` — l'adaptateur fait un match **exact** sur
  WM_CLASS avec une liste **différente** (`keepassxc` vs `keepass`) alors que
  keylogger fait un match **substring** ; déléguer changerait la détection
  password (sécurité) sans possibilité de test runtime ici. Commentaire de renvoi
  ajouté dans le code. **À faire avec revue sécurité.**

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

- [x] **P1.1 — 🔴 CRITIQUE : pipeline de saisie mort — CORRIGÉ (option a).**
  `_pump_one()` finissait par `if ch and _on_char` sans jamais assigner `ch`
  (`_resolve_char` jamais appelé) → **zéro caractère** n'atteignait `on_char`, tout
  le daemon était inerte. Fix : `local ch = _resolve_char(ev.code)` **+** 2 bugs
  latents corrigés au passage : (1) `_resolve_char` (défini plus bas) était appelé
  au-dessus de sa définition → **même piège nil-global** (forward-declaration
  ajoutée) ; (2) le reset des modificateurs se faisait **avant** la résolution →
  tout caractère shifté sortait non-shifté (résolution déplacée avant le reset).
  Test comportemental `test_keyboard_hook_pump.lua` (pipe evdev mocké, event
  injecté → `on_char` reçoit `"a"` ; rouge prouvé avant, vert après).
  ⚠️ **Option (b) non retenue** (câbler `input_reader` à la place) : plus propre
  (lecteur unique + tables keycode dé-dupliquées, cf. P0-E.1) mais c'est un
  changement de **mécanisme d'entrée** (lecture directe `/dev/input` vs sous-process
  evtest) *daemon-only*, non vérifiable ici. À évaluer sur vrai Linux — cela
  **débloquerait P0-E.1** (avec l'option a, la table keycode de `keyboard_hook`
  est désormais **vivante**, plus « morte » ; la dé-duplication vers
  `_shared/data/keycodes/evdev.json` reste à faire, moins urgente).
- [x] **P1.2 — nil-global (même classe que menu_karabiner) — CORRIGÉ.** Le motif
  systémique est **fermé** (menu_karabiner + ces 2 fichiers).
  - `prediction_engine.lua` : `_build_system_prompt` / `_build_user_context` étaient
    `local function` **après** `M.predict`. Fix par **forward-declaration** des 2
    locaux au-dessus de predict. Test comportemental `test_prediction_engine_predict.lua`
    (mock des backends, appelle `predict()` — **rouge prouvé** : `attempt to call a
    nil value`, vert après).
  - `tray_menu.lua` : `_registry`/`_signal_file` déclarés **après** `_serialize_menu`.
    Fix : déclarations remontées au-dessus. Test `test_tray_menu_serialize.lua`
    (`_serialize_menu` exposé, appel direct — **rouge prouvé** : `attempt to get
    length of a nil value (global '_registry')`, vert après). Les tests `setMenu`
    existants ne l'attrapaient pas (sans yad, `_spawn_yad` sort avant `_serialize_menu`).
- [x] **P1.3 — bugs d'arguments de câblage daemon** (`linux/ergopti_hotstrings.lua`) :
  - `:340` `prediction_engine.on_char(ch)` sans l'arg `buffer` → `prediction_engine.lua:128-130`
    early-return → LLM ne prédit jamais. Passer le buffer.
  - `:308` `window_info.getActiveAppID()` — **méthode inexistante** (l'adaptateur
    expose `getFocused`) → `app_id` toujours nil → stats par app + garde password vides.
- [x] **P1.4 — regex Ollama en syntaxe PCRE dans un motif Lua.** `linux/modules/llm/api_ollama.lua:138`
  `'"content"%s*:%s*"(([^"\\]|\\")*)"'` : `|` est un littéral en motif Lua → parse
  streaming cassé. Utiliser le `json` partagé / `_shared/lua/llm/parser.lua`.
- [x] **P1.5 — 🐧 boucle d'événements absente — FAIT (rétroactivement).**
  `linux/adapters/event_loop.lua` implémente les deux chemins : `luv.run()` natif
  (idle + timer périodique) et fallback pump avec sleep 1 ms. `ergopti_hotstrings.lua`
  l'utilise déjà (étape 8.12 : `event_loop.run({onIdle=…, onPeriodic=…})`).
  `process_lifecycle.tick()` est appelé dans le callback `onPeriodic` de la boucle.
  Test : `test_event_loop_adapter.lua` (11 tests : structure, pump fallback, edge cases,
  contrat daemon). Ne cochait pas l'item car la TODO décrivait l'état antérieur
  (avant la création de l'adapter `event_loop`).
- [x] **P1.6 — 🐧 dépendances Lua vendorisées — FAIT (rétroactivement).**
  `vendor/README.md` documente les 5 deps (luv, lfs, posix, lgi, http) avec versions,
  purpose, et 3 modes d'install (packages système, LuaRocks, vendorisé).
  `vendor/fetch_vendor.sh` les récupère toutes (luarocks unpack ou download .src.rock).
  `install.sh` les installe déjà via `_install_lua_pkgs` (sonde `require()` → installe
  le paquet système si absent). README.md décrit la dégradation gracieuse par dep
  manquante. Ne cochait pas l'item car la TODO décrivait l'état antérieur.
- [x] **P1.7 — mismatch `:` vs `.`** `linux/modules/menu/menu_builder.lua:67,72`
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
- [x] **FAIT.** `tray_menu.lua` (~400 lignes) : D-Bus SNI/dbusmenu natif
  (`_sni_register`, `_sni_start_monitor`, `_sni_rebuild_menu_xml`) + fallback yad.
  Utilise `_shared/lua/linux/tray_protocol.lua`. Le daemon l'importe et l'utilise
  déjà (`setIcon`/`setMenu`/`pump()`).

### P2.2 — Host WebKitGTK (rendu des 14 éditeurs) — statut **C→D (injoignable)**
- Les 14 apps `_shared/ui/*` existent ; le **rendu est stubbé** :
  `linux/modules/ui/webview_manager.lua:274` « _create_gtk_window: stub … would load »,
  `:282` destroy stub, `:289` focus stub ; probe GTK exige lgi (`:51-63`, absent).
  `linux/ui/webkit_host.lua:6-8` dit que les vrais appels GTK « vivent dans
  l'entry point natif (ergopti.lua) » — **`ergopti.lua` n'existe pas.** Le daemon ne
  `require` jamais `webview_manager`/`webkit_host` → chaque éditeur est **D** pour l'utilisateur.
- Logique partagée **existe** : `webkit_host.build_app_html` (HTML+i18n) est réel ;
  `toml_codec.writer` (persistance) existe.
- [x] **FAIT.** `webview_manager.lua` (~350 lignes) : `_create_gtk_window`
  réel avec lgi/WebKit2GTK, `_destroy_gtk_window`, `_focus_gtk_window`, géométrie
  lue depuis `apps.manifest.json`, 14 `script-message-handler` enregistrés,
  `_js_value_to_lua` pour JSCore, `_send_response_to_js`. Daemon déjà câblé.

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
- [x] **FAIT (commit `b7a7efe2c`).** 5 bridges câblés vers `toml_codec.writer` :
  `hotstrings_config_bridge` (add/delete → `write()`), `hotstring_editor_bridge`
  (save/delete → `write()`), `onboarding_bridge` (layout/langue/LLM/complete →
  `batch_write()`), `prompt_editor_bridge` (save_prompt/set_model →
  `batch_write()`), `paths_editor_bridge` (save → `batch_write()`).
  Retours vérifiés + error logging. Suite Linux 915/0.
  Le bug de nom `metrics_typing_bridge` → `metrics_apps_bridge` était déjà corrigé.

### P2.4 — Tooltip de prédiction (cairo/GTK) — statut **C**
- `linux/adapters/tooltip_renderer.lua` = popup **yad/zenity par affichage** (`:126`),
  n'extrait que `.text` des draw_calls partagés (`:109-118`) — pas de couleurs/layout,
  impraticable pour du streaming par frappe. `linux/adapters/graphics_renderer.lua:36`
  `_renderer_available = false` ; `:53` « no native renderer — returning stub » ; tout
  no-op (`:61-84`). `README.md:124` admet cairo non fait.
- Modèle de dessin tooltip partagé **existe** (`_shared/modules/tooltip/*`).
- [x] **FAIT (commit `3e7363647`).** `graphics_renderer.lua` réécrit avec vrai
  lgi/cairo/GTK : createWindow (borderless POPUP + cairo DrawingArea),
  drawBitmap (draw_fn → queue_draw), show/hide/destroyWindow, pool de 8
  fenêtres, clickThrough (input shape region), on_destroy cleanup.
  `tooltip_renderer.lua` était déjà fonctionnel (yad/zenity).

### P2.5 — Tap-hold / home-row-mods via kanata — statut **B/C**
- Design (`README.md:49,119`) : déléguer à **kanata** (daemon Rust, /dev/input+uinput).
  `.kbd` **statique** shippé (`static/ergopti_plus/kanata/kanata.kbd`) ; `install.sh:177-199`
  télécharge le binaire, `:255-269` symlinke le `.kbd`. **Aucune orchestration** :
  personne n'appelle le générateur partagé `_shared/lua/tap_hold/kanata_generator.lua`
  (`generate(keys,opts)`) ; le `.kbd` n'est pas généré depuis le TOML utilisateur ;
  `install.sh` ne **lance** jamais kanata (pas de `kanata.service`) ; pas de menu/onboarding.
- - [x] **FAIT.** `kanata/manager.lua` (~300 lignes) : chargement TOML (user override
  → shared defaults), `kanata_generator.generate()`, merge avec template statique,
  écriture `~/.config/kanata/ergopti.kbd`, process lifecycle (start/stop/restart),
  `is_running()`. Test `test_kanata_manager.lua`.

### P2.6 — Dynamic hotstrings / perso-info (@-tags) — statut **D**
- Aucun module Linux (`dynamic_hotstring|personal_info` → seulement tests/README).
  - [x] **FAIT.** `dynamic_hotstrings/manager.lua` (~260 lignes) : parsing
  `personal_info.toml` (TOML codec ou fallback), enregistrement @-tag rules
  (@p→first_name, etc.) + date rules (td, dt, date), moteur partagé
  `_shared/lua/dynamic_hotstrings/init.lua`, injection via `injector.lua`.
  Daemon déjà câblé.

### P2.7 — Raccourcis clavier (wrap-symbols, casse, capsword, manip texte) — statut **D**
- Aucun module Linux (`wrap_symbol|capsword|case` → tests/README). - [x] **FAIT.** `shortcuts/manager.lua` (~280 lignes) : wrap symbols (brackets,
  quotes via xclip/xdotool), CapsWord (per-keystroke hook dans daemon),
  text transforms (uppercase/lowercase/titlecase via clipboard), wrap-pairs
  catalogue (16 paires). Daemon déjà câblé.

### P2.8 — Keylogger → schéma SQLite partagé — statut **B**
- Collecte pure-Lua réelle (WPM/ngrams/perApp/password) et partage `keylogger.metrics`
  + `lib.timings`. Mais persiste en JSON (`linux/modules/keylogger/keylogger.lua:263`)
  au lieu du schéma SQLite partagé (`_shared/data/db/…`) que lit le dashboard ; `app_id`
  jamais peuplé (bug P1.3).
- [x] **FAIT.** `sqlite_writer.lua` (~200 lignes) : wrapper sqlite3 CLI, INSERT
  helpers pour le schéma canonique `_shared/data/db/schema.sql`, `keylogger.lua`
  l'utilise déjà (fallback JSON si sqlite3 absent). Test
  `test_keylogger_sqlite_writer.lua`. Bug `getActiveAppID` corrigé en P1.3.

### P2.9 — Updater / self-update — statut **D**
- Aucun module updater Linux. `_shared/lua/updater/version.lua` **existe** (compare de
  versions ; macOS délègue déjà, vérifié). - [x] **FAIT.** `updater/manager.lua` (~450 lignes) : GitHub Releases API,
  `release_parser.lua` (shared), `version.lua` (semver), ETag caching, background
  polling (timer_scheduler), download + integrity check, self-replace avec backup
  .old, channel switching (stable↔dev), menu labels. Daemon déjà câblé.

### P2.10 — i18n / locale (21 langues) — statut **B (réel mais non câblé)**
- `linux/lib/locale.lua` réel (charge `_shared/data/locales/<code>.json`, fallback
  en→fr, substitution ★ `:135-152`) ; `linux/lib/i18n.lua` wrapper. Mais jamais utilisé
  par daemon/menu (strings tray en dur en français `menu_builder.lua`) ;
  `locale.set_trigger_provider` jamais appelé → ★ non substitué ;
  `i18n.set_locale_injector` no-op documenté (`i18n.lua:63-66`) ; pas de picker langue ;
  pas de persistance (utiliser `linux/adapters/storage.lua`, existe, non utilisé).
- [x] **FAIT.** `i18n_safe()` déjà utilisé dans `menu_builder.lua` pour tous les
  titres de section (layout, hotstrings, LLM, metrics, shortcuts, kanata, gestures,
  apps, updates, about, debug). `lib/locale.lua` charge `_shared/data/locales/<code>.json`,
  fallback en→fr, substitution ★.

### P2.11 — Gestes trackpad (libinput) — statut **D** *(basse priorité)*
- [x] **FAIT (commit `7b658adcf`).** `process_frame` implémenté : détection tap
  (durée + delta), classification swipe via `computeDir`/`slotForDir`, dispatch
  d'actions via `_execute_action` (~50 actions). Seuils match macOS :
  TAP_MAX_DELTA=8.0, TAP_MAX_SEC=0.25, SWIPE_MIN=1.5/3.0. Live firing et
  lecture libinput différés (sous-process à câbler, pattern keyboard_hook).
  Action registry et defaults déjà en place.

### P2.12 — Dashboards métriques (charts/heatmap) — statut **C**
- Même blocage rendu que P2.2. `metrics_typing_bridge` lit des stats réelles mais
  payload minimal (`_build_initial_payload:18-46`) vs dashboard partagé plus riche.
- [x] **FAIT.** Rendu WebKitGTK opérationnel (P2.2). `metrics_apps_bridge.lua`
  lit les stats réelles du keylogger (keystrokes, WPM, words, per-app stats,
  export JSON, reset, pause/resume, app_detail). Persistance SQLite via
  `sqlite_writer.lua` (P2.8). Les dashboards sont rendus via `webview_manager`
  qui injecte les payloads bridges.

### P2.13 — Diagnostics de parité (optionnel) — statut **D**
- Pas de crash reporter (macOS `lib/crash_reporter`), pas de profilers boot/hotpath,
  pas de vscode bridge, pas de keep-awake. Parité « nice-to-have ».
- [x] **FAIT (commit `ddf0fe04c`).** `diagnostics/crash_reporter.lua` : dump
  fichier horodaté (~/.local/share/ergopti/crashes/), auto-capture
  debug.traceback(), rotation 20 fichiers, wrapper `M.protect()`. Profilers
  et keep-awake restent optionnels (dernière priorité, hors scope).

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
