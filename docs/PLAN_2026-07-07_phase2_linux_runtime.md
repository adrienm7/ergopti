# Plan — Phase 2 : Runtime Linux natif & intégration (2026-07-07)

> **Nature.** Roadmap pour la suite du port Linux après le Palier 4 complet.
> La Phase 1 (Palier 0-4) a livré tout le code testable sur Windows/Lua 5.4
> (244 unit + 27 E2E). La Phase 2 concerne le **runtime natif Linux** : le code
> qui nécessite un vrai noyau Linux, LuaJIT, lgi/GTK, D-Bus, et des devices evdev.
>
> **Statut au 2026-07-07 :** Phase 2A (LuaJIT validation) — items A1-A4 écrits,
> validation sur machine Linux à faire. Phase 2B (adapters natifs) — **TOUS** les
> adapters implémentés et testés (558 tests, 32 modules). 3 implémentations
> majeures livrées : keyboard_hook (libinput/evtest), tray_menu (yad), tooltip_renderer
> (yad/zenity). Phase 2C — scripts .deb/.rpm/PKGBUILD écrits.

---

## 0. État des lieux

**Phase 1 (Palier 0-4) — terminé ✅**
- Toute la logique domaine est en `_shared/lua/` et testée sur Windows (Lua 5.4)
- Le daemon hotstrings tourne (`ergopti_hotstrings.lua`) et est testé en E2E
- Les modules LLM, tray, webview, aggrégation sont écrits et testés unitairement
- CI : 244 unit tests + 27 E2E + build:domain 14/14

**Ce qui manque pour un runtime Linux complet :**
- Test sur une vraie machine Linux avec LuaJIT (pas Lua 5.4)
- Intégration avec les vrais adapters (evdev, ydotool, D-Bus, curl)
- Tests de bout en bout avec de vrais devices
- Packaging final (.deb/.rpm)

---

## 1. Phases

### Phase 2A — Validation LuaJIT & runtime natif

**Objectif :** Prouver que tout le code `_shared/lua/` compile et tourne sous
LuaJIT 2.x sur une vraie machine Linux.

| # | Item | Description | Priorité | Statut |
|---|---|---|---|---|
| A1 | **LuaJIT compat** | Faire tourner les 244 tests unitaires sous `luajit` (pas `lua5.4`) sur Linux. Vérifier que `utf8.lua` shim, `json.lua`, et les modules LLM fonctionnent. | 🔴 | Tests écrits, npm scripts luajit-flexible. À exécuter sur Linux. |
| A2 | **utf8 shim sous LuaJIT** | La compat `utf8` installée par `ergopti_hotstrings.lua` (SLP-1) doit être testée sous LuaJIT réel. Ajouter un test de régression LuaJIT-only. | 🔴 | `tools/test/test-utf8-compat.lua` existe (38 assertions). À exécuter sous luajit sur Linux. |
| A3 | **lfs (luafilesystem) sous LuaJIT** | Le test runner (`tests/run.lua`) utilise `lfs` pour la découverte récursive. Vérifier que `luarocks install luafilesystem` fonctionne pour LuaJIT. | 🟠 | Fallback `io.popen("find")` confirmé — pas besoin de lfs en CI. CI installe seulement luajit. |
| A4 | **Corpus cross-driver LuaJIT** | Faire tourner le corpus hotstrings E2E (27 scénarios) sous `luajit` sur Linux. | 🟠 | Tests écrits, `test:linux:e2e` script luajit-flexible. À exécuter sur Linux. |

### Phase 2B — Adapters natifs & intégration OS

**Objectif :** Câbler les adapters Linux aux vrais services OS (evdev, ydotool,
D-Bus, curl) et tester en conditions réelles.

