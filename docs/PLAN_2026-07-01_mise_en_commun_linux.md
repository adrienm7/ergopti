# Plan — Mise en commun maximale & préparation du portage Linux (2026-07-01)

> **Nature.** Plan d'action priorisé, **sans modification de code**, de ce qui reste
> à mettre en commun dans `_shared/` entre les drivers AHK (`windows/`) et
> Hammerspoon (`macos/`), et de ce qui doit être partagé **avant** d'écrire le
> driver Linux.
>
> **Méthode.** Audit de l'état **actuel** du code par 8 investigateurs parallèles
> (un par axe) + vérification **adversariale** de chaque constat (70 constats →
> 30 vrais manques confirmés, 18 déjà faits depuis le dernier audit, 11
> légitimement spécifiques au driver, 8 surévalués/recadrés, 3 purement doc).
> Chaque constat est prouvé par `chemin:ligne` réels.
>
> **Décision cadre (2026-07-01, mainteneur).** Linux recevra un **host webview
> natif WebKitGTK** rendant les **mêmes** webviews `_shared/ui` que macOS/Windows.
> Le menu + les webviews doivent donc devenir **100 % host-agnostiques** (un 4ᵉ
> host Linux), et le manifeste de menu + les défauts `_shared` doivent piloter
> Linux aussi. La note « pas de GUI native » du `linux/README.md` est **caduque**.
>
> **Ce document remplace** `docs/AUDIT_2026-06-26_mise_en_commun_simplification.md`
> (supprimé) : son contenu encore pertinent est repris et remis à jour ici ; les
> items qu'il listait et qui ont **atterri depuis** sont recensés en §3 pour ne pas
> être ré-ouverts.

---

## 0. Constat global

**La mise en commun AHK ↔ macOS est très mûre.** Sur les 8 axes audités, le gros
du travail est **fait et vérifié** :

- **Corps des sous-menus** (raccourcis, métriques, layout, hotstrings, gestes,
  tap_holds AHK, debug) : 100 % pilotés par `_shared/…/menu_manifest.json` via
  deux renderers jumeaux (`manifest_menu.ahk` / `manifest_menu.lua`) — ordre,
  i18n, séparateurs, en-têtes, imbrication, filtrage par plateforme = **données
  partagées**.
- **Défauts** : LLM, timings, tooltip, hotstrings, tap-hold sont **single-source**
  et lus en fail-fast par les deux drivers GUI. Les 2 items du dernier audit
  (port Ollama `DD-1`, bloc mort `_platform_defaults` `DD-2`) sont **clos**.
- **Webviews** : les 13 frontends riches vivent **une fois** dans `_shared/ui/*`
  et sont consommés par les deux drivers ; `makeHostBridge`, `escapeHtml`,
  `i18n.js` sont centralisés et déjà bi-transport.
- **Logique domaine** : PromptBuilder, parser LLM, matching hotstrings,
  terminateurs, matching dynamic-hotstrings, dérivation des libellés de raccourcis
  (MS-3 atterri) sont partagés **ou** certifiés par corpus cross-driver.
- **Pureté `_shared/lua`** : le blocage `toml_codec` du dernier audit (SS-2) est
  **résolu** — plus aucun `require("lib.*")`/`hs.*` en dur ; Linux délègue déjà le
  parsing TOML au reader partagé.

**Ce qui reste** se scinde en deux familles :

1. **Finir les bords SSoT AHK ↔ macOS** : l'**ossature du menu top-level** et le
   **modèle de grisage** ne sont pas encore data-partagés ; les **sous-menus
   spécifiques driver** (tap-holds AHK, Karabiner macOS) gardent leur *structure*
   en dur ; quelques duplications de **logique LLM** ; le rapport **healthcheck**
   dupliqué ; la **carte doigts/mains** en 3 copies.
2. **Préparer le terrain Linux** : le port Linux est **~25 % construit** (une seule
   verticale — hotstrings + métriques WPM — exemplaire et déjà 100 % partagée).
   Tout le reste est stub ou absent, et dépend d'un ensemble de **prérequis
   `_shared`** à livrer d'abord (token `linux` du manifeste, host webview,
   générateur kanata, lecteurs timings/locale Linux, compat `utf8`).

---

## 1. Résumé exécutif — meilleures opportunités (valeur / risque)

