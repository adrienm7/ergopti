# ErgoptiPlus — Glossaire

> Termes techniques utilisés dans le code, les tests, et la documentation. Ordre alphabétique.

---

## A

**Adapter** — Implémentation driver-spécifique d'un [Port](#port). Tout appel OS direct (`hs.*` sur macOS, `DllCall`/`WinGet*` sur Windows) doit vivre dans `adapters/` ; le code domaine dans `modules/` et `lib/` n'appelle jamais les OS-APIs directement. Voir ADR 001.

**AltGr (SC138)** — La touche Alt-droite du clavier, utilisée comme modificateur de couche pour les caractères Unicode spéciaux et comme préfixe pour les raccourcis de contrôle du script. Sur AHK : touche à double rôle délicate — elle se verrouille comme préfixe de combinaison et peut se désynchroniser sous `Suspend`.

**Auto-snapshot baseline** — Une valeur de ratchet calculée dynamiquement au premier lancement du test et persistée, au lieu d'être codée en dur. Évite que le ratchet devienne une mine lors d'un refactor légitime.

---

## C

**CapsWord** — Mode temporaire où CapsLock active la capitalisation pour un seul mot, puis se désactive automatiquement à la prochaine espace ou ponctuation. Distinct de CapsLock persistant.

**CoreState** — Table Lua centralisée créée par `init.lua` et injectée dans chaque module via `M.init(state)`. Évite les globals ; toute dépendance partagée (feature flags, config, registries) passe par cette table.

**Corpus test** — Test cross-driver en JavaScript (`_shared/core/domain/*.spec.js`) qui vérifie qu'un contrat comportemental est respecté par les deux drivers (AHK et Lua) à partir du même jeu de vecteurs. Voir ADR 006.

---

## D

**data.sql** — Fichier SQL append-only par device dans le dossier métriques du keylogger. Source de vérité canonique sur disque pour les événements clavier ; `db.sqlite` en est un cache reconstruisable.