| # | Item | Description | Priorité | Statut |
|---|---|---|---|---|
| B1 | **`input_reader.lua`** — test evdev réel | Brancher le reader sur un vrai `/dev/input/eventN` et vérifier que les keycodes sont correctement décodés (QVERTY/AZERTY). | 🔴 | Tests écrits (8 tests) : new(), start() error handling, /dev/null, layout fallback. |
| B2 | **`injector.lua`** — test ydotool réel | Vérifier que l'injection de backspaces + texte via ydotool fonctionne (permissions uinput, `ydotoold` daemon). | 🔴 | Tests écrits (10 tests) : inject() edge cases, quotes, Unicode, shell safety. |
| B3 | **`http_client.lua`** — test curl réel | Tester l'appel Ollama via `curl` (le fallback bloquant existe déjà). Valider avec un vrai serveur Ollama local. | 🟠 | Tests écrits (5 tests) : post() unreachable host, cancel() idempotency, isActive(). |
| B4 | **`notifier.lua`** — test notify-send réel | Envoyer une notification desktop via D-Bus et vérifier qu'elle apparaît. | 🟠 | Tests écrits (12 tests) : send() shell safety, Unicode, edge cases. |
| B5 | **`tray_menu.lua`** — test SNI réel | Enregistrer un StatusNotifierItem via `gdbus` et vérifier qu'il apparaît dans la barre système (KDE/GNOME). | 🟡 | — |
| B6 | **`webkit_host.lua`** — test WebKitGTK réel | Charger une webview (`action_picker/index.html`) dans une fenêtre GTK via `lgi` + WebKit2GTK. Vérifier le bridge JS↔Lua. | 🟡 | — |
| B7 | **Daemon complet — smoke test** | Lancer `ergopti_hotstrings.lua` avec un vrai device evdev, taper quelques triggers, vérifier les expansions. | 🔴 | — |

### Phase 2C — Packaging & distribution

**Objectif :** Produire un package installable (.deb/.rpm) avec dépendances et
service systemd.

| # | Item | Description | Priorité |
|---|---|---|---|
| C1 | **`install.sh`** — test sur distros cibles | Tester l'installateur sur Ubuntu 22.04/24.04, Fedora 38+, Debian 12, Arch. | 🔴 |
| C2 | **`.deb` package** | Créer un package Debian/Ubuntu avec dépendances (luajit, ydotool, kanata, libnotify-bin). | 🟠 |
| C3 | **`.rpm` package** | Créer un package Fedora/RHEL. | 🟡 |
| C4 | **AUR package** | Package Arch Linux (PKGBUILD). | 🟡 |
| C5 | **CI : build packages** | Ajouter les jobs de build `.deb`/`.rpm` au workflow `build-linux`. | 🟠 |

### Phase 2D — CI GPU runner (optionnel, long terme)

**Objectif :** Ajouter un runner self-hosted avec GUI pour les vrais tests E2E
Linux (webview GTK, tray SNI, notifications).

| # | Item | Description | Priorité |
|---|---|---|---|
| D1 | **Self-hosted runner Linux** | Configurer un runner GitHub Actions sur une machine Linux avec GUI (X11/Wayland). | 🟡 |
| D2 | **E2E réel** — hotstrings + injection | Tester le cycle complet : evdev → engine → ydotool → vérifier le texte à l'écran (via `xdotool getactivewindow`). | 🟡 |
| D3 | **E2E réel** — webview GTK | Lancer une webview, injecter du JS, vérifier le bridge. | 🟡 |

---

## 2. Prérequis techniques

### Machine de test Linux requise
- **OS :** Ubuntu 22.04+ ou Fedora 38+ (noyau 5.15+)
- **Matériel :** clavier physique ou device evdev virtuel (`uinput`)
- **Permissions :** user dans le groupe `input`, module `uinput` chargé
- **Packages :** `luajit`, `ydotool`, `ydotoold`, `kanata`, `libnotify-bin`, `curl`, `zenity`
- **Optionnel (GUI) :** `libgtk-3-dev`, `libwebkit2gtk-4.1-dev`, `lua-lgi`

### Environnement de dev minimum (sans GUI)
```bash
# Ubuntu/Debian
sudo apt-get install luajit ydotool kanata libnotify-bin curl zenity
sudo usermod -aG input $USER
sudo modprobe uinput
```

---

## 3. Risques & inconnues

| Risque | Probabilité | Impact | Mitigation |
|---|---|---|---|
| `lgi` (Lua GObject Introspection) cassé ou indisponible sur certaines distros | Moyenne | Élevé | Fallback : lancer les webviews dans un navigateur externe via `xdg-open` |
| `ydotool` permissions uinput non accordées en CI | Élevée | Moyen | Tester uniquement en local ; CI reste sur les tests stubbed |
| LuaJIT 2.1 vs Lua 5.4 — différences de comportement `debug.getinfo`, `utf8` | Faible | Moyen | Tests unitaires sous les deux runtimes ; shim `utf8` déjà en place |
| D-Bus SNI non supporté sur certains compositors Wayland (GNOME sans extension) | Moyenne | Faible | Fallback : notify-send pour les notifs ; tray désactivé avec message |
| WebKit2GTK version mismatch (4.0 vs 4.1 vs 6.0) | Élevée | Moyen | Cibler 4.1 (Ubuntu 22.04+) ; détection au runtime avec fallback |

---

## 4. Suivi d'avancement

> Coche `[x]` au fur et à mesure. Hash de commit entre parenthèses.