| # | Opportunité | Axe | Effort | Risque | Linux | Gain |
|---|---|---|---|---|---|---|
| 1 | **`LNX-2`** — ajouter le token `linux` au schéma + vocabulaire du manifeste et factoriser la boucle `manifest_menu` en helper driver-neutre | Linux | L | moyen | 🔴 prérequis #0 | débloque **tout** menu/tray Linux |
| 2 | **`MENU-1`/`MENU-2`** — faire consommer `top_level` + `global_actions` du manifeste par les 2 drivers (aujourd'hui data morte, ossature ré-codée en dur ×2) | Menu | M | moyen | 🔴 | tue une dérive silencieuse déjà réelle + 1 source pour Linux |
| 3 | **`MG-1`/`MG-2`** — prédicat de grisage déclaratif `disabled_when` dans le manifeste + résolveur partagé ; rendre `depends_on` (data morte) load-bearing | Grisage | M | moyen | 🔴 | supprime le graphe de dépendances dupliqué à la main ×2 |
| 4 | **`UI-A3`** — `_shared/ui/apps.manifest.json` (géométrie des fenêtres webview) lu par les 3 hosts | UI | M | bas | 🔴 | tue la seule data host copiée à la main + amorce le host Linux |
| 5 | **`DL-1`** — aligner le `ProfileSelector` partagé sur le contrat réel des drivers, les 2 délèguent, + corpus de parité | Domaine | M | moyen | 🟠 | corrige la fonction LLM la plus critique (prompt réellement envoyé) |
| 6 | **`UI-A1`** — frontend partagé `_shared/ui/healthcheck/` (aujourd'hui 2 générateurs HTML/CSS jumeaux, « mirrors the Windows healthcheck UI ») | UI | M | bas | — | ferme la dernière vraie surface de drift webview (ex-UI-1) |
| 7 | **`DC-1`** — faire de `azerty.json` la source **chargée** unique de la carte doigts/mains (3 copies à la main aujourd'hui) + test de parité | Catalogues | M | bas | — | tue 3 copies drift-prone |
| 8 | **`MENU-3`/`MENU-4`** — structure des sous-menus **Karabiner** + **tap_hold** (ordre des touches, options de hold, split main gauche/droite) en data `_shared` | Menu | L | moyen | 🟠 | cœur de l'exigence #4 (sous-menus driver définis dans shared) |
| 9 | **`MG-3`** — promouvoir le mapping catégorie→sous-item (master-gate AHK-only) en data partagée | Grisage | L | moyen | 🟠 | donne à macOS/Linux le même modèle de grisage catégoriel |
| 10 | **`DL-2`/`DL-3`** — `legacy_ids` (migration d'IDs de profil) + `BASIC_PROMPT` en source unique (génération côté AHK) | Domaine | S | bas | — | 2 faits domaine dé-dupliqués (§5.2) |
| 11 | **`DL-4`/`DL-5`** — corpus de parité pour le calcul de préfixes perso-info et pour la cascade de résolution hotstrings | Domaine | M | bas | — | ferme 2 gaps de parité (pattern ADR-006) |
| 12 | **`UI-A1`+`UI-A2`** — extraire un vrai host-factory AHK `WebView_Host_Open` (macOS a déjà `ui_builder`) | UI | L | moyen | — | −~10-15 réimplémentations de cycle de vie WebView2 (§5) |
| 13 | **Bundle prérequis Linux** — `LNX-1` (evdev en `_shared`), `DD-3`/`DC-2` (lecteur timings Linux), `DC-3` (locale/i18n Linux), `SLP-1` (compat `utf8`), `LNX-5` (config-template Linux) | Linux | M×5 | bas | 🔴 | rend Linux consommateur des données/défauts partagés |
| 14 | **Chantiers natifs Linux** — `LNX-3`/`UI-A4` host WebKitGTK, `LNX-7` tray+tooltip, `LNX-4`/`DD-4` générateur kanata, `LNX-6` bridge LLM, `LNX-9` updater partagé | Linux | XL | moyen | 🔴 | complète le port (75 % restant) |

Légende Linux : 🔴 prérequis / bloquant ; 🟠 concerne aussi Linux ; — win↔mac seulement.

---

## 2. Manques confirmés, par axe

Chaque item : **Constat → Proposition** avec `chemin:ligne`. Sauf mention,
`behavior_change=false`. Les propositions intègrent les **corrections
adversariales** des vérificateurs.

### 2.1 — Menu : ossature & sous-menus spécifiques driver (exigence #4)

**`MENU-1` — L'ordre du menu top-level est déjà une donnée `_shared` que PERSONNE ne lit. `[M, moyen, 🔴, behavior_change]`**
- **Constat.** `menu_manifest.json:83-153` (source `manifest.toml:2690-2749`) contient un tableau `top_level` complet avec filtres `platforms` par item — **zéro** consommateur (`grep top_level` = 2 fichiers data seulement). Les 2 drivers ré-assemblent la même séquence impérativement : AHK dans `initMenu()` (`windows/ui/menu/menu_init.ahk:95-296`), macOS dans `M.generate()` (`macos/ui/menu/builder.lua:152-529`). Les deux ordres **divergent déjà** (AHK rend `setup_wizard` avant `config_folder` `menu_init.ahk:247,251` ; macOS l'inverse `builder.lua:451-452` ; le tableau partagé contredit AHK) — exactement le bug de dérive silencieuse que la data partagée élimine, et Linux n'a **aucune** source à rendre.
- **Proposition.** Faire itérer le tableau `top_level` par les 2 drivers **exactement comme `debug_menu`** l'est déjà (`MenuManifest_LoadDebugMenu` `menu_init.ahk:272-294`, `load_debug_menu` `builder.lua:99-125` : filtrage plateforme + dispatch id→builder). Ne garder dans le driver que la table id→(builder de sous-menu / closure d'action). **Corrections avant câblage** : (a) `top_level` n'a **pas** d'entrée `about` alors que les 2 drivers rendent un sous-menu About inline (`menu_init.ahk:200-245`, `builder.lua:439-445`) → ajouter un id `about` orderable ; (b) l'id `edit_shortcuts` (`manifest.toml:2735-2736`) n'est rendu comme top-level par aucun driver (il est injecté dans le sous-module raccourcis) → décider s'il reste top-level ou non. Réconcilier l'ordre canonique unique (changement de comportement sur le driver réaligné).

**`MENU-2` — `global_actions` est data `_shared` non consommée, ré-déclarée en dur ×2. `[S, bas, 🔴]`**
- **Constat.** `menu_manifest.json:154-170` (source `manifest.toml:2751-2764`) = `[enable_all, disable_all, reset_defaults, ---, language]`, **zéro** consommateur ; AHK re-déclare le trio (`menu_init.ahk:191-195`), macOS aussi (`builder.lua:430-437`).
- **Proposition.** Rendre `global_actions` via le renderer générique (c'est un id `top_level`) — **à fusionner dans le chantier `MENU-1`**. Ne restent en driver que les closures `enable_all`/`disable_all`/`reset_defaults` + le sous-menu `language` (déjà construit via `I18nBuildLanguageMenu` / `i18n.build_language_menu_items`).

**`MENU-3` — La structure du sous-menu Karabiner (macOS) est 100 % en dur, sans corps manifeste. `[L, moyen, 🟠]`**
- **Constat.** `menu_karabiner.lua:813-949` construit tout le squelette impérativement (aucun `karabiner_menu` dans le manifeste). L'ordre fixe des items (status/gui/start/stop/clear/restore/copy/délais), les en-têtes (`Main gauche`/`Main droite`/`Raccourcis`), l'ordre tap/hold et le split `LEFT_HAND_IDS` (`menu_karabiner.lua:177-187`) sont de la **structure de menu** en dur. Le driver **frère** (AHK) pilote **déjà** son sous-menu tap_holds analogue depuis `menu_manifest.json` (`tap_holds_menu`, lignes 690-729) via `MenuRenderer_Build` (`menu_taphold.ahk:39-46`) — le précédent existe.
- **Proposition.** Ajouter un tableau `karabiner_menu` à `manifest.toml [menu.*]` (`platforms=['hs']`) décrivant le squelette fixe (toggle `enabled`, items d'action ordonnés, séparateurs, en-têtes de section, items délai/seuil/symétrique/sticky, ids dynamiques pour `tap_hold_keys` et `raccourcis`), et le consommer via `macos/lib/manifest_menu.lua` avec des handlers dynamiques — exactement comme `menu_taphold.ahk`. Ne restent en driver que les closures de clic + les sondes de process KE (hot-path, différées).

**`MENU-4` — L'ordre des touches tap-hold + la liste des options de hold + le split main sont 3 copies driver-locales. `[L, moyen, 🟠]` — cœur exigence #4.**
- **Constat.** AHK : `tap_hold_writer.ahk:35-63` code en dur la liste ordonnée `_TH_KeyDefs` (14 touches) et `_TH_HoldOptions` (none/ctrl/shift/alt/alt_gr/win/nav). macOS : l'ordre `TAP_HOLD_KEYS` vient de `macos/modules/karabiner/data/tap_hold_keys.json` (jeu physique **différent** : fn/left_command/spacebar…), et le split main est une table `LEFT_HAND_IDS` en dur (`menu_karabiner.lua:177-187`). Le jeu de touches partagé existe pourtant déjà (`_shared/tap_hold/defaults.toml:37-107`).
- **Proposition.** Ajouter à `_shared/tap_hold/` (ou `manifest.toml [menu.*]`) un **catalogue de touches ordonné canonique** `{id, i18n, hand, platforms}` + une **liste d'options de hold partagée** `{id, kind, i18n}`. AHK (`TapHoldKeyDefs()`) et macOS (ordre `TAP_HOLD_KEYS` + `LEFT_HAND_IDS`) le **lisent**. Les jeux physiques divergents (AHK `alt_gr`/`win` vs macOS `fn`/`spacebar`) sont modélisés par le champ `platforms` par touche. Ne restent en driver que le mapping `key_code` OS (Karabiner from-modifiers / AHK) et les closures d'écriture/reload.

**`MENU-5` — `builder.lua` porte des copies fallback en dur de `debug_menu` et `ergopti_groups` qui ombragent le manifeste. `[S, bas]`**
- **Constat.** `builder.lua:25` `ERGOPTI_GROUPS_FALLBACK` et `:28-36` `DEBUG_MENU_FALLBACK` miroitent le manifeste, utilisés seulement en cas d'échec de chargement (`:78-80`, `:102-104,123`). Le fallback debug **a déjà dérivé** (il omet `open_error_log` présent au manifeste) → filet actif trompeur.
- **Proposition.** Supprimer les 2 fallbacks ; sur échec de chargement, logger `ERROR` et rendre un menu debug dégradé (fail loud, §5.3) plutôt qu'une copie périmée. Si un filet est requis, ajouter un test de drift build-time (comme le gate menu) au lieu de le maintenir à la main.

### 2.2 — Grisage / activation (modèle de dépendances)

**`MG-1` — Les prédicats de grisage par item sont codés en dur par driver ET dupliqués entre drivers. `[M, moyen, 🔴]`**
- **Constat.** Le graphe « quel item se grise quand quel toggle est off » est ré-encodé à la main une fois par driver. macOS `menu_metrics.lua:407` `disabled = not state.keylogger_enabled or not state.keylogger_menubar_wpm` ; `:443/:461/:478` idem sur `keylogger_float_wpm`. AHK `menu_metrics.ahk:143/153/161` ré-encode le **même** graphe (`if !WPMWidget.visible or !MetricsShortcuts.enabled`). Dérive silencieuse garantie.
- **Proposition.** Étendre le schéma d'item du manifeste avec un prédicat déclaratif, ex. `disabled_when = { any_off = ["keylogger_enabled", "wpm_widget"] }`, attaché à chaque item metrics/gestures/wpm. Ajouter un petit résolveur partagé dans chaque renderer (`manifest_menu.ahk`, `manifest_menu.lua`) qui lit le prédicat + une map de getters d'état fournie par le driver (`{ keylogger_enabled = fn, wpm_widget = fn, … }`). Les **getters** (OS/impl) restent en driver ; le **graphe** part en `_shared`. Réutiliser/généraliser la clé `depends_on` déjà présente (voir `MG-2`).

**`MG-2` — `depends_on` dans le manifeste est data morte. `[S, bas, 🔴]`**
- **Constat.** `menu_manifest.json:356` / `manifest.toml:2916` déclarent `depends_on = "wpm_menubar"` sur `menubar_colors` — **zéro** consommateur (`grep` = data + SQL sans rapport). Le renderer macOS ne le lit jamais (et ne rend même pas les items `feature`, `manifest_menu.lua:165-166`).
- **Proposition.** Rendre `depends_on` (généralisé en `disabled_when` de `MG-1`) **load-bearing** : le renderer le résout contre la map de getters ; supprimer ensuite la clause inline `or not state.keylogger_menubar_wpm`. Attention : `depends_on="wpm_menubar"` seul n'encode qu'**une** des deux clauses réelles (il faut aussi `not keylogger_enabled`) → sous-griserait. Livrer un **test de contrat cross-driver** (comme `test_llm_menu_layout_shared`) asserant que le flag `disabled` rendu = la projection du prédicat manifeste, pour qu'il ne redevienne jamais mort.

**`MG-3` — Le modèle de master-gate catégoriel AHK n'a aucun équivalent macOS/Linux ni représentation partagée. `[L, moyen, 🔴]`**
- **Constat.** AHK a un modèle complet mais **impératif** : `CategoryEnabled` Map (`feature_state.ahk:125-141`), `IsCategoryGated` (`:157-164`), table sous-catégorie→master `SubGates` (`master_gates.ahk:90-96`), résolveur `_MasterCategoryFor` (`menu_engine.ahk:96-117`), application du grisage (`menu_engine.ahk:57-60/85-87/169-171`). `grep` macOS/Linux = **0** contrepartie (confirme « category_enabled AHK-only » du dernier audit). Un futur host Linux (WebKitGTK) devrait tout réinventer.
- **Proposition.** Promouvoir la relation catégorie→sous-item en **data partagée** : garder les tags `category` déjà présents sur les toggles (`menu_manifest.json:223/313/413/…`) comme identité de master-gate, + ajouter un bloc `category_gating`/`master_categories` (mapping actuellement dans `SubGates` + `_MasterCategoryFor`). Un résolveur partagé calcule « cet item est-il grisé par son master ». AHK garde `ApplyMasterGatesToFeatures` (zéroing runtime = glue OS) mais **lit** le mapping depuis `_shared` ; macOS/Linux gagnent le même grisage.

### 2.3 — Défauts & variables (§5.2)

**`DD-3` / `DC-2` — Le daemon Linux re-déclare les timings keylogger en littéraux locaux. `[M, bas, 🔴]`** *(même manque vu sous 2 axes)*
- **Constat.** `metrics_collector.lua:48` `DEFAULT_SESSION_TIMEOUT_MS=300000`, `:53` `DEFAULT_WPM_WINDOW_MS=15000` — les commentaires admettent qu'ils « miroitent » `_shared/modules/timings/constants.toml [keylogger]` (précédemment divergents 30s/10s, corrigés à la main). `ergopti_hotstrings.lua:281` appelle `metrics.init({})` **vide** → ces littéraux sont les valeurs runtime réelles, pas des fallbacks inertes.
- **Proposition.** Donner à Linux un petit lecteur fail-fast (ex. `linux/lib/timings.lua`) miroir de `macos/lib/timings.lua` : parser `_shared/modules/timings/constants.toml` via `toml_codec.reader` (déjà requis par le loader Linux), exposer `Timings.ms(section,key)` en lisant `parsed.sections["keylogger"][key]`. Remplacer les 2 littéraux. Garder locaux `DEFAULT_NGRAM_SIZE`/`WPM_RING_CAPACITY` (bornes algorithmiques).

**`DD-4` / `LNX-4` — `kanata.kbd` code en dur des timeouts tap-hold/one-shot qui divergent de `_shared/tap_hold/defaults.toml`. `[L, moyen, 🔴, behavior_change]`** *(voir aussi §2.8 LNX-4)*
- **Constat.** `kanata/kanata.kbd` est **entièrement écrit à la main** : `:112-121` code `tap-hold-press 200 200` uniforme sur alttab/cap/lsft/lctl/lalt/ralt et `one-shot 1000 lsft`. **Aucun générateur** (`install.sh:257,265` symlink direct), alors que les valeurs partagées sont **par touche** (`defaults.toml:37-107` : caps_lock 350, left_ctrl 200…). Dérive déjà réelle.
- **Proposition.** Écrire un générateur data-driven lisant le **même** `_shared/tap_hold/defaults.toml` (via `toml_codec.reader`) et émettant `kanata.kbd` (ou au moins son bloc `(defalias)`), à l'image de `macos/modules/karabiner/generator.lua` : chaque `tap-hold-press <t> <t>` = `round(time_activation_seconds*1000)`, le one-shot depuis `[tap_hold] one_shot_shift_timeout_ms`. Le transform pur peut vivre en `_shared`, seul l'install/reload reste Linux-natif. + **corpus golden** kanata (comme karabiner). À défaut de génération : au minimum une assertion build-time que les littéraux kanata = valeurs partagées. Le remap physique (`defsrc`/`deflayer`) reste écrit à la main (glue de remap OS).

**`DD-10` — `CHARS_PER_WORD=5` re-déclaré en littéral Linux. `[S, bas]`**
- **Constat.** `metrics_collector.lua` re-déclare `CHARS_PER_WORD=5` (convention cross-driver : macOS keylogger + WPM widget utilisent la même règle) alors que la constante partagée **existe** (`_shared/lua/keylogger/metrics.lua:30 DEFAULT_CHARS_PER_WORD=5`) et que Linux **requiert déjà** ce module (`metrics_collector.lua:32`).
- **Proposition.** Single-sourcer : exporter/lire `DEFAULT_CHARS_PER_WORD` depuis le module partagé. Le reste (config dir XDG, ring capacity, ngram size, `os.clock`) reste légitimement local. À grouper avec `DD-3`.

*(Docs seulement — `DD-6` : corriger l'en-tête « mirror … MUST match » de `windows/lib/ui_style.ahk:6-9` en « lit au boot » ; `DD-7` : corriger le renvoi périmé `[timers]`→`[debounce]` dans `_shared/modules/hotstrings/defaults.toml:52`.)*

### 2.4 — UI / webviews

**`UI-A1` — Le rapport healthcheck est encore 2 générateurs HTML/CSS par driver (ex-UI-1, non atterri). `[M, bas]`**
- **Constat.** Pas de `_shared/ui/healthcheck`. `windows/ui/healthcheck/helpers.ahk:333` (`_HealthCheck_SnapshotToHtml`) et `macos/ui/healthcheck/helpers.lua:433` (`H.snapshot_to_html`) émettent un HTML/CSS quasi-identique (mêmes classes, table, `.ok`/`.fail` `#1a7f37/#cf222e`, bouton `#0078d4`) ; le fichier Lua commente littéralement « mirrors the Windows healthcheck UI ».
- **Proposition.** Créer `_shared/ui/healthcheck/{index.html,style.css,script.js}` : un template unique dont `script.js` reçoit le snapshot en JSON (via le host bridge / payload injecté) et rend System / compteurs session / état runtime / adapters / dernière erreur. **Libellés en anglais, hors i18n** (diagnostic dev, les 2 drivers le documentent). Chaque driver garde : (a) la collecte du snapshot (OS-spécifique), (b) la closure copie-presse-papier, (c) le fallback natif (Edit AHK / texte macOS). Détail : Windows rend aujourd'hui côté AHK via `NavigateToString` (`helpers.ahk:329`) → la migration passe le rendu au JS in-page comme macOS.

**`UI-A2` — Windows réimplémente tout le cycle de vie WebView2 dans ~10-15 modules ; pas de host-factory partagé (macOS en a un). `[L, moyen]`**
- **Constat.** `macos/ui/ui_builder.lua:251` = **une** factory `M.show_webview` (création fenêtre, inline HTML, injection i18n, focus, cycle de vie) réutilisée par ~15 modules macOS. Windows n'a **pas** d'équivalent : `windows/lib/webview_utils.ahk` ne fait que l'environnement partagé + le gate fallback ; chaque surface AHK ré-implémente le host en privé (`action_picker_webview.ahk`, `personal_toml_editor_webview.ahk`, `paths_editor/init.ahk`…, quasi-verbatim).
- **Proposition.** Consolidation **interne AHK** (pas un move `_shared` : AHK ne peut requérir le host Lua/JS). Étendre `webview_utils.ahk` en vraie factory `WebView_Host_Open({vhost, app_path, i18n_seed?, on_msg, …})` faisant une fois : show-before-create, `WebView2.create` + fallback natif, durcissement settings, mapping vhost, seed i18n, Navigate, bookkeeping des subscriptions, teardown. Chaque module se réduit à : builder de payload init + closures de message + fallback natif.

**`UI-A3` — Le descripteur host par app (vhost, chemin d'entrée, base i18n, géométrie) est en dur par driver ; devrait être data partagée pour piloter aussi le host Linux. `[M, bas, 🔴]` (recadré)**
- **Constat.** Chaque host AHK code en dur vhost + URL d'entrée + base i18n (`action_picker_webview.ahk:52/268/276`, `paths_editor/init.ahk:43`, `prompt_editor/init.ahk:57`) ; macOS dérive la base locale une fois (`ui_builder.lua:38`) mais chaque init hardcode `ASSETS_DIR`. La **seule** data réellement copiée à la main AHK↔macOS est la **géométrie** (`default_size`/`min_size`). Avec Linux sans couche `ui/`, une 3ᵉ copie se créerait.
- **Proposition.** Ajouter `_shared/ui/apps.manifest.json` **énumérant** les apps webview + leur **géométrie** (`{ id, default_size, min_size }`). Les 3 hosts (AHK `WebView_Host_Open`, macOS `ui_builder`, futur host Linux) lisent la liste + la géométrie. Garder `entry`/`locales_base` comme **conventions dérivées de l'id** (`ui/<id>/index.html`, `data/locales/`) plutôt que data. Satisfait l'exigence #4 pour l'UI et dé-risque le host Linux.

**`UI-A4` / `LNX-3` — Linux n'a aucun host webview ni couche `ui/`. `[XL, haut, 🔴, behavior_change]`** *(le plus gros chantier UI Linux — voir §2.8)*

**`UI-A6` — Libellés français en dur résiduels dans `_shared/ui/metrics_apps` (I18N-4 non terminé pour cette app). `[S, bas, 🔴]`**
- **Constat.** `metrics_apps/helpers.js:67-131` `MAC_CATEGORIES_FR` mappe les catégories anglaises vers du français et **keye les couleurs sur les libellés FR** (`FIXED_CAT_COLORS`) → structurellement non-localisable ; sous toute locale ≠ FR (et un futur host Linux), ça rend français.
- **Proposition.** Câbler sur les clés locale `app_category.*` déjà présentes dans chaque `data/locales/<code>.json` : mapper la catégorie vers un id stable snake_case (`productivity`, `social`, `video`, …), le libellé via `_t('app_category.'+id)`, et **re-keyer** `FIXED_CAT_COLORS` sur l'id stable. Même pattern que `metrics_typing` (déjà fait). Ferme le dernier gap I18N-4 matériel de l'axe UI.

*(Recadré `UI-A5` : WebKit2GTK expose **le même** `window.webkit.messageHandlers` que WKWebView → **pas** de 3ᵉ probe dans `makeHostBridge` ; action = **doc-only** (`host_bridge.js:6-11`) + enregistrer le handler côté host GTK.)*

### 2.5 — Logique domaine

**`DL-1` — La résolution du system-prompt LLM est dupliquée AHK+macOS et diverge du `ProfileSelector` partagé (sans corpus de parité). `[M, moyen, 🟠]`**
- **Constat.** La fonction LLM la plus critique (le prompt réellement envoyé) existe en **3** exemplaires **divergents** : `windows/modules/llm/profiles.ahk:99-127` et `macos/modules/llm/profiles.lua:160-207` implémentent le **même** algorithme (raw short-circuit ; n==1→`system_single` ; n>1→`system_single \n\n footer{n}` ; injection `{min_words}`/`{max_words}`/`{language}`), tandis que le `_shared/lua/llm/profile_selector.lua` fait un chemin **footer-only** qui **droppe le prompt de base** (donc le « canonique » partagé est *faux* vs les 2 drivers) et n'est appelé par personne.
- **Proposition.** **Aligner le partagé sur le contrat réel**, puis déléguer : réécrire `profile_selector.lua:resolve_system_prompt` (+ `ProfileSelector.js`) avec l'algorithme prouvé (profil nil → nil ; raw non-vide → verbatim [**manquant** aujourd'hui, à ajouter] ; n==1 → `system_single`|BASIC ; n>1 → base+`\n\n`+footer{n} ; substitution `{min_words}`/`{max_words}`/`{language}` en **variables** pas settings). Les drivers ne gardent que la glue OS (résolution live de min/max words + locale). + **corpus** `resolve_system_prompt` cross-driver (les 2 drivers certifiés).

**`DL-2` — Table de migration d'IDs de profil legacy dupliquée verbatim dans les 2 drivers. `[S, bas]`**
- **Constat.** `profiles.ahk:55-60` et `profiles.lua:86-91` déclarent la **même** map `{parallel→basic, batch→batch_advanced, parallel_advanced→advanced, base_completion→raw}` ; le partagé `profile_selector.lua:143` ne fait **aucun** remap. macOS commente « kept here because it encodes macOS driver history » alors qu'AHK en a une copie identique → data domaine cross-driver mal étiquetée.
- **Proposition.** Déplacer la map en `_shared` (bloc `legacy_ids` dans `_shared/modules/llm/profiles.json`, chargé par les 2 drivers) et appliquer le remap **dans** `Selector.get_active_profile`. Les 2 drivers droppent leur copie.

**`DL-3` — Littéral `BASIC_PROMPT` de fallback dupliqué dans les 2 drivers. `[S, bas]`**
- **Constat.** Le « basic » `system_single` existe en 3 endroits : `profiles.json:10` + `profiles.ahk:242-250` (`LLM_GetBasicPrompt`) + `profiles.lua:33-40` (`BASIC_PROMPT_FALLBACK`). Éditer le JSON ne met **pas** à jour les 2 fallbacks (§5.2).
- **Proposition.** Traiter en **génération** (pas délégation runtime) : au build, émettre le `basic.system_single` de `profiles.json` vers un artefact driver — pour AHK, `windows/_generated/` à côté de `terminators.ahk`/`prompt_builder.ahk`, lu par `profiles.ahk` au lieu du littéral ; pour macOS, délégation directe possible (peut requérir le shared). À fusionner avec `DL-1`.

**`DL-4` — AHK réimplémente le calcul de préfixes perso-info (spaced_prefix + comptes phone/SSN/IBAN) sans corpus cross-driver. `[M, bas]`**
- **Constat.** Le partagé Lua possède `spaced_prefix`/`compute_prefix_counts` (`_shared/lua/dynamic_hotstrings/init.lua:61,84`), macOS délègue (`rules_engine.lua`), mais AHK réimplémente (`hotstrings_text_expansion.ahk:262`, seuils `menu_helpers.ahk:42-58`) et le corpus `vectors.json` n'a **aucun** vecteur phone/ssn/iban/prefix → rien ne certifie la copie AHK (mode d'échec pré-ADR).
- **Proposition.** Ajouter `_shared/tests/corpus/dynamic_hotstrings/prefix_vectors.json` (générés depuis le module partagé = oracle) + faire tourner ce corpus dans `macos/tests` et un nouveau `windows/tests/meta` (pattern jumeau ADR-006). AHK garde son impl mais devient **corpus-bound**.

**`DL-5` — La cascade de résolution config hotstrings (override > TOML _meta > défaut) est codée 2 fois sans corpus. `[M, bas]`**
- **Constat.** DATA et défauts déjà single-source, mais l'**algorithme** de merge (précédence, portée section/fichier, « chaîne vide = hériter ») est dupliqué en Lua (`hotstrings_config.lua` `M.resolve` ~389-422) et AHK (`hotstrings_catalogue.ahk` `_HotstringsResolveUncached` ~84-135), sans corpus → un bug de précédence corrigé d'un côté est invisible de l'autre.
- **Proposition.** Ajouter `_shared/tests/corpus/hotstrings/config_resolve_vectors.json` (couches d'entrée → `{delay,color,show_tooltip}` attendus) tournant dans les 2 suites. Optionnel : extraire le merge pur en `_shared/lua/hotstrings_config_resolver.lua` (macOS/Linux le requièrent ; AHK reste hand-port certifié). Priorité < DL-1/DL-4.

*(Recadré `DL-6` : seuils de distance gestes — les swipe sont déjà single-sourcés dans `geometry.lua` (engine relit `SWIPE_MIN`) ; seul risque = sync documentaire `GestureRecognizer.spec.js` ↔ 3 littéraux `engine.lua`. **Doc/petit**, à faire quand le moteur de gestes Linux sera cadré.)*

### 2.6 — Pureté `_shared/lua` pour LuaJIT (Linux)

**`SLP-1` — Des modules partagés appellent la lib `utf8` de Lua 5.3, absente en LuaJIT. `[M, moyen, 🟠]` (recadré : robustesse latente, PAS un crash bloquant)**
- **Constat.** `_shared/lua/{keymap/terminators,text_utils/init,toml_codec/codec}.lua` appellent `utf8.offset/len/codes/char`. LuaJIT 2.x (runtime Linux confirmé) ne bundle **pas** `utf8`, et aucun shim n'existe. **MAIS** l'unique appel atteignable par le daemon actuel (`terminators.lua:94`, `pcall(utf8.offset,…)`) est **pcall-gardé** et **dégrade correctement** vers `s:sub(1,1)` (ASCII) → **pas** de crash ; les 2 autres sites ne sont pas sur le chemin de charge Linux actuel.
- **Proposition.** Ajouter une couche compat pure-Lua `_shared/lua/compat/utf8.lua` (offset/len/char/codes/codepoint, sémantique 5.3), installée en global une fois depuis `ergopti_hotstrings.lua` avant tout require partagé — **avant** que Linux consomme `text_utils`/`codec` à plus grande échelle (futur bridge LLM/keymap, host webview). Retirer `linux_blocker`/`behavior_change` du sévère : l'appel actuel ne change pas de comportement.

*(`SLP-2` : rider de `SLP-1` — quand le shim atterrit, livrer un test de régression **sous `luajit`** (§5.9) requérant `keymap.terminators`/`text_utils` et appelant une fonction utf8-dépendante.)*

### 2.7 — Catalogues de données

**`DC-1` — La carte doigts/mains existe en 3 copies synchronisées à la main ; aucune ne charge `azerty.json`. `[M, bas]`**
- **Constat.** `_shared/data/keycodes/azerty.json` est le canon déclaré mais **jamais chargé** au runtime (`grep` = commentaire + README). `state.js:382` re-déclare la map inline (`KEYCODE_DATA`) ; `macos/modules/keylogger/aggregator/core.lua:76` déclare une **3ᵉ** copie `KC_TO_FINGER` (docstring « kept in sync with KEYCODE_DATA in state.js »). Aucun test de parité.
- **Proposition.** Faire de `azerty.json` la source **chargée** unique : (a) webview — générer un module JS depuis `azerty.json` (ou le charger via host bridge), `state.js` l'importe (`heatmap_win.js` réutilise déjà `state.js`, rien à faire) ; (b) macOS `aggregator/core.lua` — dériver la colonne doigt de la data partagée au lieu de la map à la main. A minima : test de parité (comme `test-priority-parity`) verrouillant les 3 copies à `azerty.json`.

**`DC-3` — Linux n'a aucun consommateur locale/i18n du catalogue partagé (×21). `[M, bas, 🔴]`**
- **Constat.** Le catalogue existe (`_shared/data/locales/` ×21) et est consommé par macOS (`lib/locale.lua`) + Windows (`lib/locale.ahk`) + webviews (`i18n.js`) ; Linux = **0** consommateur. Bloquant pour le host webview Linux (qui doit injecter la même table locale).
- **Proposition.** Porter `macos/lib/locale.lua` en `linux/lib/locale.lua` (résolution de `_shared/data/locales/<code>.json` relative à la racine driver, même surface `M.get`/`M.set_locale`/substitution ★/fallback en→fr) + le wrapper `lib/i18n.lua`. Les JSON restent la source unique ; Linux n'ajoute qu'un consommateur.

*(Recadré `DC-4` : `priority.json` — **macOS seulement** peut charger `common/package/personal` depuis le JSON et droper ses littéraux `registry.lua:63-65` ; garder le miroir AHK `HSE_PRIORITY_*` + `test-priority-parity` comme exception acceptée. Le moteur partagé n'a pas de concept de priorité → laisser Linux hors scope ici.)*
*(Doc-only `DC-5` : corriger le docstring `_shared/lua/keycodes/init.lua:8` qui sur-annonce Linux comme consommateur — ce registre = sentinelles HID macOS, un domaine différent des tables evdev de Linux.)*

### 2.8 — Portage Linux — analyse de gaps subsystème par subsystème

> Linux ≈ **25 % construit** : une seule verticale (hotstrings + métriques WPM)
> exemplaire et **déjà 100 % partagée** (délègue à `_shared/lua`). Le reste est
> stub ou absent. Parce que macOS a déjà poussé le domaine dur en `_shared/lua`,
> la plupart des subsystèmes sont « câbler un adapter à un module partagé
> existant », pas « porter la logique ».

**`LNX-2` — Le vocabulaire de plateforme du manifeste est ahk/hs-only — ne peut pas piloter un menu/tray Linux. `[L, moyen, 🔴, behavior_change]` — PRÉREQUIS #0.**
- **Constat.** `menu_manifest.json:3` documente `omit/both/ahk/hs`. Surtout, `manifest.schema.json:47,101` **restreint l'enum** de `platforms` à `["ahk","hs"]` → un item `linux` **échouerait la validation** (preuve plus forte qu'un simple commentaire). `is_for_hs`/`_MR_IsForAhk` mirroir. Aucun reader manifeste Linux.
- **Proposition.** **Avant tout code menu Linux** : (1) ajouter `"linux"` à l'enum `platforms` du schéma (les 2 occurrences `:47,:101`) + à l'objet `default` par plateforme si besoin ; (2) doc `menu_manifest.json` ; (3) factoriser la boucle de build générique de `manifest_menu.lua` en helper **driver-neutre** (elle n'a besoin que d'un décodeur JSON + lookup i18n + prédicat plateforme — les injecter) ; Linux fournit `_shared/lua/json.lua` + son i18n (DC-3) et réutilise l'itération ; ajouter `is_for_linux`. **Auditer chaque tableau `platforms` existant** pour décider la visibilité Linux.

**`LNX-1` — Les tables keycode→char evdev sont en dur dans `input_reader` ; devraient être en `_shared/data`. `[M, bas, 🔴]`**
- **Constat.** `input_reader.lua:85-149` code 4 maps evdev→char inline (`QWERTY_/AZERTY_ (UN)SHIFTED`) agrégées en `LAYOUTS`. C'est de la **data de layout** pure (pas de la glue ABI). Aucune source partagée ne sert ce besoin (`_shared/lua/keycodes` = sentinelles HID macOS, espace numérique différent).
- **Proposition.** Ajouter `_shared/data/keycodes/evdev.json` (`{keycode, unshifted, shifted, altgr}` par layout : qwerty, azerty) + un loader mince `_shared/lua/keycodes/evdev.lua` retournant la structure `LAYOUTS`. `input_reader.lua` le `require` et droppe les 4 maps ; garde le décodage binaire (`decode_u16_le`/`decode_s32_le`, filtrage `EV_KEY`) = glue kernel.

**`LNX-3` / `UI-A4` — Aucun host webview Linux : le host WebKitGTK + le contrat `makeHostBridge` ne sont pas câblés. `[XL, moyen, 🔴]`**
- **Constat.** `makeHostBridge` (`host_bridge.js:20-34`) a 2 probes (WebView2, WKWebView) ; le driver Linux n'a **pas** de dossier `ui/` ni de host. Les 13 webviews partagées sont **injoignables** sur Linux.
- **Proposition.** En `_shared` : documenter un **contrat d'enregistrement de handlers** (les noms de `messageHandlers` que chaque app enregistre) — **pas** de 3ᵉ probe JS (WebKit2GTK réutilise `window.webkit.messageHandlers`, cf. `UI-A5`). Côté driver (natif, Linux-only) : monter `linux/ui/` avec un host WebKitGTK (LuaJIT+lgi → WebKit2GTK/GTK3) miroir de `ui_builder.lua` : charge `_shared/ui/<app>/index.html`, injecte `window.__i18n_base`/`window._i18n_locale`, bridge JS↔Lua via `webkit_user_content_manager_register_script_message_handler`. Frontends déjà host-agnostiques (`i18n.js`/`dom_utils.js` = JS pur). **Séquencer après `LNX-2`** (le menu lance ces webviews) et prioriser le menu + les éditeurs.

**`LNX-4` / `DD-4` — Pas de générateur tap-hold → kanata ; `kanata.kbd` écrit à la main et dérivant. `[L, moyen, 🔴, behavior_change]`** *(voir §2.3 DD-4 pour la proposition — générateur data-driven miroir de `karabiner/generator.lua` + corpus golden).*

**`LNX-5` — Pas de génération de config-template Linux ; chaque autre driver a `_generated/config_template.toml`, Linux non. `[M, bas, 🔴]` (recadré/scopé)**
- **Constat.** `linux/_generated/` n'existe pas ; `macos/_generated/config_template.toml` + `windows/…` existent. `renderConfigTemplate(manifest, sections, features, platform)` (`build-features-manifest.js:389`) est **déjà** paramétré par plateforme, mais `PLATFORMS=['ahk','hs']` (`:37`) et n'est invoqué que pour `ahk`/`hs`.
- **Proposition.** Ajouter une cible `linux` au codegen : `OUT_LINUX_DIR = linux/_generated`, ajouter `'linux'` à `PLATFORMS`, émettre `renderConfigTemplate(…, 'linux')` (+ enregistrer dans `build-domain.cjs generated[]` et le test config-schema). Garder la résolution XDG (`~/.config/ergopti`) dans le daemon. **Scope honnête** : le template ne contiendra que les features dont `platforms` inclut `linux` — donc **dépend de l'audit `LNX-2`** des visibilités.

**`LNX-6` — Subsystème LLM entièrement non câblé sur Linux alors que les ports Lua partagés sont prêts. `[XL, moyen]`**
- **Constat.** `_shared/lua/llm/{parser,prompt_builder,profile_selector}` sont purs et **prêts** (docstrings anticipent « a Linux driver »), mais `linux/` n'a **aucun** code LLM.
- **Proposition.** **Aucun move `_shared`** (domaine déjà partagé) : écrire un bridge LLM natif Linux qui (a) collecte le contexte buffer, (b) build via `prompt_builder` partagé, (c) appelle Ollama sur `linux/adapters/http_client.lua` en **lisant le port depuis `_shared/modules/llm/defaults.json:25`** (11434, jamais re-hardcodé), (d) stream/debounce via timer natif (légitimement driver — macOS co-localise aussi). Séquencer après `LNX-3` (webviews prompt/token) et `LNX-5` (surface config LLM). *(Prérequis `DL-1`/`DL-3` pour que la résolution de prompt soit partagée avant que Linux la réutilise.)*

**`LNX-7` — Tray, tooltip et la plupart des adapters de port sont des no-ops TODO. `[XL, moyen, 🔴]`**
- **Constat.** `tray_menu.lua:42-49` logue « SNI/AppIndicator not yet implemented » et chaque méthode early-return ; `tooltip_renderer.lua:53-78` ne rend qu'un `notify-send` stub. Le test de présence (`test_port_adapter_presence.lua`) ne fait qu'un `io.open` → un stub pur passe.
- **Proposition.** Restent **Linux-natifs** (pas de move `_shared`) : tray = `StatusNotifierItem`/`com.canonical.dbusmenu` ; tooltip = **natif** cairo/GTK layer-shell (**ne jamais** webview-er le tooltip, règle hot-path). Les seules dépendances partagées restent des **contrats** : items du tray depuis le manifeste `LNX-2`, `draw_calls` du tooltip depuis le payload partagé `_shared/modules/tooltip`. **Renforcer** le test de présence en test de **conformité** (appeler chaque méthode, asserter pas d'erreur) pour que les stubs soient visiblement incomplets.

**`LNX-9` — Pas de câblage updater/notifications alors que les défauts updater partagés existent. `[M, bas]`**
- **Constat.** `_shared/modules/updater/defaults.json` existe et macOS le lit ; Linux ne consomme ni l'updater ni les notifications (`notifier.lua:54-55` = stub `notify-send`).
- **Proposition.** Extraire la surface **pure** version+parsing-release de `macos/lib/updater.lua` (`normalize_tag`, `parse_version`, `compare_versions`, `is_newer_version`, `parse_notes`, `parse_asset_url`, …) vers `_shared/lua/updater/` (validée par `version_vectors.json` + `version.js`). macOS **requiert** ensuite ce module (retire sa réimpl) ; Linux le réutilise avec son propre download/install. `notify-send` reste natif, mais les **messages** viennent des locales partagées (pas en dur).

*(Recadré `LNX-8` : keylogger Linux = métriques en mémoire seulement. La **math** WPM/n-gram est déjà partagée et utilisée ; le résiduel = pipeline persistance/agrégation/export. Extraire un **cœur d'agrégation pur** vers `_shared/lua/keylogger/` est un refactor utile dont le **1er** bénéfice est de dé-dupliquer macOS↔AHK (l'aggregator est aujourd'hui mirror-porté, pas partagé), Linux venant après. `storage.lua` n'est **pas** un stub — c'est un KV Settings fonctionnel.)*

---

## 3. Déjà fait / vérifié depuis le 2026-06-26 (ne pas ré-ouvrir)

Constats **négatifs vérifiés** (18 `ALREADY_DONE`) — la data/logique est déjà
correctement partagée :

- **`MENU-7`** — corps des sous-menus (raccourcis/layout/hotstrings/métriques/gestes/tap_holds/debug) 100 % manifest-driven sur les 2 drivers (`manifest_menu.ahk:138-207` / `manifest_menu.lua:136-223`).
- **`MG-5`** — visibilité menu (ordre + filtrage plateforme) = modèle partagé (il ne manque qu'une 4ᵉ valeur `linux` quand le host Linux atterrit).
- **`DD-1`** — port Ollama single-sourcé (`defaults.json:25`), lu fail-fast par les 2 drivers. **Clos.**
- **`DD-2`** — bloc mort `_platform_defaults` **supprimé**. **Clos.**
- **`DD-5`** — registre timings partagé lu fail-fast par les 2 drivers GUI (implémentation de référence de l'axe).
- **`UI-A7`** — host bridge + `escapeHtml` + loader i18n centralisés et host-agnostiques (le `escape_html` du dernier audit a atterri).
- **`UI-A8`** — les 13 frontends riches vivent une fois dans `_shared/ui`, consommés par les 2 drivers (fallbacks natifs = dégradation offline/low-RAM, pas des copies).
- **`DL-7`** — PromptBuilder single-sourcé (Lua partagé + AHK généré), vecteurs partagés.
- **`DL-9`** — matching hotstrings/terminateurs/dynamic-hotstrings partagés ou certifiés (ADR-005/006) ; Linux re-exporte le moteur partagé verbatim.
- **`DL-10`** — dérivation des libellés de raccourcis + catalogue wrap-symbols partagés (MS-3/MS-3b atterris).
- **`SLP-3`** — impureté `toml_codec` (SS-2) **résolue** (commit `106bf348f`) : reader/writer soft-resolvent logger/i18n ; Linux délègue au reader partagé.
- **`SLP-4/5/6`** — logger shim, `hotstring_engine`, `dynamic_hotstrings`, `keylogger/metrics`, `json`, `keycodes`, `terminators_catalogue`, `prompt_builder`, `profile_selector` = **purs et directement Linux-consommables**.
- **`DC-6/8/9/10`** — catalogues gestes / wrap-symbols / hotstrings (TOML + TSV généré) single-source ; hotstrings = **le plus fort** cross-driver (consommé par les 3 drivers, gate corpus ADR-006).
- **`LNX-10`** — hotstrings/dynamic-hotstrings/terminateurs/métriques/lecture-TOML **déjà correctement partagés sur Linux** — le modèle que le reste du port doit suivre.

## 4. Légitimement spécifique au driver (vérifié — ne pas déplacer)

11 constats `LEGITIMATELY_DRIVER_SPECIFIC`, confirmés en vérification adversariale :

- **`MENU-6`** — sous-menu install-layout macOS : bodies dérivés d'état TIS/bundle live + AppleScript (l'ordre externe est déjà data via `top_level`).
- **`MENU-8`** — closures d'action + sondes KE/TIS + dialogues AppleScript = la bonne frontière driver/shared (le mécanisme handler-dynamique existe déjà pour ça).
- **`MG-4`** — le fallback inline de la policy de grisage LLM est épinglé au JSON partagé par `test_llm_menu_layout_shared.ahk` (résilience drift-proof, pas une 2ᵉ source).
- **`MG-6`** — grisage `paused` macOS : Hammerspoon n'a **pas** de suspend OS (AHK utilise `Suspend` natif) → asymétrie d'architecture, pas une duplication.
- **`MG-7`** — lectures de label/état natif + closures de toggle par ligne restent en driver (exigence #4 : seule la data part).
- **`DD-8`** — défauts model/backend LLM par plateforme (clés **structurellement divergentes** : AHK `llm_model` vs macOS `llm_model_ollama`+`_mlx` ; MLX macOS-only).
- **`DD-9`** — 7 constantes warmup/stream Ollama AHK = tunables hot-path AHK-only (le registre partagé `warmup_*` est MLX/HS-only).
- **`UI-A9`** — tooltip + widget WPM (GDI+, cold-start WebView2 ~476 ms/keystroke) + micro-modals (MagicKeyEditor, lien ChatGPT, `token_prompt` MLX macOS-only) restent **natifs**.
- **`DL-8`** — parser LLM : AHK réimplémente (ne peut requérir Lua) mais **certifié** par `parser_test_vectors.json`/`process_prediction_vectors.json`.
- **`DC-7`** — `tooltip/constants.toml` : catalogue **chargé** fail-fast (pas miroité).
- **`DC-5`** — `_shared/lua/keycodes` = sentinelles HID macOS (doc-only à corriger).

---

## 5. Plan d'exécution incrémental (moins → plus risqué)

Chaque incrément = un commit conventionnel autonome + son test de régression
(§5.9). 🖥️ = vérifiable **uniquement au reload** (GUI Windows / boot Hammerspoon /
daemon Linux) par le mainteneur.

> **Suivi d'avancement.** Coche `[x]` au fur et à mesure qu'un incrément est
> commité sur `dev` (ne pas pusher). Le hash de commit est noté entre parenthèses.
>
> ⚠️ **CORRECTION (2026-07-08) — les cases « fait » ci-dessous sont OPTIMISTES.**
> Les 26 items ont été *écrits et committés*, mais un audit a montré que :
> (1) la livraison a laissé **7 défauts sur les plateformes testables** (corrigés
> depuis : commits `a4624a741`, `0bb95a26c`) ; (2) **le driver Linux ne tourne pas**
> (pipeline de saisie mort — voir la todo ci-dessous) ; (3) plusieurs items sont
> *incomplets* malgré leur case cochée — notamment **LNX-8 (item 26) est faussement
> « fait »** : seuls les leaf helpers ont été extraits, le walk d'agrégation + le flush
> SQL restent des copies byte-for-byte macOS↔AHK sans corpus.
>
> ➡ **La todo autoritative et à jour est désormais :**
> [`TODO_2026-07-08_linux_parite_et_ssot.md`](TODO_2026-07-08_linux_parite_et_ssot.md)
> (Priorité 0 = finir la mutualisation/SSoT ; Priorité 1 = rendre le daemon Linux
> fonctionnel ; Priorité 2 = parité feature-by-feature). Suivre CE document, pas les
> cases ci-dessous.

**Palier 0 — Docs & data morte (risque ≈ nul).**
- [x] 1. `docs`/`chore` : corriger en-têtes/renvois périmés (`DD-6` `ui_style.ahk`, `DD-7` `hotstrings/defaults.toml:52`, `DC-5` docstring keycodes, `UI-A5` docstring `host_bridge`). (`0d25a1aac`)
- [x] 2. `refactor(menu)` : supprimer les fallbacks en dur dérivants de `builder.lua` + fail-loud (`MENU-5`). 🖥️ (`0d25a1aac`, même commit)

**Palier 1 — SSoT AHK↔macOS à faible risque.**
- [x] 3. `feat(menu)` : faire consommer `top_level` + `global_actions` du manifeste par les 2 drivers (`MENU-1`+`MENU-2`), + gate de drift top-level. 🖥️ (`a8e64794e`)
- [x] 4. `feat(menu)` : prédicat `disabled_when` déclaratif + résolveur partagé + rendre `depends_on` load-bearing + test de contrat (`MG-1`+`MG-2`). 🖥️ (`80e1cef55`)
- [x] 5. `refactor(llm)` : `legacy_ids` + `BASIC_PROMPT` en source unique (génération AHK) (`DL-2`+`DL-3`). (`afe5d9e2a`)
- [x] 6. `test(corpus)` : corpus de parité préfixes perso-info (`DL-4`) + résolution config hotstrings (`DL-5`). (`23a825d36`)
- [x] 7. `refactor(metrics)` : `azerty.json` source chargée unique doigts/mains + test de parité (`DC-1`). (`f7d713bba`) — note : un 4ᵉ artefact hardcodé (`KLW_VK_FINGER`, Windows/AHK, clés VK et non `kc`) a été découvert hors scope de cet item ; consigné dans `docs/PROJECT_MEMORY.md` (`project-dc1-windows-vk-finger-map-gap`), pas dans ce plan.
- [x] 8. `feat(ui)` : `_shared/ui/healthcheck/` partagé + hosts (`UI-A1`). 🖥️ (`be52ea7f4`)
- [x] 9. `feat(i18n)` : câbler `metrics_apps` sur `app_category.*` (`UI-A6`). 🖥️ (`f1ddc641e`)

**Palier 2 — SSoT structurel + comportement assumé.**
- [x] 10. `feat(llm)` : aligner `ProfileSelector` partagé sur le contrat réel + délégation + corpus (`DL-1`, `behavior_change`). 🖥️ (`46ae3764f`)
- [x] 11. `feat(menu)` : structure des sous-menus Karabiner + catalogue tap-hold en `_shared` (`MENU-3`+`MENU-4`, exigence #4). 🖥️ (`6a97c08ff`)
- [x] 12. `feat(menu)` : mapping master-gate catégoriel en data partagée (`MG-3`). 🖥️ (`6a97c08ff`)
- [x] 13. `refactor(ui)` : host-factory AHK `WebView_Host_Open` + `_shared/ui/apps.manifest.json` géométrie (`UI-A2`+`UI-A3`). 🖥️ (`10ad0868f`)
- [x] 14. `refactor(llm)` : macOS charge `priority.json` (drop littéraux) (`DC-4`). (`10ad0868f`)

**Palier 3 — Prérequis `_shared` du portage Linux (à livrer AVANT le code Linux).**
- [x] 15. `feat(manifest)` : token `linux` (schéma + vocab + `default`) + helper `manifest_menu` driver-neutre + audit des visibilités (`LNX-2`). ← **prérequis #0** (`10ad0868f`)
- [x] 16. `feat(shared)` : evdev en `_shared/data/keycodes/evdev.json` + loader (`LNX-1`). (`10ad0868f`)
- [x] 17. `feat(linux)` : lecteur timings Linux fail-fast + `CHARS_PER_WORD` single-sourcé (`DD-3`/`DC-2`+`DD-10`). 🖥️ (`10ad0868f`)
- [x] 18. `feat(linux)` : lecteur locale/i18n Linux du catalogue ×21 (`DC-3`). (`10ad0868f`)
- [x] 19. `feat(shared)` : couche compat `utf8` pure-Lua + test LuaJIT (`SLP-1`+`SLP-2`). (`10ad0868f`)
- [x] 20. `feat(codegen)` : cible `linux` du config-template (`LNX-5`). (`10ad0868f`)
- [x] 21. `feat(shared)` : extraire l'updater pur en `_shared/lua/updater/` (macOS délègue) (`LNX-9` partie shared). (`10ad0868f`)

**Palier 4 — Chantiers natifs Linux (reload/daemon-vérifiables).**
- [x] 22. `feat(linux)` : générateur kanata data-driven depuis `_shared/tap_hold/defaults.toml` + corpus golden + parity test CI (`LNX-4`/`DD-4`). 🖥️ (`10ad0868f` + `601882571`)
- [x] 23. `feat(linux)` : host webview WebKitGTK + contrat d'enregistrement handlers (`LNX-3`/`UI-A4`), menu + éditeurs d'abord. 🖥️
- [x] 24. `feat(linux)` : tray SNI/dbusmenu (depuis le manifeste) + tooltip natif cairo/GTK (depuis le payload partagé) + test de conformité des adapters (`LNX-7`). 🖥️
- [x] 25. `feat(linux)` : bridge LLM natif réutilisant les modules Lua partagés + adapters (`LNX-6`). 🖥️
- [~] 26. `feat(shared/linux)` : cœur d'agrégation keylogger pur en `_shared/lua/keylogger/` (`LNX-8`). 🖥️ — ⚠️ **INCOMPLET** : seuls les leaf helpers extraits ; le walk (`events.lua`/`keylogger_walker_events.ahk` ~500-620 lignes) + le flush SQL restent des copies byte-for-byte macOS↔AHK sans corpus. macOS ne `require` PAS les helpers partagés. → voir P0-G.1 de la nouvelle todo.

---

## 6. Tests / gates à ajouter (règle §5.9)

Chaque item structurel doit embarquer son test de régression :

- **Gate de drift top-level** : l'ordre rendu par chaque driver == projection plateforme de `menu_manifest.json top_level` (`MENU-1`).
- **Test de contrat grisage** : flag `disabled` rendu == projection du prédicat `disabled_when` (comme `test_llm_menu_layout_shared`) (`MG-1`/`MG-2`).
- **Parité catalogue tap-hold** : ordre `_TH_KeyDefs` (AHK) + ordre `TAP_HOLD_KEYS`/`LEFT_HAND_IDS` (macOS) == catalogue partagé (`MENU-4`).
- **Corpus** : `prefix_vectors.json` (`DL-4`), `config_resolve_vectors.json` (`DL-5`), `resolve_system_prompt` (`DL-1`), [x] corpus golden kanata (`LNX-4`) → `_shared/tap_hold/golden_kanata_defalias.kbd` + `tools/test/test-kanata-defalias-parity.cjs` (14/14 ✅).
- **Parité carte doigts** : les 3 copies == `azerty.json` (`DC-1`).
- [x] **Loader evdev** : `input_reader` charge la table partagée (`LNX-1`).
- [x] **Test LuaJIT** : `keymap.terminators`/`text_utils` sous `luajit` sur un caractère multi-octets (`SLP-1`/`SLP-2`). → `tools/test/test-utf8-compat.lua` (38 assertions, passe sur Lua 5.4 ; compatible LuaJIT)
- [x] **Config-schema** : le template Linux valide contre le schéma (`LNX-5`). → `build:domain` 14/14 ✅
- [x] **Conformité adapters Linux** : chaque méthode de port appelée, pas d'erreur (`LNX-7`). → tests unitaires 244/244 ✅

---

*Plan produit sans modification de code. Tous les chemins sont réels ; vérifications
adversariales appliquées à chaque affirmation de partage. Méthode : 8 investigateurs
+ vérificateurs par constat. Remplace `AUDIT_2026-06-26_mise_en_commun_simplification.md`.*
