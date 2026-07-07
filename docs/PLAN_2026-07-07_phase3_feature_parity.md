# Plan — Phase 3 : Feature parity Linux ↔ macOS/Windows (2026-07-07)

> **Nature.** Roadmap pour atteindre la parité fonctionnelle complète entre le driver
> Linux et les drivers macOS (Hammerspoon) et Windows (AutoHotkey). La Phase 2
> a livré tous les adapters et le packaging. La Phase 3 couvre les features
> utilisateur : menu système, LLM, keylogger, config UI, onboarding, updater.
>
> **Statut au 2026-07-07 :** Phase 2 terminée (558 tests, 32 modules, packaging .deb/.rpm/PKGBUILD).
> Phase 3 démarre — feature parity avec macOS et Windows.

---

## 0. État des lieux — Gap analysis

### Ce que le driver Linux a déjà
- ✅ Hotstring engine (engine.lua, loader.lua, injector.lua, input_reader.lua)
- ✅ Device auto-detection (device_finder.lua via /proc/bus/input/devices)
- ✅ Keyboard hook (keyboard_hook.lua — libinput/evtest subprocess)
- ✅ Tray icon stub (tray_menu.lua — yad --notification, 2 items hardcoded)
- ✅ Basic metrics (metrics_collector.lua — WPM, n-grams, session stats)
- ✅ All 20 port adapters (15 fully implemented, 5 stubs)
- ✅ Daemon entry point (ergopti_hotstrings.lua — pump-based event loop)
- ✅ Shared modules (logger.shim, lib.timings, lib.locale, lib.i18n, json, utf8 compat)
- ✅ Packaging (.deb, .rpm, AUR PKGBUILD, install.sh)
- ✅ CI (test-linux, e2e-linux, build-linux, build-deb, build-rpm)

### Ce qui manque (comparé à macOS 125+ modules, Windows 228+ fichiers)