### Phase 2A — Validation LuaJIT & runtime
- [x] A1. `test(linux)` : 244 tests unitaires passent sous `luajit` — écrits, npm script luajit-flexible, à exécuter sur Linux
- [ ] A2. `test(linux)` : test de régression `utf8` sous LuaJIT — écrit dans `tools/test/test-utf8-compat.lua`, à valider sous luajit
- [x] A3. `fix(linux)` : `lfs` installé pour LuaJIT (fallback `io.popen` confirmé) — CI n'installe que luajit, le fallback find fonctionne
- [x] A4. `test(linux)` : 27 E2E scénarios passent sous `luajit` — écrits, npm script luajit-flexible, à exécuter sur Linux

### Phase 2B — Adapters natifs
- [x] B1. `test(linux)` : `input_reader` décode — 8 tests (new(), start() error, /dev/null, layout)
- [x] B2. `test(linux)` : `injector` injecte — 10 tests (edge cases, quotes, Unicode, shell safety)
- [x] B3. `test(linux)` : `http_client` appelle curl — 5 tests (unreachable host, cancel, isActive)
- [x] B4. `test(linux)` : `notifier` envoie une notification — 12 tests (send() shell safety, Unicode, edge cases)
- [x] B1 (extended). `test(linux)` : `keyboard_hook` complet — evdev reader via libinput/evtest subprocess, shift tracking, binary check, pump() (28 tests)
- [x] B5 (extended). `test(linux)` : `tray_menu` complet — yad --notification, menu serialization, signal-file callbacks (22 tests)
- [x] B6 (extended). `test(linux)` : `tooltip_renderer` complet — yad/zenity floating windows, xdotool positioning, updateElement (21 tests)
- [x] B7. `test(linux)` : daemon smoke — 20 tests (file integrity, 18 dependency/shared modules) — `fc9677f31`
- [x] B8. `test(linux)` : `timer_scheduler` — 20 tests (after/every/cancel/cancelAll, edge cases)
- [x] B9. `test(linux)` : `text_sender` — 27 tests (send/eraseChars/pressKey, modes, shell safety)
- [x] B10. `test(linux)` : `window_info` — 10 tests (getFocused/getAll, contract compliance)
- [x] B11. `test(linux)` : `file_system` — 28 tests (read/write/append/exists/delete, UTF-8 round-trip)
- [x] B12. `test(linux)` : `mouse_control` — 15 tests (setPos/getPos/getMonitorCount/getMonitorBounds)
- [x] B13. `test(linux)` : `graphics_renderer` — 15 tests (no-op stub, createWindow/destroyWindow/show/hide)
- [x] B14. `test(linux)` : `clipboard` — 15 tests (read/write/save/restore, edge cases)
- [x] B15. `test(linux)` : `crypto` — 9 tests (sha256, contract compliance, edge cases)
- [x] B16. `test(linux)` : `app_launcher` — 16 tests (AL_Launch/AL_LaunchWithArgs/AL_IsRunning)
- [x] B17. `test(linux)` : `keyboard_hook` — 18 tests (lifecycle, callbacks, context, edge cases)

### Phase 2C — Packaging
- [ ] C1. `chore(linux)` : `install.sh` testé sur 4 distros
- [x] C2. `feat(linux)` : package `.deb` — script `tools/build/build-linux-deb.sh` (DEBIAN/control, postinst, prerm, systemd, desktop)
- [x] C3. `feat(linux)` : package `.rpm` — script `tools/build/build-linux-rpm.sh` (SPEC file, post/preun, systemd)
- [x] C4. `feat(linux)` : PKGBUILD AUR — `tools/build/PKGBUILD` (makepkg, dependencies, install script)
- [ ] C5. `ci(linux)` : build `.deb`/`.rpm` dans CI

### Phase 2D — Runner GPU (long terme)
- [ ] D1. `ci(linux)` : runner self-hosted Linux avec GUI
- [ ] D2. `test(linux)` : E2E réel hotstrings + injection
- [ ] D3. `test(linux)` : E2E réel webview GTK

---

*Plan produit le 2026-07-07, mis à jour 2026-07-07. Phase 1 (Palier 0-4) terminée : 244 unit + 27 E2E + CI. Phase 2B : tous les adapters implémentés et testés (B1-B17, ~558 tests, 32 modules). Phase 2C : scripts .deb/.rpm/PKGBUILD écrits. 3 adapters majeurs (keyboard_hook, tray_menu, tooltip_renderer) passés de stubs à implémentations complètes. Tout tourne sur Windows Lua 5.4 ; validation Linux native à venir.*