**Dead key** — Touche combinatoire (chapeau `^`, tréma `¨`, accent grave `` ` ``…) qui ne produit pas de caractère immédiatement mais modifie le caractère suivant pour former un caractère composé (ex. `^` + `a` → `â`).

**Debounce** — Délai minimal entre le dernier événement déclenchant et le lancement d'une opération coûteuse (requête LLM, rebuild menu, écriture config). Évite les déclenchements parasites lors d'une frappe rapide.

**Domain spec** — Fichier JavaScript dans `_shared/core/domain/` (ex. `HotstringMatcher.spec.js`) définissant le contrat comportemental cross-driver d'un composant. Exécuté par la suite JS pour certifier la parité des deux drivers.

**Driver** — L'une des trois implémentations complètes d'ErgoptiPlus : `windows/` (AutoHotkey v2), `macos/` (Hammerspoon/Lua) ou `linux/` (Lua/LuaJIT + kanata). Les trois partagent données et frontends via `_shared/`.

**Dynamic hotstring** — Expansion calculée au moment de la frappe (date du jour, numéro de téléphone, NIR/IBAN depuis `personal_info.toml`) par opposition à un hotstring statique défini dans un fichier TOML.

---

## E

**Eventtap** — Objet `hs.eventtap` qui intercepte les événements clavier et/ou souris au niveau OS, globalement, avant qu'ils atteignent les applications. Équivalent macOS du hook clavier AHK.

**Expander** — Sous-module de `modules/keymap/` qui injecte le texte de remplacement dans l'OS après qu'un déclencheur a été reconnu. Marque les keystrokes injectés comme synthétiques pour que le keylogger ne les comptabilise pas.

---

## F

**Feature toggle** — Drapeau booléen dans `_shared/modules/features/manifest.toml` activant ou désactivant une fonctionnalité. Valeur par défaut dans le manifest ; valeur runtime lue depuis `config.toml` via la `Features map`.

**Features map** — Table en mémoire (`Map` AHK / table Lua) construite au boot depuis `config.toml` et le manifest. Source de vérité runtime de l'état de chaque fonctionnalité ; jamais re-déclarée dans le code module.

---

## H

**Healthcheck** — Sonde de diagnostic accessible depuis le menu Debug. Snapshote l'état runtime du driver (adapters, modules init, infos OS, dernières erreurs) et l'affiche dans une fenêtre dédiée ou via IPC.

**Hold** — La moitié "maintien" d'un tap-hold : maintenir la touche au-delà du seuil `TAP_MIN_DURATION_MS` active une couche ou un modificateur au lieu de déclencher l'action tap.

**Hotstring** — Séquence de touches déclenchant une expansion de texte en temps réel. Définie dans les fichiers TOML sous `_shared/modules/hotstrings/` ; l'expansion peut être statique (texte fixe) ou dynamique (calculée à la frappe).

**Hotstring engine** — Le sous-système (centré sur `modules/keymap/`) qui intercepte les frappes, compare les séquences tapées au catalogue de déclencheurs, et déclenche l'expansion correspondante.

---

## I

**InputHook** (AHK) — Objet AHK v2 `InputHook()` qui intercepte les caractères de façon transparente, sans les consommer du flux d'événements OS. Utilisé par le prefix watcher et le LLM bridge.

**Ingest tick** — Timer périodique qui lit `today.log`, écrit les événements dans `db.sqlite`, et vide le buffer mémoire. Fréquence configurable dans `_shared/modules/timings/constants.toml [keylogger]`.

---

## K

**Karabiner-Elements (KE)** — Outil macOS de remapping clavier bas niveau fonctionnant au niveau kernel. ErgoptiPlus génère entièrement son `karabiner.json` en Lua et le déploie dans le répertoire de config KE pour gérer les remappings que Hammerspoon ne peut pas intercepter.

**Keylogger** — Démon bas niveau qui intercepte, horodate et stocke chaque frappe humaine globalement. Ne loggue pas les frappes synthétiques (injectées par l'expander). Persiste en SQLite + JSONL ; partage le schéma disque entre les deux drivers pour les dossiers cloud partagés.

---

## L

**Layout** (keymap) — La couche de remapping physique du clavier Ergopti : couche de base, Shift, CapsLock, AltGr, touches mortes. Définie dans `modules/keymap/layout.ahk` (Windows) et `modules/keymap/` (macOS).

**LLM bridge** — Composant qui intercepte les frappes pour maintenir un buffer de contexte et déclencher des requêtes LLM debouncées vers le moteur de prédiction.

**Lifecycle pairing** — Règle : `Logger.start` / `Logger.trace` doit toujours être suivi d'un `Logger.success` / `Logger.done`. Un `start` sans `success` dans les logs signale un échec silencieux. Vérifié par `test_logger_pairing`.

---

## M

**Magic key** — Touche synthétique (étoile `★` / `Chr(0x2605)`) utilisée comme sentinelle dans les expansions de hotstrings avancées et les liaisons du layout. N'est pas une touche physique ; émise par l'expander via `Send`.

**Manifest** — `_shared/modules/features/manifest.toml` : source de vérité de tous les feature toggles, leurs valeurs par défaut, et leurs métadonnées (label, section). Généré en `_generated/features_manifest.{ahk,lua}` par `npm run codegen`.

**MLX** — Framework Apple (open-source) pour l'inférence LLM locale sur Apple Silicon. L'un des deux backends LLM locaux supportés par ErgoptiPlus (avec Ollama).

---

## N

**Navigation layer** — Couche virtuelle activée par le maintien d'une touche tap-hold (ex. LAlt), mappant les touches de lettres/chiffres à des actions de navigation (flèches, mot/ligne/document, gestion de fenêtres, volume).

**N-gram** — Séquence de N frappes consécutives analysée par le keylogger pour les statistiques ergonomiques (fréquence de bigrammes, SFBs, vitesse par finger).

---

## O

**Ollama** — Serveur local d'inférence LLM multi-modèles. Backend par défaut pour les prédictions de frappe dans ErgoptiPlus.

**One-shot shift** — Mode de capitalisation où un tap de Shift capitalise exactement le caractère suivant puis se désactive, sans nécessiter de maintenir la touche Shift.

**Onboarding wizard** — Assistant multi-étapes affiché au premier lancement en l'absence de `config.toml`. Guide l'utilisateur pour choisir la langue, le layout clavier, et les chemins de configuration.

---

## P

**Port** (architecture hexagonale) — Interface d'isolation OS définie dans `_shared/core/ports/` (`KeyboardHook`, `FileSystem`, `TimerScheduler`, `TextSender`, `Storage`, `HttpClient`…). Tout appel OS passe par un port ; les adapters en fournissent l'implémentation driver-spécifique. Voir ADR 001.

**Prefix watcher** — Le composant (AHK : `InputHook` ; macOS : buffer dans l'eventtap) qui surveille les caractères tapés pour détecter les séquences de déclenchement de hotstrings et les transmettre au moteur.

**Purity ratchet** — Meta-test (`tests/meta/test_port_adapter_coverage.lua`) qui compte les appels `hs.*` / `io.open` / `os.execute` hors `adapters/` et asserte que le total reste sous un plafond décroissant. Rend impossible la régression vers des appels OS directs dans le code domaine.

---

## R

**Ratchet** — Un gate CI monotone dont le plafond (ou plancher) ne peut qu'aller dans la direction de l'amélioration : une fois qu'une métrique s'améliore, le ratchet échoue si elle régresse. Utilisé pour la pureté des ports, le ratio d'introspection, et le nombre de tests épinglés par chemin.

**Registry** (keymap) — Sous-module de `modules/keymap/` qui maintient la table de correspondance déclencheur → callback. Implémente le contrat `HotstringMatcher.spec.js`.

**RegisterMenuItem** (AHK) — Wrapper obligatoire (`lib/menu_dispatcher.ahk`) pour tout item actionnable du menu tray. Contourne le bug AHK 2.0 qui ignore silencieusement ~30–50 % des callbacks de menu quand `Menu.Add` est utilisé directement avec des lambdas.

---

## S

**SFB (Same-Finger Bigram)** — Séquence de deux touches tapées consécutivement par le même doigt. ErgoptiPlus inclut une catégorie `sfbs_reduction/` dans son catalogue de hotstrings pour éviter ces enchaînements inconfortables.

**Singleton window** — Pattern garantissant qu'une fenêtre UI ne s'ouvre qu'une seule fois : un second appel à `show()` ramène la fenêtre existante au premier plan (et sur le Space actif sur macOS). Tous les éditeurs et pickers implémentent ce pattern.

**Space teleportation** — Technique macOS faisant apparaître une fenêtre Hammerspoon dans le Space (bureau virtuel) actuellement actif de l'utilisateur, quel que soit celui dans lequel elle a été créée.

**SSoT (Single Source of Truth)** — Principe imposant qu'une valeur partagée (constante, default, catalogue) soit définie en un seul endroit et lue partout ailleurs. Toute duplication est une violation et crée un risque de drift.

**Suspend / Pause invariant** — Règle architecturale : suspendre ErgoptiPlus doit faire taire **toutes** les fonctionnalités (tooltip, LLM, keylogger, widget). AHK `Suspend` ne désarme que les hotkeys ; les `InputHook`, timers, et `OnMessage` le contournent et nécessitent des guards `A_IsSuspended` explicites.

---

## T

**Tap** — La moitié "pression courte" d'un tap-hold : une pression relâchée avant le seuil `TAP_MIN_DURATION_MS` déclenche l'action tap (ex. espace → espace, LAlt → retour arrière).

**Tap-hold** — Technique de double rôle sur une touche physique : pression courte (tap) → une action, maintien (hold) → une autre action (couche ou modificateur). Implémenté dans `modules/tap_holds/`.

**today.log** — Fichier JSONL hot-path écrit par le keylogger à chaque flush. Évite d'ouvrir SQLite sur le chemin critique par frappe (latence) ; ingéré dans `db.sqlite` par le walker au prochain tick.

**Touchdevice** — API macOS non documentée (`hs._asm.undocumented.touchdevice`) permettant de recevoir les frames tactiles brutes du trackpad. Le device est dormant jusqu'au premier contact physique ; aucune sonde logicielle ne peut le réveiller plus tôt.

**TSV cache** — Fichier plat (`.tsv`) auto-généré et non versionné, dérivé des sources TOML. Utilisé sur Windows pour le catalogue de hotstrings (évite de parser du TOML à chaque frappe) ; se reconstruit automatiquement si absent ou périmé.

---

## U

**Usercontent channel** — Canal de communication JS↔hôte dans les fenêtres webview. Sur macOS : `hs.webview.usercontent` (handler nommé) + `evaluateJavaScript`. Sur Windows : `chrome.webview.postMessage` (WebView2) + `webview.ExecuteScript`. Le frontend partagé détecte automatiquement quel canal est disponible.

---

## W

**Warmup** — Pré-chargement d'un modèle LLM en mémoire (envoi d'une requête factice) pour que la première vraie prédiction n'ait pas de latence de démarrage à froid. Déclenché après un délai configurable si LLM est activé.

**WebView2** — Runtime Microsoft (basé sur Chromium) permettant d'embarquer un moteur web dans les applications AHK v2. Équivalent de WKWebView côté macOS.

**WKWebView** — Moteur WebKit d'Apple embarqué dans Hammerspoon pour les fenêtres web partagées. Les données sont injectées via `evaluateJavaScript` ; les actions JS remontent via le handler usercontent.

**WPM (Words Per Minute)** — Vitesse de frappe en mots par minute, calculée sur une fenêtre glissante de keystrokes récents. Affiché par le widget WPM flottant et (macOS) la barre de menu.

**Wrap symbols** — Fonctionnalité encadrant une sélection de texte avec une paire de caractères (parenthèses, guillemets, crochets, etc.) via un raccourci. Le catalogue des paires vit dans `_shared/modules/wrap_symbols/wrap_symbols.json`.