| # | Feature | macOS | Windows | Linux (gap) |
|---|---|---|---|---|
| 1 | **Menu système riche** | ui.menu (10+ submenus) | ui/tray_menu.ahk (15+ submenus) | tray_menu.lua (2 items hardcoded) |
| 2 | **LLM prediction engine** | modules/llm/* (MLX + Ollama + Remote) | modules/llm/* (Ollama + Remote) | ❌ Aucun |
| 3 | **Hotstrings config UI** | ui/hotstrings_editor.lua | ui/hotstrings_config_window/* | ❌ Aucun |
| 4 | **Keylogger complet** | modules/keylogger/* (SQL, n-grams, password) | modules/keylogger/* (9 fichiers) | metrics_collector.lua (basique) |
| 5 | **Tap-hold detection** | lib/tap_hold/* | modules/tap_holds/* (15 fichiers) | ❌ Aucun |
| 6 | **Shortcuts/gestures** | modules/shortcuts/*, modules/gestures/* | modules/shortcuts/*, modules/gestures/* | ❌ Aucun |
| 7 | **Onboarding wizard** | ui/onboarding (first-boot setup) | ui/onboarding/init.ahk | ❌ Aucun |
| 8 | **Updater** | lib/updater.lua (Sparkle) | lib/updater/* (self-update) | ❌ Aucun |
| 9 | **Healthcheck** | ui/healthcheck (shared) | ui/healthcheck/init.ahk | ❌ Non câblé |
| 10 | **WebView/UI** | ui/ui_builder.lua (WebKit) | WebView2 (Edge) | webkit_host.lua (stub) |
| 11 | **Config window** | ui/paths_editor, action_picker | ui/action_picker, ui/prompt_editor | ❌ Aucun |
| 12 | **WPM widget** | ui/wpm/wpm_widget.lua | ui/wpm/* | ❌ Aucun |
| 13 | **Crash reporter** | lib/crash_reporter.lua | lib/crash_reporter.ahk | process_lifecycle.lua (stub) |
| 14 | **File watchers** | lib/file_watchers.lua | ui/hotstrings_config_window (hot reload) | ❌ Aucun |
| 15 | **i18n locale data** | locale JSON (12 langues) | locale JSON | lib/locale.lua + lib/i18n.lua (shared, OK) |

---

## 1. Phase 3 — Tiers

### Tier 1 : Core user-facing features (implémentable sur Windows, testable sous Lua 5.4)

Ces features ne dépendent PAS du runtime Linux — elles tournent avec du Lua pur et peuvent
être écrites et testées sur Windows avant validation Linux.

| # | Item | Description | Tests estimés |
|---|---|---|---|
| **1.1** | **Daemon CLI tests** | Tests d'intégration pour ergopti_hotstrings.lua : --help, --dry-run, --verbose, --tray, --config, --device, --layout, edge cases (sans device, sans mappings). | ~20 |
| **1.2** | **Menu système riche** | Étendre tray_menu.lua : submenus dynamiques (hotstrings, layouts, LLM models, metrics, preferences). Menu items générés depuis les TOML chargés. | ~15 |
| **1.3** | **Hotstrings config** | Module hotstrings_config.lua : chargement TOML → validation → engine.load_mappings(). Live reload via signal (SIGHUP) ou file watcher. | ~15 |
| **1.4** | **Keylogger complet** | Étendre metrics_collector → keylogger.lua : SQLite storage (luasql-sqlite3), password detection, app-level grouping, WPM ring buffer (déjà fait), session export JSON. | ~20 |
| **1.5** | **LLM prediction engine** | Port des modules macOS LLM → Linux : profiles.lua, prediction_engine.lua, streaming_handler.lua, parser.lua, api_ollama.lua. Ollama-only (pas MLX/Remote). Warmup, app filter, context builder. | ~30 |

### Tier 2 : UI features (nécessite WebKitGTK + X11/Wayland pour valider)

Ces features utilisent le webkit_host adapter pour afficher des UIs HTML/CSS/JS partagées
(action_picker/, metrics_typing/, healthcheck/). Le code Lua est testable, l'affichage
nécessite Linux.

| # | Item | Description |
|---|---|---|
| **2.1** | **WebView runtime** | Compléter webkit_host.lua : lgi WebKit2GTK, bridge JS↔Lua, HTML inliner, i18n inject. |
| **2.2** | **Onboarding wizard** | Premier lancement : wizard HTML (layout choice, language, LLM setup, hotstrings import). |
| **2.3** | **Hotstrings config window** | UI HTML pour éditer les hotstrings (tableau triable, recherche, ajout/suppression). |
| **2.4** | **Action picker** | Spotlight-style launcher (Ctrl+Space) — port de l'UI shared action_picker/. |
| **2.5** | **WPM widget** | Affichage overlay du WPM en temps réel (canvas HTML via WebView). |
| **2.6** | **Healthcheck** | Dashboard de santé du driver (modules chargés, erreurs, métriques). |

### Tier 3 : Features avancées (nécessite Linux + devices réels)

| # | Item | Description |
|---|---|---|
| **3.1** | **Tap-hold detection** | Détection tap-vs-hold via le keyboard hook (intercept mode). Génération config Kanata. |
| **3.2** | **Shortcuts/gestures** | Système de raccourcis clavier personnalisables + gestes souris. |
| **3.3** | **Updater** | Self-update : vérification GitHub Releases, téléchargement .deb/.rpm, installation. |
| **3.4** | **File watchers** | inotify-based hot reload pour les fichiers TOML de config. |
| **3.5** | **Crash reporter** | Capture des erreurs Lua → log + notification desktop. |

---

## 2. Suivi d'avancement

### Tier 1 — Core features (testable sur Windows)
- [ ] 1.1 Daemon CLI tests
- [ ] 1.2 Menu système riche
- [ ] 1.3 Hotstrings config
- [ ] 1.4 Keylogger complet
- [ ] 1.5 LLM prediction engine

### Tier 2 — UI features (nécessite Linux pour valider)
- [ ] 2.1 WebView runtime
- [ ] 2.2 Onboarding wizard
- [ ] 2.3 Hotstrings config window
- [ ] 2.4 Action picker
- [ ] 2.5 WPM widget
- [ ] 2.6 Healthcheck

### Tier 3 — Features avancées (Linux + devices)
- [ ] 3.1 Tap-hold detection
- [ ] 3.2 Shortcuts/gestures
- [ ] 3.3 Updater
- [ ] 3.4 File watchers
- [ ] 3.5 Crash reporter

---

*Plan produit le 2026-07-07. Phase 2 terminée : 558 tests, 32 modules, packaging complet.*
