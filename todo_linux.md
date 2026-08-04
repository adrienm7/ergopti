<!-- todo_linux.md -->

# Plan & TODO — Driver Linux (moteur de hotstrings X11 + Wayland)

> **But de ce document.** Amener le driver Linux d'ergopti+ à un moteur de
> hotstrings *réellement fonctionnel sur du vrai matériel*, identique sous X11
> et sous Wayland, avec **une seule** implémentation qui détecte le serveur
> d'affichage à l'exécution — un utilisateur peut se déconnecter d'X11, se
> reconnecter sous Wayland, sans rien toucher. Livrable minimal visé : une icône
> ergopti+ dans la barre système Linux avec au moins un sous-menu Hotstrings
> capable de charger toutes les hotstrings des fichiers TOML.
>
> **Plan ET TODO dans un seul fichier** (comme `TODO.md`) : les §0–4 portent le
> raisonnement et les preuves ; le §5 (« plan par jalons ») est la **checklist
> actionnable** (cases à cocher). Séparé de `TODO.md` (édité en parallèle sur
> `dev`) pour éviter les conflits ; à réconcilier au merge. Écrit le 2026-07-30,
> branche `feature/linux-hotstrings` (dérivée de `dev`).
>
> **Règles de travail** (comme `TODO.md`) : aucun changement de comportement sans
> test de régression (§5.9) ; ne jamais affaiblir un test pour faire passer un
> changement ; tout texte visible passe par l'i18n (21 locales) ;
> `node ./tools/test/verify-change.cjs` pour les gates. **[MATÉRIEL]** = à valider
> sur une vraie machine avant merge (le CI ne couvre rien de tout ça).

---

## 0. TL;DR — la décision d'architecture en un paragraphe

Le driver Linux garde **une seule voie** pour capturer et injecter les frappes :
**lire les événements evdev bruts depuis `/dev/input/eventN` et écrire dans
`/dev/uinput`**, tout en LuaJIT via FFI. Cette voie est la *seule* mécanique qui
couvre 100 % des serveurs d'affichage et compositeurs en 2026 (X11, Mutter/GNOME,
KWin/KDE, wlroots : sway/Hyprland/river/niri, COSMIC, Weston, TTY) parce qu'elle
opère **sous** le serveur d'affichage : ni X11 ni le compositeur ne savent que le
clavier virtuel n'est pas physique. C'est ce qu'utilisent en production espanso
(backend evdev), keyd, kanata, kmonad et xremap. La détection X11/Wayland à
l'exécution ne sert **que** pour les concerns périphériques qui, eux, dépendent
vraiment du serveur : résolution de la disposition clavier, identité de la
fenêtre active, et presse-papiers. Tout cela passe par **une** petite lib de
détection partagée. Le sous-menu tray passe par **StatusNotifierItem** (D-Bus),
lui aussi agnostique au serveur d'affichage.

**Corollaire fort :** notre différenciateur par rapport à espanso est le
*driver unique*. Espanso a un split X11/Wayland **à la compilation**
(`is_wayland()` = `cfg!(feature = "wayland")`, deux binaires mutuellement
exclusifs, issue #2137 toujours ouverte). Notre objectif de driver unique évite
exactement cette verrue — et le code d'espanso *prouve* que la voie evdev marche
aussi sous X11 (`USE_EVDEV=true` force le backend evdev sur leur build X11).

```
Physique ──► kanata (grab + remap Ergo) ──► périph. uinput « kanata »
                                                    │
                          notre daemon EVIOCGRAB ◄──┘  (voit les keycodes POST-remap)
                                    │
                          moteur hotstrings (Lua pur, partagé)
                                    │
                  écriture directe /dev/uinput « ergopti virtual keyboard » ──► compositeur / app
                                    │
         détection X11/Wayland (runtime) uniquement pour : layout • fenêtre active • presse-papiers
```

---

## 1. Contraintes et objectifs de succès

| # | Contrainte | Critère de validation |
| --- | --- | --- |
| C1 | **Un seul driver.** Pas de binaire X11 vs Wayland séparé. | Le même exécutable démarre et fonctionne sous les deux, sans variable d'environnement de sélection. |
| C2 | **Détection dynamique.** Bascule X11 ⇄ Wayland sans réinstallation ni reconfiguration. | Après un logout X11 → login Wayland, le daemon (via systemd `--user`, lié à `graphical-session.target`) redémarre et re-sonde le serveur à chaud. |
| C3 | **Toutes distros.** Ubuntu/Debian, Fedora/RHEL, Arch, openSUSE, **et** Alpine/musl, Void, Gentoo, NixOS, distros immuables (Silverblue, SteamOS). | Un chemin d'installation documenté et testé par distro-famille ; aucune ne « hard-abort » silencieusement. |
| C4 | **Correction du texte.** Une expansion ne doit jamais corrompre le texte de l'utilisateur (bug de course actuel `"abcd"→"acd"`). | Test de course sur vrai matériel : frappe rapide pendant l'expansion, sortie déterministe. |
| C5 | **Multilingue.** Les remplacements contiennent massivement des accents français (é, è, à, ç…) et des symboles (★, ➜, ≠). | Une expansion `NT’ ➜ N’T` ou une phrase accentuée s'insère correctement, quelle que soit la disposition active. |
| C6 | **Icône tray + sous-menu Hotstrings.** Au minimum : charger toutes les hotstrings TOML et les présenter. | Le sous-menu liste les catégories réelles (5 packs partagés + perso), avec toggles fonctionnels et persistants. |
| C7 | **Parité de discipline.** Chaque bug corrigé embarque un test de régression (règle §5.9) ; tout texte visible passe par l'i18n (21 locales). | `node ./tools/test/verify-change.cjs` vert sur ce qu'on touche ; pas de littéral français hors i18n. |

---

## 2. État des lieux vérifié (ce qui existe, ce qui est cassé)

Le driver Linux **existe déjà** et est architecturalement complet (daemon de
810 lignes, 22 adapters, tray SNI/yad, kanata, watchers inotify, i18n, keylogger,
LLM). Mais **il n'a jamais tourné sur du vrai matériel** — le CI stubbe tout
evdev/ydotool. Les défauts ci-dessous sont vérifiés par lecture directe du code
(chaque `file:line` a été relu) et par les man pages (étiquetés *mesuré*) ou par
déduction (*déduit*).

### 2.1 Ce qui casse en premier — le daemon est **inerte** sur vrai matériel

1. **`libinput debug-events` masque les keycodes par défaut** *(mesuré, man page)*.
   La commande de capture (`keyboard_hook.lua:150`) omet `--show-keycodes` ; le
   vrai `libinput` obfusque les événements clavier, donc le parseur de lignes ne
   matche **rien** : zéro caractère, zéro hotstring, zéro keylog — sous X11 comme
   sous Wayland. Le CI ne l'attrape pas (subprocess stubbé). En prime `libinput`
   « usually needs to be run as root ».

2. **L'injection est destructrice** *(mesuré + déduit)*. `--clearmodifiers`
   (`injector.lua:120`) n'est pas une option `ydotool` (vocabulaire `xdotool`).
   Comme les backspaces sont envoyés **avant** le `type`, un match efface le
   trigger de l'utilisateur puis échoue à taper le remplacement → perte de
   données. Idem pour `text_sender` (`--delay=0`, `ydotool key --repeat=N` :
   options non documentées).

3. **Aucun cycle de vie `ydotoold`** *(mesuré)*. `ydotool` exige le daemon
   `ydotoold` ; rien ne le lance, ne sonde la socket, ni n'échoue franchement —
   chaque échec d'injection est un `WARN` avalé.

### 2.2 Défauts structurels du moteur

4. **Décodeur evdev = code mort** *(confirmé)*. `input_reader.lua:258` (`M.new`,
   la boucle de lecture des structs 24 octets) n'a **aucun appelant de
   production** — la prod scrape le texte de `libinput`/`evtest` avec des motifs
   Lua. En prime, `OFFSET_TYPE=17`/`INPUT_EVENT_SIZE=24` codent en dur un
   `timeval` 64 bits : faux sur userspace 32 bits.

5. **Lecture bloquante = daemon affamé** *(déduit)*. `_pipe:read("*l")`
   (`keyboard_hook.lua:251`) bloque ; le tray, le tick périodique (250 ms), les
   watchers et le cache de fenêtre active n'avancent **que** quand une touche
   arrive — l'inverse exact de ce que promet l'en-tête du daemon.

6. **Course de l'observe-mode non résolue** *(déduit, connu)*. Pas de grab : les
   touches tapées pendant la fenêtre effacement+retape atteignent l'app
   directement et s'intercalent avec le flux synthétique. La file
   `_begin/_queue/_end_injection` ne fixe que le modèle interne du moteur, pas le
   chemin d'entrée de l'OS.

7. **kanata et le daemon ne se coordonnent pas** *(déduit)*. kanata est lancé
   `kanata --quiet --cfg '…'` **sans `--device`** (`manager.lua:378`) ; le daemon
   choisit indépendamment par nom contenant `keyboard`/`kbd`
   (`device_finder.lua:137-139`), **sans exclusion des périphériques
   virtuels/uinput**. Le daemon lit donc probablement les keycodes **pré-remap**,
   et peut ré-avaler ses propres injections (boucle de feedback).

### 2.3 Défauts du tray + chargement TOML

8. **Aucun transport tray ne fonctionne** *(confirmé)*. Le backend SNI est une
   façade : `RequestName` one-shot (le nom est relâché dès que le process gdbus
   sort), XML dbusmenu écrit dans un fichier temp que personne ne lit, icône
   jamais posée, signal `ItemActivated` que rien n'émet, `pump` bloquant. Le
   fallback yad **crashe au premier lancement** (bug Lua `_yad_kill` appelé
   34 lignes avant sa déclaration `local` → global nil). En plus, mismatch de
   forme : le builder produit `item.menu`/`{title="-"}`, le sérialiseur attend
   `item.items`/`item.separator` — tout sous-menu serait silencieusement perdu.

9. **Le sous-menu ne peut afficher qu'UN groupe** *(confirmé)*. Le groupe est
   dérivé du **répertoire parent** (`loader.lua:68`), donc les 5 packs partagés,
   à plat dans `_shared/modules/hotstrings/`, s'effondrent tous en un unique
   groupe littéralement nommé `hotstrings`. `[_meta]` (descriptions 21 locales,
   `sections_order`), et les flags `auto_expand`/`final_result` sont **jetés**.

10. **État write-only** *(confirmé)*. `enable_all`/`disable_all` appelés par le
    tray **n'existent pas** (`hotstrings_config` n'a que `enable_group`/
    `disable_group`/`toggle_group`) → no-op silencieux derrière un `if`. Les
    toggles ne sont pas persistés ; le menu n'est rebâti qu'au callback de
    l'updater — jamais après un toggle/reload/changement de locale. Perso et
    packs partagés sont **mutuellement exclusifs** (le loader choisit UN
    répertoire ; créer `~/.config/ergopti/hotstrings` masque les 5 packs).

11. **Linux absent du manifeste de menu partagé** *(vérifié)*. `linux` apparaît
    **0 fois** dans `menu_manifest.json` (vocabulaire `ahk`/`hs` seulement) et le
    `menu_builder` Linux ne le lit pas — menu codé en dur, littéraux français
    hors i18n, `i18n_safe` déclaré en global accidentel, `display_name` couvre 16
    codes locale sur 21.

### 2.4 Défauts de correction du moteur (déjà notés dans `TODO.md` Lot 8)

12. Linux **ne déclenche jamais** une hotstring non-`auto_expand` (le loader ne
    lit même pas le champ) ; **pas** de propagation de casse ; **pas** de priorité
    de collision ; sa touche magique par défaut est `\` alors que le manifeste
    partagé dit `★`.

### 2.5 Défauts d'installation / packaging (voir §7)

13. Cinq définitions d'unité systemd qui divergent ; `DISPLAY=:0` codé en dur et
    aucune importation d'environnement de session (casse la bascule X11⇄Wayland) ;
    aucun installeur ne configure uinput/groupe input/règle udev/ydotoold ; abort
    dur sur distro sans apt/dnf/pacman ou sans systemd ; wrapper `shared/` (typo,
    l'arbre est `_shared/`) ; PKGBUILD non-bootable ; assets de release
    incomplets (impossible d'installer depuis la release).

---

## 3. Le paysage technique (ce que la recherche a établi)

> Sources primaires citées dans `docs/research/` (dump des 7 agents). Toute
> affirmation runtime est à **revalider sur matériel réel** — c'est la discipline
> du driver Linux (le CI ne teste rien de tout ça).

### 3.1 Capture + injection : evdev + uinput est la **seule** voie universelle

- **Aucun mécanisme Wayland unique ne couvre tous les compositeurs en 2026.**
  `virtual-keyboard-unstable-v1` (wtype) est **absent de Mutter/GNOME et de
  KWin/KDE** (vérifié dans leurs `meson.build`/`CMakeLists.txt`). `input-method-v2`
  n'est pas implémenté par GNOME et n'admet qu'un seul IME à la fois (évincerait
  fcitx5/ibus). Les **portails** (`RemoteDesktop`/`InputCapture` + libei) ne
  marchent que sur GNOME/KDE, exigent un dialogue de consentement, et
  `InputCapture` est *par conception* réactif (barrière) — **inutilisable** pour
  une détection de trigger toujours active. Il n'existe **aucun** portail
  d'observation clavier permanente : c'est une posture de sécurité délibérée, et
  la raison pour laquelle evdev reste obligatoire.
- **evdev+uinput est agnostique au serveur d'affichage** parce qu'il est au
  niveau noyau. C'est le substrat commun d'espanso (backend Wayland), keyd,
  kanata, kmonad, xremap, dotool, ydotool.
- **Bindings LuaJIT-FFI existants** pour ne pas tout réécrire :
  `LJIT2libevdev`, `MunifTanjim/lua-evdev` (via `libevdev.so`), ou lecture
  directe du struct (à la `Tangent128/lua-evdev`) — cette dernière évite une
  dépendance `libevdev.so` versionnée, on ne dépend que du `struct input_event`
  ABI-stable du noyau. **Reco : FFI + lecture directe du struct** (via
  `ffi.sizeof`, ce qui tue l'hypothèse 24 octets/64 bits d'un coup).

### 3.2 Le grab (EVIOCGRAB) est ce qui corrige la corruption à la racine

Les observateurs sans grab (espanso) *documentent notre bug* : désync de
modificateurs et intercalage sur frappe rapide (espanso issues #588, #914,
#1507, #1575). Les daemons qui **grab + ré-émettent** (keyd, kanata, kmonad,
xremap) possèdent l'ordre des événements et peuvent **mettre en file** les
touches tapées pendant l'expansion. `EVIOCGRAB` + ré-émission via notre propre
uinput est le **seul** design qui corrige C4.

### 3.3 Coordination kanata : chaîner, pas rivaliser

- Le périphérique de sortie de kanata s'appelle **exactement `kanata`** (défaut
  `linux-output-device-name`), et kanata **s'auto-exclut** par un test de nom
  codé en dur (`if device.name() == Some("kanata")`). Tout **autre** clavier
  virtuel est capturable — y compris `ydotoold virtual device` : sous
  auto-détection, kanata **re-remap notre texte injecté** (confirme le bug 7).
- **Fix :** générer le defcfg kanata avec
  `linux-dev-names-exclude ("ydotoold virtual device" "ergopti virtual keyboard")`,
  `linux-device-detect-mode keyboard-only`,
  `linux-continue-if-no-devs-found yes` ; supprimer le `--auto-detect` fantôme
  (ce n'est **pas** un flag CLI kanata — la sélection se fait en defcfg). Notre
  daemon lit le périphérique **`kanata`** (keycodes **post-remap** = ce que voit
  l'app, ce qui corrige le bug de keycodes pré-remap), et injecte sur un
  périphérique nommé `ergopti virtual keyboard` que kanata exclut.
- **kanata ne peut pas remplacer notre moteur** : `defseq` exige une touche
  leader `sldr` ; `zippychord` ne se déclenche que sur accords **simultanés**
  (`g` puis `i` sans relâche), pas sur une abréviation tapée normalement ; pas de
  terminateurs par entrée, pas de propagation de casse, unicode « may be broken
  entirely » sous Wayland. Décision confirmée : on garde notre moteur.

### 3.4 Le problème de disposition (layout) — ne jamais supposer QWERTY US

uinput envoie des **keycodes** ; le compositeur (ou le serveur X) applique la
disposition XKB de l'utilisateur **par-dessus, de façon identique sous X11 et
Wayland** — XKB est l'unique étage de mapping, XInput2 ne re-mappe pas au-dessus.
Injecter du **texte** exige donc le mapping inverse
`caractère → (keycode, groupe, niveau, masque de modificateurs)` sous la
disposition **active**. C'est *exactement* le problème de `xdotool type`, et il
est **uniforme** sur les deux serveurs : donc il ne pousse **pas** vers un backend
X11 séparé, c'est une propriété de la voie uinput partagée. keyd/kanata
l'esquivent en ne faisant que du keycode→keycode ; un injecteur de texte ne le
peut pas. ydotool suppose US → charabia sur Dvorak/allemand/
français (issues #43, #254, #22, #249). La bonne réponse, disponible depuis
**libxkbcommon 1.8.0** (fév. 2025) : demander au serveur sa disposition réelle —
`xkbcli dump-keymap-wayland` si `$WAYLAND_DISPLAY`, `xkbcli dump-keymap-x11`
sinon (**cette branche EST la détection X11/Wayland demandée**, sans code
spécifique au compositeur), puis `xkbcli how-to-type` pour construire une table
cache, rafraîchie sur signal de changement de disposition. Fallback :
`setxkbmap -query` (X11), `gsettings … input-sources` (GNOME), sinon override
utilisateur dans le TOML.

### 3.5 La leçon d'espanso : caractères non typables → **presse-papiers**

Le backend `Auto` d'espanso sur Linux n'injecte au clavier **que** le texte
pur-ASCII sous 100 caractères ; **tout le reste passe par le presse-papiers**
(coller Ctrl+V / Shift+Insert sous Wayland, avec save→set→delay→restore).
Vu que nos remplacements sont massivement accentués (C5), le chemin
presse-papiers sera le chemin **courant**, pas l'exception. Il contourne
dead-keys, AltGr, et l'arithmétique de backspace sur graphèmes multi-codepoints.
À adopter, avec ses pièges documentés (flicker GNOME, save/restore racé avec les
gestionnaires de presse-papiers, terminaux en Ctrl+Shift+V).

### 3.6 Tray : StatusNotifierItem, persistant, avec extension GNOME

SNI/`com.canonical.dbusmenu` est le seul mécanisme tray cross-desktop sur Wayland
(le systray XEmbed X11 est mort). Natif sur KDE, XFCE ≥ 4.16 (plugin Status Tray
fusionné dans le panel), LXQt, Budgie, COSMIC, la plupart des panels wlroots
(waybar — beta/parfois instable, ags/eww/hyprpanel). **GNOME Shell n'a toujours
pas de SNI natif en 2026** → extension AppIndicator/KStatusNotifierItem requise (à
documenter, non corrigeable de notre côté).

**Décision clé : ne PAS hand-roll le dbusmenu en `gdbus` one-shot** (c'est
exactement pourquoi le tray actuel est une façade cassée : `RequestName` transient
qui relâche le nom, XML jamais servi). Il faut un **processus persistant** qui
reste sur le bus et *sert* `GetLayout`/`GetGroupProperties`/`Event`/`AboutToShow`
— ce que `gdbus` en ligne de commande ne fait pas (il *appelle*/*émet*, il n'*héberge*
pas un objet). Options réalistes, de la meilleure à la moins bonne :
1. **FFI LuaJIT → `libayatana-appindicator`** (dbusmenu géré pour nous) ou
   GLib/Gio pour servir les objets — voie propre puisqu'on a déjà FFI.
2. **Petit sidecar** contre une implémentation prête : crate Rust **`ksni`** (SNI +
   dbusmenu complet, ~200 lignes de glue) ou `fyne.io/systray` (Go).
3. `yad --notification` **uniquement** en fallback X11-XEmbed (invisible sur GNOME
   et panels Wayland sans XEmbed).
Pour les WM sans hôte SNI (dwm/i3/vieux XFCE) : proxy **`snixembed`** (SNI→XEmbed).
espanso **n'a aucun tray Linux** à copier (son search-bar est indisponible sous
Linux) ; ksni est ce qu'utilisent les daemons Rust/Go qui affichent un tray.

### 3.7 Permissions et universalité distro

- **Accès `/dev/input` (lecture)** : groupe `input` (défaut des distros), mais
  **équivaut à un keylogger global** — à afficher franchement dans
  l'onboarding. ⚠ **Ne PAS utiliser `uaccess` sur `/dev/input`** : la guidance
  systemd/udev l'interdit explicitement (« unprivileged raw keyboard access would
  make keylogging trivial ») — le seat logind accorde une ACL pour les
  caméras/GPU mais *délibérément pas* pour l'input. Alternative plus stricte : un
  **groupe dédié** + helper privilégié dont seul l'utilisateur du service est
  membre. `setcap cap_dac_override+p` reste une option (voie espanso).
- **Accès `/dev/uinput` (écriture)** : règle udev
  `KERNEL=="uinput", MODE="0660", GROUP="uinput", OPTIONS+="static_node=uinput"`
  (le `static_node` est essentiel car `/dev/uinput` n'existe pas tant que le
  module n'est pas chargé) + groupe dédié `uinput` + chargement du module via
  `/etc/modules-load.d/uinput.conf`. C'est la recette de kanata.
- **Piège LuaJIT statique-musl** *(mesuré, classe de bug documentée)* : le JIT
  utilise le NaN-tagging et exige que son allocateur obtienne de la mémoire dans
  le **bas de l'espace d'adressage** via `mmap` ; sous PIE/ASLR durci (probable
  sur build statique-musl), l'allocation JIT peut échouer (issues LuaJIT #49,
  #671 ARM64 ; tarantool #2643). **À smoke-tester explicitement** : ne pas se
  contenter de « ça compile », vérifier que le JIT tourne (ou fallback
  interpréteur `-joff`).
- **glibc version skew** : un binaire lié dynamiquement contre une glibc récente
  casse sur Debian stable/RHEL. Pertinent si on distribue un LuaJIT compilé ;
  moins si on dépend du LuaJIT du système (présent partout, y compris Alpine).
- **Non-systemd** : pas de réponse portable unique — systemd `--user` en primaire
  (couvre la majorité) + **autostart XDG `.desktop`** (init-agnostique, tout DE) en
  fallback + scripts OpenRC (Alpine/Gentoo)/runit (Void) à la main, comme kanata.
  Un daemon lisant `/dev/input` veut être un service **`--user`** (tourne sous
  l'utilisateur de la session), pas system.
- **NixOS** : un script qui hardcode `/usr`/`#!/bin/bash` ne tourne pas. Livrer un
  **flake** exportant `nixosModules.<nom>` (câble uinput/udev/service
  déclarativement, comme `services.kanata`) + `homeManagerModules.<nom>` (daemon +
  config utilisateur). **Pas** de `curl | sh` vers `/usr`.
- **Immuables** (Silverblue/Kinoite/SteamOS/MicroOS) : `/usr` en lecture seule →
  installer binaire+config dans `~/.local`/`~/.config` + `systemd --user`
  (tout sur `/home` writable, survit aux updates atomiques). `/etc/udev/rules.d` et
  `/etc/modules-load.d` **sont** writable (overlay `/etc`) → la règle uinput + le
  module-load y vont via **un** `sudo`. ⚠ Les scriptlets RPM `%post` qui écrivent
  dans `/sys/.../uinput` **échouent** sur rpm-ostree (rootfs read-only) — ne pas en
  mettre.
- **Flatpak/Snap** : un daemon qui a besoin de `/dev/uinput` **ne peut pas** être
  un Flatpak normal (uinput non partagé avec le sandbox, `--device=all` échoue,
  jugé sandbox-escape). **Packaging natif obligatoire** pour le daemon ; Flatpak
  réservé à un éventuel éditeur de config compagnon.

### 3.8 Le menu n'est partagé qu'à ~20 % aujourd'hui — mutualiser au maximum

C'est le constat unanime des 4 agents de cartographie de parité, et c'est
l'occasion de faire mieux. « Le menu est partagé » n'est vrai qu'à moitié :

- `menu_manifest.json` décrit la **structure de premier niveau** (ordre des
  rangées, types, clés i18n, filtre `platforms`). Son renderer AHK
  (`MenuRenderer_Build`) **accepte déjà le token `"linux"`** (`_MR_IsForPlatform`).
- **macOS ne lit même pas le manifeste** : son sous-menu hotstrings est
  **assemblé à la main** (`ui/menu/builder.lua:319-449`), et un simple *drift-gate*
  vérifie que la forme du manifeste correspond.
- **~80 % des rangées visibles** (les sous-menus par catégorie, les toggles par
  section, les compteurs, les arbres perso/extensions, tout label à valeur
  courante) sont générées par du **code driver**, pas par le manifeste.
- **Les deux drivers matures divergent déjà** : macOS a 4 toggles d'aperçu (bulle
  ★/autocorrection/IA + colorés) dans le tray, Windows **non** (son `ShowTooltip`
  par catégorie vit dans la fenêtre WebView partagée) ; macOS rend `repeat_key`
  malgré son tag `platforms:["ahk"]`. Sans certification, la dérive est la norme.

**Ta proposition est donc la bonne** — et la faire pour Linux, c'est le moment de
la faire pour les trois. L'architecture cible (= invariant **I3** + Lot 5 de
`TODO.md`) en **4 couches** :

| Couche | Rôle | Où | Partagé ? |
| --- | --- | --- | --- |
| **1. Manifeste** (donnée) | *Ce que* l'utilisateur voit : chaque rangée déclarée, y compris celles codées en dur aujourd'hui (sous-menus par catégorie, toggles par section via un `provider`, compteurs via `count`+`count_policy`, coches `checked_when`, labels à valeur `label.format`+`args`, `platforms`, `visible_when`/`disabled_when`) | `_shared/modules/menu/menu_manifest.json` | **100 %** |
| **2. Renderer** (code) | Parcourt le manifeste, résout l'i18n, appelle les getters/providers du driver, émet un **arbre de menu neutre** `{label, kind, checked, enabled, submenu, action_id}` | `_shared/lua/menu/render.lua` | **macOS + Linux** (les deux en Lua) — AHK garde son `MenuRenderer_Build`, tenu identique par la gate |
| **3. Host OS** (code, petit) | Dessine l'arbre neutre avec la toolkit OS : `hs.menubar` (macOS), SNI/dbusmenu (Linux), `Menu` AHK (Windows) | `<driver>/infra/menu_host.*` | par-OS (mince) |
| **4. Le driver ne fournit QUE** | un **registre d'actions** (id → callback), des **getters d'état** (`is_enabled`, char trigger courant, délai courant) et des **providers** (catégories, sections, compteurs) | `<driver>/…` | logique dans `_shared/lua/*` quand c'est du Lua pur |

**Le « modulo OS » devient de la donnée, pas du code divergent** : un
`platforms:["windows","macos","linux"]` par entrée + prédicats
`visible_when`/`disabled_when` + un `reason_key` pour les features absentes sur une
plateforme (rangée grisée avec tooltip = Convention S « stub avec raison »). La
différence est **auditable** parce qu'elle est déclarée.

**La certification — le cœur de ta demande** : une gate qui *rend* le manifeste
pour les 3 plateformes et *diffe* les arbres de labels, en assertant qu'ils sont
identiques **sauf** là où `platforms`/`visible_when` diffèrent explicitement :
- `test-menu-parity.cjs` (I3) — rend les 3, diffe les arbres.
- ratchet **« aucune rangée de menu créée hors du renderer »** (baseliné aux sites
  émetteurs actuels : 265 AHK + 399 macOS + 101 Linux) — personne ne peut
  rajouter une rangée divergente à la main.
- bijection `action_id ↔ handler` dans les deux sens (toute action du manifeste
  résout un callback réel sur chaque driver ; tout callback est référencé).
- « toute clé-tableau du manifeste a un lecteur ».
Ainsi « le menu est identique sur chaque OS » devient un **invariant vérifié par
la CI**, pas une discipline.

**La frontière honnête (AHK)** : Windows est en AHK — il partage la **donnée**
(manifeste, i18n, registre d'actions, `defaults.toml`, catalogue Terminators, la
fenêtre WebView de config partagée) mais **pas le code Lua** du renderer. Son
`MenuRenderer_Build` reste, tenu identique par la gate. Donc « maximum dans
`_shared` » = manifeste + i18n + registre d'actions + renderer Lua (macOS+Linux) +
logique de feature (`_shared/lua/*`) ; par-OS = seulement le host (dessiner une
rangée) + les deltas `platforms` + le jumeau renderer AHK.

**Ce qui est déjà réutilisable tel quel** (mesuré) : `menu_manifest.json`, les clés
i18n (21 locales), `_shared/modules/hotstrings/defaults.toml` (délais canon
0.75 s / 2.0 s), le catalogue Terminators (`_shared/lua/keymap/terminators.lua`,
neutre, 5 fonctions), la fenêtre WebView `hotstrings_config_window` (déjà
enregistrée côté Linux), `_shared/modules/tooltip/constants.toml` (SSOT de style,
lu fail-fast), les oracles JS (tint/layout/dequeue). Le donneur idéal pour Linux
est **macOS** : `hotstrings_config.lua` (résolveur de délais + override) est du Lua
pur, quasi copiable.

**Bénéfice** : au lieu de coder un menu Linux jetable, on écrit le renderer
partagé **une fois** (macOS l'adopte aussi, supprimant son assemblage manuel et son
drift-gate), et les trois drivers convergent — la création ET la maintenance du
driver Linux, et des deux autres, s'en trouvent durablement allégées.

---

## 4. Alternatives rejetées (à ne PAS re-proposer)

| Idée | Pourquoi rejetée |
| --- | --- |
| **Adopter espanso comme moteur** | Déjà rejeté (`README.md:22-40`) : besoin de log par frappe pour les métriques, terminateurs par entrée, touche magique, état in-process partagé avec le keymap. On en tire des **leçons**, on ne l'adopte pas. |
| **Split binaire X11 vs Wayland (compile-time)** | C'est exactement la verrue d'espanso (issue #2137). Viole C1. La détection runtime + evdev/uinput l'évite. |
| **Protocoles Wayland « propres » (virtual-keyboard-v1, input-method-v2)** | Absents de GNOME **et** KDE (les deux plus gros desktops). Ne peuvent pas être la voie unique. Utilisables au mieux en *fast-path opportuniste* sur wlroots. |
| **Portails + libei comme capture** | `InputCapture` est réactif par conception, inutilisable pour un trigger toujours actif. Injection possible sur GNOME/KDE seulement. Optionnel en 2ᵉ backend d'injection, jamais l'unique. |
| **`kanata` defseq/zippychord pour les hotstrings** | Mauvais modèle de déclenchement (leader/accords simultanés), pas de terminateurs ni de casse, unicode Wayland cassé. |
| **Rester en observe-mode (libinput/evtest scraping)** | Masquage des keycodes = daemon inerte ; lecture bloquante = daemon affamé ; pas de grab = corruption C4. La voie FFI evdev résout les trois. |
| **`ydotool` comme injecteur principal** | Suppose US (charabia accentué), pas de `--clearmodifiers`, dépend de `ydotoold` root, un fork par événement en pass-through. Gardé **au mieux** en fallback ASCII. |
| **Garder `M.new` (décodeur) en double du chemin scraping** | Divergence garantie. Soit on en fait la voie de prod (FFI), soit on le supprime — pas de copie morte parallèle. |

---

## 5. Le plan par jalons

Ordre de dépendance : **coordination d'abord, moteur ensuite, layout/tray/
packaging après.** Chaque tâche note le test de régression qu'elle embarque
(règle §5.9). Chaque tâche runtime porte la mention **[MATÉRIEL]** = à valider sur
une vraie machine avant merge (le CI ne le couvre pas).

### M0 — Coordination des périphériques (fondation, faible risque)

Sans ceci, le moteur lit les mauvais keycodes et boucle sur ses injections.

- [x] **M0.1** Générer le defcfg kanata avec `linux-dev-names-exclude`
  (`"ydotoold virtual device"`, `"ergopti virtual keyboard"`),
  `linux-device-detect-mode keyboard-only`, `linux-continue-if-no-devs-found yes`.
  Supprimer le `--auto-detect` fantôme du commentaire et du lancement.
  *Test :* gate étendant `test-kanata-defalias-parity` — le defcfg généré
  contient les exclusions et le mode ; snapshot golden.
  → **Corrections au plan.** (a) Le nom réel du périphérique est
  `Ergopti Virtual Keyboard` (majuscules) et non `ergopti virtual keyboard` ;
  `linux-dev-names-exclude` matche **exactement**, donc la chaîne du plan
  n'aurait rien exclu du tout. (b) `--auto-detect` n'a jamais été passé au
  lancement — il n'existait que dans trois commentaires, tous corrigés.
  (c) Le defcfg n'est pas *généré* : le générateur n'émet que le bloc
  `defalias` et le préfixe du template est recopié tel quel. Les noms vivent
  donc une seule fois dans `linux/infra/device_names.lua`, lu par
  `uinput_writer` et `device_finder`, et une gate épingle le `.kbd` dessus.
- [x] **M0.2** `device_finder` : exclure les périphériques dont le parent sysfs
  est `uinput` ou dont le nom matche `ydotool|kanata|ergopti|virtual`. Choisir
  explicitement de lire le périphérique **`kanata`** (post-remap) quand kanata
  tourne, sinon le physique.
  *Test :* fixtures `/proc/bus/input/devices` incluant un périph `kanata` et un
  `ydotoold` → `find_keyboard()` retourne `kanata`, jamais un virtuel.
  → Le danger était pire que « non coordonné » : `Ergopti Virtual Keyboard`
  contient « keyboard », donc notre propre périphérique d'injection était dans
  le rang **préféré**, au-dessus du clavier physique. L'exclusion se fait
  d'abord sur `S: Sysfs=/devices/virtual/` (réponse du noyau, couvre les
  injecteurs qu'on ne connaît pas), les noms ne servant que de repli. La
  préférence `kanata` est évaluée **avant** l'exclusion, sinon elle l'écarterait.
  Deux seams purs (`parse_devices`, `select`) rendent le tout pilotable par
  fixture — c'est leur absence qui empêchait d'écrire le test.
- [x] **M0.3** Un seul propriétaire de config kanata : supprimer le symlink
  `install.sh` ; `manager.write_kbd()` seul écrivain de
  `~/.config/kanata/ergopti.kbd`.
  *Test :* le manager écrit un vrai fichier (pas à travers un symlink vers
  l'arbre source).
  → Le symlink corrompait **le template suivi** : `write_kbd()` ouvre ce chemin
  en écriture à chaque démarrage, donc le premier redémarrage suivait le lien et
  réécrivait `platform/remap/data/kanata.kbd` dans l'arbre installé — le fichier
  que la gate de parité lit était réécrit par le générateur qu'elle vérifie.
  `install.sh` sème désormais une **copie** ; cela ferme aussi le trou d'ordre
  que le lien masquait (l'unité kanata est activée avant que le daemon n'ait
  jamais tourné).

### M1 — Le cœur : FFI evdev in / uinput out + grab (le gros morceau)

Corrige d'un coup les bugs 1, 4, 5, 6, 7. C'est **le** jalon qui rend les
hotstrings fonctionnelles sur vrai matériel, X11 et Wayland.

- [x] **M1.1** Écrire un **lecteur evdev FFI** : `ffi.cdef` du `struct
  input_event`, `ffi.sizeof` (tue l'hypothèse 24 o/64 bits), ouverture
  `O_NONBLOCK`, `poll()` piloté par l'event loop (fin de la lecture bloquante).
  Remplacer `libinput/evtest` scraping. Réutiliser `resolve_char`/`evdev.json`
  comme source unique de keycodes. **Supprimer** `M.new` mort ou en faire cette
  voie — pas de copie parallèle.
  *Test :* harnais **[MATÉRIEL]** créant un uinput de test, y écrivant des
  événements, et assertant le décodage. Sur CI : décodage de structs synthétiques
  (le décodeur cesse d'être du code mort avec couverture réelle).
  → `adapters/evdev_reader.lua` (backend syscall interchangeable, comme
  `uinput_writer`) + `infra/input_event.lua` (le struct, **une** fois, dans les
  deux sens). Taille mesurée par `ffi.sizeof`, offsets **dérivés** de la taille :
  le cas 32 bits n'a plus de branche et ne peut plus être oublié. `M.new` mort
  supprimé avec ses copies parallèles du shift, des touches de contrôle et du
  struct. Corrections au plan : (a) la voie vivante en production était
  `evtest --grab`, pas `libinput` — le masquage de keycodes ne cassait plus que
  l'échappatoire ; (b) `O_NONBLOCK` suffit à tuer la lecture bloquante, `poll()`
  est là pour qu'une boucle puisse dormir sur l'entrée, pas pour la correction.
- [x] **M1.2** Écrire un **écriveur uinput FFI** : `UI_SET_EVBIT`/`UI_DEV_SETUP`/
  `UI_DEV_CREATE` au démarrage (nom `ergopti virtual keyboard`), `write()` par
  événement ensuite. **Zéro fork** par événement (fin de la dépendance ydotoold,
  du flag invalide, du fork-par-frappe). Ré-émettre EV_KEY + EV_SYN.
  *Test :* [MATÉRIEL] injection round-trip via une deuxième lecture uinput.
  → L'écriveur existait déjà, testé au niveau octet, et **injoignable** :
  `open_fast_channel()` n'avait aucun appelant hors de son propre test, donc
  `emit_key` retombait sur un `ydotool key` par frappe physique — sous un grab
  activé par défaut au motif que ça n'arrivait plus. Le canal s'ouvre maintenant
  **avant** le grab et se ferme après, sur les deux chemins de sortie. Le repli
  ydotool de `emit_key` est supprimé : il refuse et le dit, et le daemon échoue
  franchement au boot avec la raison. Les backspaces passent aussi par uinput.
- [x] **M1.3** **Grab + ré-émission** (`EVIOCGRAB` via ioctl FFI sur le périph
  `kanata`) : ré-émettre **tout** (relâches, autorepeat valeur 2, codes inconnus,
  modificateurs) sur notre uinput **avant** dispatch domaine. Pendant une
  expansion, mettre en pause le forwarding → effacement+retape **atomique**, et
  file des touches tapées pendant. Corrige C4 à la racine.
  *Test :* [MATÉRIEL] frappe rapide pendant expansion → sortie déterministe ;
  garde-fou : ungrab sur panic/exit (sinon clavier mort).
  → Le grab appartient au daemon (plus à un process enfant), et l'ordre est
  épinglé par des tests : grab **avant** la première lecture, ungrab **avant** la
  fermeture. Pas de « pause du forwarding » à écrire : avec le grab et un drain
  séquentiel, ce qui est tapé pendant l'injection reste dans le buffer noyau et
  est lu **après** — l'atomicité est structurelle. Le garde-fou ungrab-sur-panic
  n'existe pas non plus, et c'est délibéré : `EVIOCGRAB` est lié au descripteur
  et le noyau le relâche à la mort du process, quelle qu'en soit la cause.
  **Divergence corrigée au passage** : l'autorepeat produit désormais un
  caractère. Sous grab l'application voit ce qu'on ré-émet, répétitions
  comprises ; un buffer qui ignorait la valeur 2 croyait « a » quand l'écran
  disait « aaaa », puis effaçait le mauvais nombre de caractères.
- [x] **M1.4** Watchdog / ré-acquisition : inotify sur `/dev/input` pour attendre
  l'apparition du périph `kanata` et le re-grab sur restart/reload kanata ;
  fallback grab du physique si kanata absent.
  *Test :* apparition/disparition simulée du périph → ré-acquisition.
  → Sondage du tick périodique (toutes les 2 s) plutôt qu'inotify : `luv` n'est
  pas installé en CI, donc une voie inotify serait la seule non testée du lot, et
  l'événement surveillé arrive au plus deux fois par jour. Deux causes couvertes :
  clavier débranché/rebranché (nouveau nœud `eventN`) et redémarrage du daemon de
  remap (son périphérique de sortie est détruit puis recréé — la perte ne coupe
  pas la capture, elle la **dégrade** silencieusement vers des keycodes pré-remap).

### M2 — Injection correcte multilingue + détection serveur partagée

- [x] **M2.1** Une **lib de détection X11/Wayland partagée** (`XDG_SESSION_TYPE`/
  `WAYLAND_DISPLAY`), consommée par layout, `window_info`, `clipboard`,
  `text_sender`. Le cœur hotstrings, lui, n'a **aucune** branche (evdev/uinput).
  *Test :* la lib retourne `wayland`/`x11` selon l'env ; single-source (un seul
  point de détection).
  → `infra/display_server.lua`. L'ordre est tout le contenu : `WAYLAND_DISPLAY`
  bat `DISPLAY` (XWayland exporte `DISPLAY` aussi — le tester d'abord classe
  **tous** les bureaux modernes en X11), et une socket bat `XDG_SESSION_TYPE`
  (plusieurs gestionnaires de session écrivent `tty` pour une session graphique
  parfaitement valide). Cache + `refresh()` explicite, pour que la bascule
  logout-X11 → login-Wayland soit une propriété du driver et non du gestionnaire
  de services. Expose aussi l'identité du compositeur : « Wayland » ne dit pas
  comment poser la question.
- [x] **M2.2** **Résolution de disposition** : `xkbcli dump-keymap-{wayland,x11}`
  → table cache `char → (keycode, groupe, niveau, mods)`, rafraîchie sur signal
  de changement. Fallbacks `setxkbmap -query` / `gsettings` / override TOML.
  Jamais de table US codée en dur.
  *Test :* [MATÉRIEL] une disposition azerty et une bépo produisent le bon
  keycode pour `é`, `ç`, `à`. CI : mapping depuis un keymap XKB fixture.
  → Trois couches séparables, chacune testable sans serveur d'affichage :
  `infra/xkb_keymap.lua` (texte → keysym/keycode/niveau, offset XKB→evdev de 8
  appliqué **une** fois), `infra/keysym.lua` (nom de keysym → caractère : FFI
  libxkbcommon si présente, sinon le bloc Latin-1 de `keysymdef.h` + les
  écritures Unicode — ce n'est **pas** une table de disposition, elle est
  identique sur toutes les machines), et `adapters/keyboard_layout.lua` (la
  jointure, le cache, et le refus de deviner).
  → **Fallbacks du plan écartés, avec raison** : `setxkbmap -query` ne rend que
  le *nom* de la disposition, pas le mapping ; `gsettings` de même. Le repli
  X11 est `xkbcomp -xkb "$DISPLAY" -`, qui rend le vrai keymap et existe partout
  où il y a un serveur X. Sous Wayland il n'y a aucun repli : le keymap d'un
  compositeur n'est pas lisible de l'extérieur. Sans keymap, `resolve()` rend
  `nil` pour tout et l'expansion passe par le presse-papiers — retomber sur une
  table US intégrée est exactement le défaut remplacé : il n'échoue pas, il tape
  les mauvais caractères. Override par `--keymap <fichier>`.
  → Tests pilotés par un dump **AZERTY**, délibérément : sur US, « a » est le
  keycode 30 que la disposition ait été lue ou non, donc une table codée en dur,
  un parse silencieusement vide et l'implémentation correcte sont
  indiscernables.
- [x] **M2.3** **Fallback presse-papiers** pour texte non-typable (accents hors
  niveau ≤3, emoji, texte long) : `wl-copy`/`wl-paste` (kill-timeout) sur
  Wayland, `xclip`/`xsel` sur X11, save→set→delay→paste(Shift+Insert Wayland)→
  restore. Router les remplacements accentués par là (leçon espanso).
  *Test :* [MATÉRIEL] `NT’ ➜ N’T` et une phrase accentuée s'insèrent correctement.
  → **La prémisse du §3.5 est désormais fausse** et c'est le point important : le
  presse-papiers devait être le chemin *courant* parce qu'on ne savait pas taper
  les accents. Avec M2.2 on sait — é, ç, «, € et tout ce que la disposition de
  l'utilisateur produit sortent en vraies frappes. Le presse-papiers ne porte
  plus que ce qu'**aucune touche** ne peut produire (emoji, CJK). Meilleure
  chose à rendre rare : coller est visible, court après les gestionnaires de
  presse-papiers, et détruit ce que l'utilisateur avait copié si on ne le
  restaure pas. Ctrl+V et non Shift+Insert : c'est ce que lie chaque toolkit.
  → **ydotool est sorti du chemin de frappe**, comme le veut la décision §6.1 :
  il n'a jamais été un repli pour le cas qui en atteint un (il suppose US, donc
  un caractère que la disposition ne sait pas taper est exactement celui qu'il
  rate) et il ne peut pas tourner sous le grab. Le seam shell de l'injecteur est
  supprimé avec lui ; la pause inter-phase passe par `nanosleep` en FFI plutôt
  que par un `fork` de `/bin/sleep` par expansion.
- [x] **M2.4** Kit de sûreté d'espanso, porté : fenêtre de discard (ignorer notre
  propre écho), attente de relâche des modificateurs avant injection, comptage de
  backspace en **codepoints Unicode**, undo (backspace après expansion restaure
  le trigger), invalidation sur clic souris.
  *Test :* comptage backspace correct sur remplacement multi-octets ; undo.
  → **Fenêtre de discard : superflue, et c'est structurel.** L'injection sort sur
  un périphérique uinput distinct de celui qui est grabbé, donc notre propre écho
  n'est jamais relu. Une fenêtre temporelle par-dessus serait un second mécanisme
  pour une garantie déjà tenue.
  → **Attente de relâche : impossible, remplacée par la neutralisation.** Le
  relâchement est dans le buffer noyau que l'injection, en cours, ne lit pas —
  attendre serait un interblocage. L'injecteur **relâche** donc les modificateurs
  de niveau tenus (Shift, AltGr), tape, puis les **represse**. Déterministe.
  → **Deux défauts trouvés en chemin, hors plan.** (1) Ctrl+S n'est pas la lettre
  S : la disposition résout un caractère quel que soit l'état de Ctrl, donc
  **chaque raccourci alimentait le buffer** et une expansion pouvait se
  déclencher sur du texte que personne n'avait tapé. (2) AltGr n'est pas Alt : le
  hook les repliait sur un seul drapeau, donc « supprimer les raccourcis » et
  « taper les accents » étaient le même interrupteur — sur un clavier français,
  é, € et « sont en niveau 3.
  → **Clic** : le pointeur est ouvert en lecture seule (jamais grabbé — un
  pointeur consommé, c'est un bureau sans souris) et une pression de bouton vide
  le buffer. Le lecteur evdev est devenu multi-slot pour ça.
  → **Comptage backspace** : déjà en codepoints côté moteur (le corpus le pinne),
  et l'undo l'est aussi — décalé de un, parce que le Backspace a déjà été
  ré-émis vers l'application avant que le callback ne tourne.
- [x] **M2.5** `window_info` : vraie voie Wayland (`swaymsg`/`hyprctl` wlroots,
  introspection GNOME / portail fenêtre active pour Mutter) au lieu de
  xdotool-only, sinon `app_id=""` casse la suppression mot-de-passe. **Documenter
  que l'app-id n'est pas universel sous Wayland** (leçon espanso : les règles
  par-app réintroduisent la fragmentation). Router via `shell_runner`.
  *Test :* détection app_id mockée par serveur.
  → `swaymsg`/`hyprctl`/`niri msg` implémentés. **Pas** d'introspection GNOME :
  Shell.Eval a été retiré en 41 et il n'existe aucune voie non privilégiée ;
  KDE, COSMIC et Weston n'exposent rien d'équivalent. Ces sessions obtiennent une
  ligne de log nommant le compositeur et une identité vide — énoncée plutôt que
  déboguée. XWayland n'est **délibérément pas** un repli : il ne répond que pour
  les clients X11, donc les règles marcheraient sur la moitié d'un bureau, ce qui
  se lit comme « instable » et non comme « non supporté ».
  → **Portée doublée par rapport au plan** : `process_lifecycle` portait une
  **seconde** implémentation xdotool indépendante, et c'était *elle* qui
  alimentait le cache d'application du chemin de frappe — corriger `window_info`
  seul n'aurait rien changé pour l'utilisateur. Elle délègue désormais, et son
  signal de changement est passé de l'ID de fenêtre au **titre** : un navigateur
  qui bascule en navigation privée garde son process et sa fenêtre, et c'est
  exactement la transition que la suppression mot-de-passe existe pour voir.

### M3 — Fondation du menu partagé + transport tray

> **État au 2026-08-04.** M3.1, M3.2 et M3.5 sont faits. **M3.3, M3.4 et M3.6
> restent**, et leur ordre est contraint : `test-menu-rows-outside-renderer.cjs`
> désigne `linux/ui/menu/menu_builder.lua` comme « le renderer Linux » (baseline
> 3/3, zéro marge) et `test-menu-top-level-parity.cjs` extrait la forme du menu
> en regexant les appels `_build_*(ctx)` **de ce même fichier**. Supprimer
> `menu_builder.lua` — le livrable de M3.3 — casse les deux, qui doivent donc
> être repointées dans le même changement, sinon la suppression atterrit avec
> deux ratchets aveuglés. Lire l'en-tête `:53-71` de la première avant de
> planifier l'ordre de migration : router une rangée par `ManifestMenu.build` ne
> fait **pas** baisser le compte ; seule une migration de type `list` l'a jamais
> fait.

Bâtir le menu Linux **sur la fondation partagée** (§3.8), pas en Linux-only.

- [x] **M3.1** **Transport SNI persistant** : un service qui reste sur le bus et
  *sert* `GetLayout`/`GetGroupProperties`/`Event`/`AboutToShow` — via FFI
  `libayatana-appindicator` (dbusmenu géré) **ou** un petit sidecar `ksni`, **pas**
  des `gdbus` one-shot. Icône posée, `pump` non bloquant. `snixembed` pour les WM
  XEmbed ; documenter l'extension AppIndicator pour GNOME.
  *Test :* round-trip menu imbriqué → dbusmenu réel avec sous-menus (les tests
  tray actuels sont faux-verts) ; réparer le crash `_yad_kill` du fallback.
  → Fait via **FFI LuaJIT + libayatana-appindicator**, pas un sidecar : la façade
  ne pouvait pas fonctionner parce que `gdbus call RequestName` acquiert le nom
  dans le process gdbus, qui sort aussitôt et le relâche. Le XML dbusmenu partait
  dans un fichier temporaire que personne ne lit (un panneau appelle `GetLayout`
  sur D-Bus), aucune icône n'était posée, un moniteur guettait un signal que rien
  n'émettait, et `pump` bloquait sur un pipe **depuis le callback idle** — la
  frappe s'arrêtait jusqu'à ce qu'on clique sur une icône absente. SNI n'est pas
  un appel qu'on fait, c'est un objet qu'on **héberge**.
  → **Le repli yad est supprimé, pas réparé.** Il n'était atteignable que sans
  gdbus, il crashait au premier usage (`_yad_kill()` appelé 34 lignes avant sa
  déclaration `local`), il dessinait un menu plat là où il faut un arbre, et il
  exige XEmbed — qu'aucun panneau Wayland ne fournit. Deux backends cassés ne
  font pas une redondance. Le sérialiseur XML partagé part avec lui.
- [x] **M3.2** **Renderer de menu partagé** `_shared/lua/menu/render.lua` :
  parcourt le manifeste, résout l'i18n, appelle getters/providers, émet l'arbre
  neutre `{label, kind, checked, enabled, submenu, action_id}`. **macOS l'adopte
  aussi** (supprime son assemblage manuel `builder.lua` et son drift-gate ensuite).
  *Test :* le renderer rend un manifeste fixture identique en macOS et Linux.
  → **Déjà fait** avant cette session (commit `d90c11cb3`) : les deux drivers Lua
  sont des liaisons d'une cinquantaine de lignes sur
  `_shared/lua/menu/renderer.lua`, et le token de plateforme est un paramètre.
  Résidus mesurés : le fichier s'appelle `renderer.lua` et non `render.lua`, et
  il émet la forme `hs.menubar` `{title, fn, menu, checked, disabled}` plutôt
  qu'un arbre neutre nommé — ce qui est sans conséquence tant que les deux
  consommateurs Lua parlent cette forme, et c'est le cas.
- [x] **M3.3** **Host de menu Linux** `linux/infra/menu_host.lua` (~180 l) : dessine
  l'arbre neutre en SNI/dbusmenu. Supprime `menu_builder.lua` (889 l codées à la
  main). Consomme `menu_manifest.json` (le renderer AHK accepte déjà `"linux"`).
  *Test :* le host produit le même arbre de labels que macOS pour `hotstrings_menu`.
  → **Deux tiers de la prémisse ne tiennent plus.** Le host SNI existe
  (`platform/tray/appindicator.lua`, livré en M3.1), et le fichier à supprimer
  n'est plus un second menu : **119 de ses 121 sites de rangée sont déjà dans le
  renderer** (mesuré par `test-menu-rows-outside-renderer.cjs --measure`). Le
  supprimer supprimerait les actions nommées, les getters d'état et les providers
  de listes que le renderer partagé **exige du driver** — c'est la même couche que
  macOS possède, en 301 rangées de plus. `infra/manifest_menu.lua` le dit dans son
  propre en-tête : « le renderer ne fait que DISPATCHER ».
  → Ce qui restait vraiment, ce sont les menus encore construits hors renderer.
  `gestures_menu` y est passé : handlers clés par id de manifeste, écrivant dans
  la table que le renderer leur passe — un handler qui écrit dans une table
  capturée émet ses rangées dans un menu que le renderer ne retourne jamais, donc
  toutes les rangées gestures disparaîtraient **sans que rien n'échoue**.
  → Deux trouvailles en chemin : la rangée « Lecture libinput » n'était dans aucun
  manifeste et portait un **libellé français codé en dur**, donc tout utilisateur
  non francophone le lisait en français et aucune gate ne pouvait voir ni l'un ni
  l'autre ; et le toggle maître reste au caller, par contrat du renderer (une
  porte de catégorie est un état de driver, pas une donnée de manifeste).
  → Les deux ratchets bougent dans le bon sens et sont regelés : rangées hors
  renderer sous Linux **3 → 2**, menus rendus par le renderer partagé **3 → 4**.
- [x] **M3.4** **Étendre le manifeste** aux 14 capacités du Lot 5 (`checked_when`,
  `action` résoluble, `label.format`+`args`, `provider` pour listes dynamiques,
  `count`/`count_policy`, `radio_group`, `visible_when`, `reason_key`…) pour que
  les rangées codées en dur (sous-menus catégorie, toggles section, compteurs)
  deviennent des données. Ajouter le token `linux` à `KNOWN_PLATFORMS`.
  *Test :* « toute clé-tableau du manifeste a un lecteur » ; schéma manifeste v-next.
  → **Mesuré avant d'écrire quoi que ce soit**, parce que « ajouter 14 capacités »
  est la description d'un schéma, pas d'un besoin. État réel :
  - `linux` dans `KNOWN_PLATFORMS` : **déjà là** (`test-menu-manifest.cjs:40`).
  - `checked_when` / `disabled_when` : **déjà lus** par le renderer partagé
    (`resolve_checked_when` / `resolve_disabled_when`). Le vrai défaut n'était pas
    l'absence de capacité mais que **macOS ne définissait aucun getter** pour les
    trois `checked_when` de `metrics_menu` — corrigé avec M3.6.
  - `provider` pour listes dynamiques : **déjà là**, c'est le type `list` +
    `list_providers`.
  - `reason_key` : déclaré sur 5 rangées, **lu par personne**. Le renderer jetait
    la rangée avec sa restriction, donc cinq explications traduites en 21 langues
    n'ont jamais atteint un seul utilisateur. C'est la capacité qui manquait
    vraiment, et elle est faite : une rangée absente d'ici mais porteuse d'une
    raison se rend **présente et grisée**, avec la raison (convention S). Une
    restriction *sans* raison reste cachée — une rangée grisée qui n'explique rien
    est pire qu'absente, elle occupe le menu et ne répond à aucune question.
  - `label.format`+`args`, `count`/`count_policy`, `radio_group` : **non ajoutés,
    délibérément.** Aucune rangée du manifeste ne les emploie. Ce dépôt a une gate
    « toute clé-tableau a un lecteur » et une autre contre les tests qui ne peuvent
    pas échouer ; ajouter du schéma sans consommateur, c'est exactement ce qu'elles
    punissent. Les comptes et les libellés composés que le plan visait sont
    produits par des `list` providers, qui existent déjà et dont le contenu dépend
    de ce que l'utilisateur a installé — donc ils ne peuvent pas être des données
    du manifeste.
- [x] **M3.5** **Loader corrigé** : grouper par **stem de fichier** (aligné sur
  `_index.toml categories_order` / `hotstring_category_keys`), garder les chemins
  absolus, exposer `[_meta].description` (21 locales) + `sections_order` + identité
  de section + comptes, lire `auto_expand`/`final_result`, exclure les fichiers
  `_`-préfixés. Fusionner perso + packs (perso prioritaire, comme macOS) au lieu de
  l'exclusivité.
  *Test :* les 5 packs → 5 groupes distincts avec labels localisés et comptes ; un
  dir perso ne masque plus les packs.
  → Groupement par **stem de fichier**, `[_meta].description` (21 locales),
  `sections_order`, identité de section et comptes exposés, fichiers `_`-préfixés
  exclus, et perso + packs **fusionnés** par stem au lieu d'être exclusifs.
  Détail qui manquait au plan : `install.sh` copie les packs **à plat** dans le
  répertoire utilisateur, donc la fusion par stem est aussi ce qui évite de les
  compter deux fois.
- [x] **M3.6** **La gate de certification** `test-menu-parity.cjs` (I3) : rend le
  manifeste pour les 3 plateformes, diffe les arbres de labels, assert identiques
  sauf `platforms`/`visible_when`. + ratchet « aucune rangée hors renderer » + la
  bijection `action_id ↔ handler` sur chaque driver.
  *Test :* la gate elle-même (rouge si une rangée diverge sans déclaration).
  → Faite, câblée dans `run-js-suite.cjs`, alias `test:menu-parity`, et
  **mutation-testée** : les trois défauts qu'elle a trouvés repassent au rouge si
  on les réintroduit.
  → **Correction au plan : « diffe les arbres de labels » ne peut pas être
  l'assertion.** Un manifeste tient *un* tableau par menu, donc les trois
  projections sont des sous-suites d'une seule séquence et ne peuvent pas
  diverger sur l'ordre. Une première version vérifiait quand même ; déplacer une
  rangée la laissait verte, parce que le déplacement vaut pour les trois à la
  fois. Elle a été remplacée par des propriétés qui, elles, peuvent échouer —
  et qui ont trouvé trois défauts réels le jour même :
  - `tap_holds` déclaré pour macOS alors qu'aucun fichier macOS ne construit ce
    menu et que *toutes* les rangées de `tap_holds_menu` sont `["ahk"]` : macOS
    ouvrait un sous-menu **vide**. Invisible pour la gate top-level, qui ne lit
    la chaîne macOS qu'à partir de `global_actions` — `tap_holds` est au-dessus.
  - `gestures` non restreint (donc visible sous Linux) alors que le manifeste ne
    projetait qu'**une** rangée pour Linux : un séparateur nu. `_build_gestures`
    construit depuis toujours un toggle, deux actions de masse et tous les slots.
  - `menu.extensions.header` sans `platforms` au-dessus d'une rangée `["ahk"]` :
    un titre sans section dessous sur deux drivers.
  → Elle a aussi trouvé que **macOS ne définissait aucun getter** pour les trois
  `checked_when` de `metrics_menu` : il lisait `state.…` en ligne, donc le
  `checked_when` du manifeste était une seconde déclaration que personne ne
  consultait, pendant que Linux, lui, la résolvait. Deux drivers, deux réponses à
  « où est la vérité » — la seule chose qu'un manifeste existe pour empêcher.

### M4 — Parité des fonctionnalités hotstrings (la demande utilisateur)

Chaque rangée du manifeste branchée sur sa fonction Linux, à l'identique des deux
autres drivers. Donneur privilégié : **macOS** (Lua pur). ⚠ Le trigger `★` dépend
de **M2.2** (résolution de disposition) : `★` est une touche de la couche Ergopti ;
tant que la résolution keycode→char ne produit pas `★`, il reste inatteignable —
c'est *pourquoi* Linux s'était rabattu sur `\`. Une fois M2.2 en place, on aligne
sur le canon partagé `MAGIC_KEY_CHAR="★"`.

- [x] **M4.1** **Registre d'actions + getters/providers** côté daemon : les ~30
  callbacks que le renderer appelle (toggles catégorie/section, `enable_all`/
  `disable_all`/`reset_defaults`, providers de listes catégories/sections,
  providers de comptes gatés, `open_file`). Implémenter `enable_all`/`disable_all`
  (inexistants → no-op silencieux), **persister** l'état via l'adapter storage,
  callback `updateMenu` (rebuild à chaque toggle/reload/locale).
  *Test :* existence de `enable_all` ; persistance après restart ; comptes gatés.
  → `enable_all`/`disable_all`/`reset_defaults` existent (le menu les appelait
  derrière un `if` qui était faux — un clic sans effet, indiscernable d'un clic
  manqué), l'état est **persisté** (chaque bascule était oubliée au redémarrage),
  et un callback `on_change` reconstruit le menu à chaque changement. Bug trouvé
  en chemin : le bridge de la fenêtre de config appelait ces fonctions avec `:`
  alors qu'elles sont plates — toutes les catégories se déclaraient activées et
  toutes les bascules étaient des no-op. Son propre test ne pouvait pas le voir :
  le mock avait été écrit à la convention buguée.
- [x] **M4.2** **Caractère trigger `★` configurable** : lire `[hotstrings]
  trigger_char` (défaut `★`, schéma 1-4 chars) au lieu du `\` codé en dur (3
  endroits) ; `set_trigger_char`/`get_trigger_char` qui **renomme les triggers
  ★-tail** + le terminateur magic-key (modèle `Registry.update_trigger_char`) ;
  propager à dyn_hotstrings, au provider i18n, à l'éditeur. Rangée de menu
  `magic_key_config` (capture 1-touche, clé i18n `dialog.magic_key.*` existante).
  *Test :* changer `★`→autre chose renomme les mappings et re-résout ; le trigger
  atteint le buffer (dépend de M2.2).
  → Le dernier `\` codé en dur est parti : le fournisseur i18n répondait `\`
  alors que le manifeste, le moteur, la page d'onboarding et les deux autres
  drivers disent `★` — un menu qui documentait une touche à laquelle rien ne
  répondait, en 21 langues. La rangée `magic_key_config` n'est **pas** ajoutée :
  le manifeste la restreint à `["ahk","hs"]` avec un `reason_key` traduit, donc
  la construire violerait le manifeste au lieu de le satisfaire.
- [x] **M4.3** **Délais d'expansion** : porter le résolveur macOS
  `hotstrings_config.resolve`/`set_override` (Lua pur) avec la **précédence 5
  niveaux** (override section → override catégorie → `[_meta.section_delays]` →
  `[_meta].delay` → défaut global menu → fallback `defaults.toml` 0.75 s/2.0 s) ;
  loader fail-fast de `_shared/modules/hotstrings/defaults.toml` ; gate de délai
  par-mapping dans le moteur ; les 6 rangées `delays_colors` (fenêtre config +
  défaut global + magickey + autocorrection + llm_prediction + dynamichotstrings),
  labels « N ms / (défaut) / Infini ».
  *Test :* la précédence résout les bons délais ; override persiste et s'applique.
  → La cascade à cinq niveaux vit dans `_shared/lua/hotstrings/delay_resolver.lua`
  et **macOS y délègue** : elle était écrite deux fois et les deux copies avaient
  déjà divergé sur ce que signifie un `false` explicite. Overrides Linux
  persistés dans `~/.config/ergopti/hotstrings_overrides.toml`, mêmes noms de
  section que macOS. `defaults.toml` lu en fail-fast. Correction au plan : les
  « 6 rangées delays_colors » sont l'implémentation macOS, pas une exigence du
  manifeste — celui-ci déclare **une** rangée `action`.
- [x] **M4.4** **Sous-menus par catégorie** (l'`InitSubMenus` équivalent, ~80 % des
  rangées) : par catégorie → toggle de gate, `enable_all`/`disable_all`,
  `open_file`, puis un toggle par section (`sections_order`) avec comptes et
  coches ; grisage quand la gate parente est off ; grand total sur la rangée
  parente. Blocs perso + extensions (arbre récursif, radio section par défaut,
  close-on-add).
  *Test :* le sous-menu d'une catégorie liste ses sections avec comptes ; parité
  d'arbre vs macOS via la gate M3.6.
  → Une catégorie est un **sous-menu** : sa porte, l'ouverture de son fichier,
  tout cocher / tout décocher, puis un toggle par section avec son compte et sa
  coche, grisé quand la porte est fermée. Le nom vient de la description
  localisée du pack. L'état par section est réel et persisté sous une clé
  `catégorie.section` — désactiver puis réactiver une catégorie rend exactement
  les sections qu'on avait, pas toutes. **Le bloc extensions n'est pas fait** :
  le manifeste le restreint à `["ahk"]` avec un `reason_key`.
- [x] **M4.5** **Word expanders (terminateurs)** : brancher le catalogue partagé
  `_shared/lua/keymap/terminators.lua` (neutre, 5 fonctions) ; persistance de la
  chaîne de délimiteurs + set consommé ; rangées check-all/uncheck-all/reset,
  toggles par entrée avec suffixe « (consommé) », ajout/suppression de
  délimiteur personnalisé.
  *Test :* toggler un terminateur persiste et change le comportement de frontière.
  → Rangées tout cocher / tout décocher, suffixe « (consommé) », suppression des
  délimiteurs personnalisés, et surtout **persistance** : le catalogue partagé ne
  garde l'état qu'en mémoire, donc chaque délimiteur désactivé revenait au
  démarrage suivant — alors que la fonctionnalité existe précisément pour dire
  « n'étends que sur ★ ».
- [x] **M4.6** **Config window partagée** : le bridge Linux
  `hotstrings_config_bridge` doit gérer les payloads délai/couleur/`show_tooltip`
  (aujourd'hui seulement toggle/reload/add/delete) pour que la fenêtre WebView
  partagée (déjà enregistrée) édite les délais/couleurs sur Linux comme ailleurs.
  *Test :* un patch de délai depuis la fenêtre atteint le résolveur.
  → Le bridge répondait à 4 des 11 actions de la fenêtre partagée : tous les
  champs de délai, pastilles de couleur et interrupteurs d'aperçu étaient inertes
  ici. Deux coercitions portent le poids : `section: ''` est la façon dont la
  fenêtre dit « la catégorie elle-même » (le passer tel quel écrit un override
  sous une section qui n'existe pas, qui ne se résout jamais), et la chaîne
  `"false"` est **vraie** en Lua — la laisser passer rallumerait l'aperçu que
  l'utilisateur vient d'éteindre.
- [x] **M4.7** **Manifeste features** : `linux/_generated/features_manifest.lua` a
  **zéro** entrée hotstrings (car `manifest.toml` met `trigger_char`/
  `expansion_delay` en `platforms={ahk,hs}`). Ajouter `linux` pour que
  `Manifest.default_for` fonctionne.
  *Test :* `default_for("hotstrings.trigger_char")` résout `★` sur Linux.

### M4T — Tooltip de prévisualisation, style **identique** aux deux drivers

Le style est **déjà** un SSOT partagé ; l'algo est un oracle JS. Le manque est le
pipeline Linux + un renderer natif.

  → **Obsolète.** Le manifeste porte déjà le token `linux` et
  `default_for("hotstrings.trigger_char")` résout `★` — vérifié. Le travail
  successeur (consommer les 73 fonctionnalités hotstrings déclarées par section)
  est couvert par M4.4.
- [x] **M4T.1** **Loader fail-fast** de `_shared/modules/tooltip/constants.toml`
  (jumeau Lua de `config.lua`/`ui_style.ahk`) → tables de style natives. Ajouter
  les clés `*_linux` manquantes (police, tailles, `window_bottom_inset` — ou
  réutiliser `*_hs`). **Suivre le TOML, pas SPEC.md** (qui a dérivé).
  *Test :* boot échoue sur clé manquante ; valeurs = pad 14/7, rayon 7, #242424…
  → `linux/ui/tooltip/config.lua`, fail-fast, jumeau du macOS et du
  `ui_style.ahk`. Les 9 clés `*_linux` manquantes sont ajoutées, chacune avec la
  raison de sa différence. **La dérive SPEC.md est confirmée et documentée** :
  SPEC.md range `screen_margin` sous `[positioning]`, le TOML sous `[layout]` —
  c'est le TOML que lisent les trois drivers.
- [x] **M4T.2** **Renderer natif** sur `graphics_renderer.lua` (lgi GTK POPUP +
  cairo, click-through déjà là) : mesure de texte Pango, rect arrondi (rayon 7,
  bord blanc α≈0.13), remplissages par-rangée, labels trigger à droite, dimming +
  barré. **Remplace** `tooltip_renderer.lua` (yad/zenity, zéro appelant, jamais au
  style). Porter tint/layout/dequeue de l'oracle JS vers `_shared/lua/tooltip/*`
  (partagé avec macOS, épinglé par les vecteurs JS).
  *Test :* conformité aux vecteurs JS (tint HSL L=0.13/S=0.85, géométrie, dequeue).
  → **Prémisses du plan inversées** : `graphics_renderer.lua` et
  `tooltip_renderer.lua` avaient été supprimés le 2026-08-02, donc « construire
  sur graphics_renderer (click-through déjà là) » partait de rien, et
  « remplace tooltip_renderer » était déjà acquis par suppression.
  → tint et layout montent dans `_shared/lua/tooltip/*` et **macOS y délègue**.
  La copie Lua du layout était en ligne dans le chemin de rendu macOS, donc le
  test de corpus qui prétendait attraper « toute divergence de clamping »
  rejouait un **clone** défini dans le fichier de test. Le corpus est maintenant
  rejoué côté Linux contre le module partagé (6 vecteurs), et un vrai défaut en
  est sorti : le layout entrait dans sa branche ancrée sur une valeur *truthy*,
  or un décodeur JSON représente `null` par une sentinelle.
- [x] **M4T.3** **Pipeline d'aperçu** : équivalent `update_preview`/`_LookupAndRender`
  (collecte des candidats, ordre par tiebreak moteur, dimming, résolution
  `show_tooltip`/couleur/délai par catégorie) alimentant le renderer ; les 4
  toggles d'aperçu (★/autocorrection/IA/colorés) dans le tray ; dismiss sur
  frappe (le hook evdev est déjà à nous) / clic.
  *Test :* un trigger affiche l'aperçu au bon style ; les toggles le gatent.
  → Les quatre bascules ont gagné leur token `linux` dans `manifest.toml` —
  **blocage silencieux que le plan ne mentionne pas** : elles étaient
  `platforms = ["hs"]`, donc aucun travail de rendu ne les aurait fait
  apparaître. Le pipeline construit les rangées (candidat qui ne se déclenchera
  pas → grisé, refusé par le moteur → barré : les cacher supprimerait la réponse
  à « pourquoi rien ne s'est passé »), et l'aperçu est masqué à la frappe et au
  clic.
- [x] **M4T.4** **Ancrage** : cascade caret → AT-SPI2 → cadre fenêtre → bas d'écran,
  clampée à la marge 5. ⚠ Sous Wayland `gtk_window_move` est un no-op → gtk-layer-shell
  (KDE/wlroots ; **pas** GNOME) sinon les échelons bas de la cascade en
  first-class. Choisir `window_bottom_inset_linux`.
  *Test :* [MATÉRIEL] position correcte sous X11 ; fallback bas-d'écran sous GNOME
  Wayland.

### M5 — Packaging + universalité distro + bascule de session (C2, C3)

  → Cascade avec ses échelons **honnêtes** : AT-SPI2 est sondé mais pas
  garanti (désactivé par défaut sur plusieurs bureaux), le cadre de la fenêtre
  active est **X11 seulement** — un compositeur Wayland n'expose pas la géométrie
  d'une fenêtre à un autre process, par conception — puis le bas de l'écran.
  Pas de gtk-layer-shell : il ne couvre pas GNOME, donc il ajouterait une
  dépendance pour la moitié des bureaux. Le clamp à la marge 5 vient du module
  partagé.
- [x] **M5.1** **Une** unité systemd `--user` : `PartOf=graphical-session.target`
  + `WantedBy=graphical-session.target`, **zéro** ligne `Environment=DISPLAY`
  (le daemon sonde le serveur à l'exécution). C'est la seule forme d'unité
  compatible avec « logout X11 → login Wayland untouched ».
  *Test :* `test-linux-package-layout` étendu — toutes les unités rendues
  identiques, cible `graphical-session`, pas de DISPLAY codé en dur.
  → **Six** définitions dans **cinq** fichiers, en désaccord sur trois choses à
  la fois : le nom de l'unité, l'ExecStart et le WantedBy. Un utilisateur qui
  installait le .deb puis lançait `install.sh` se retrouvait avec **deux** unités
  activées, toutes deux à grabber le clavier. Un seul nom désormais, `install.sh`
  copie l'unité du dépôt au lieu de la redéclarer, `PartOf=graphical-session`
  ajouté, `Environment=DISPLAY` supprimé partout, et la gate échoue sur un second
  nom.
- [x] **M5.2** **Setup des prérequis** (`install.sh` + `--setup-perms`) : règle
  udev uinput (`static_node`), groupe `input` (lecture) + groupe `uinput`
  (écriture) — **pas** `uaccess`, `modprobe uinput` via `modules-load.d`, choix
  ydotoold **ou** (préféré) écriture uinput directe qui l'élimine. Le daemon
  échoue **franchement** au boot (notifier) si un prérequis manque, message
  français.
  *Test :* [MATÉRIEL] boot sans permission → erreur claire, pas de WARN avalé.
  → `--setup-perms`, exécuté aussi lors d'une installation normale : un
  installeur qui laisse le driver incapable de lire le clavier n'a rien installé,
  et l'échec est silencieux. Groupe `uinput` créé, `input`+`uinput` ajoutés,
  règle udev **avec `static_node`** (sans quoi elle ne matche rien au premier
  démarrage), `modules-load.d`. `uaccess` écarté, avertissement de sécurité
  affiché en clair. Le daemon échoue franchement au boot si /dev/uinput est
  inaccessible.
- [x] **M5.3** **Distros non-apt/dnf/pacman et non-systemd** : garder chaque
  `systemctl` derrière `command -v systemctl`, fallback autostart XDG
  (`~/.config/autostart`) ; ajouter apk/zypper/xbps ou un chemin `--no-deps`
  documenté ; **flake NixOS** (`nixosModules`+`homeManagerModules`). Installer dans
  `~/.local` (compatible immuables ; règle udev + `modules-load.d` dans `/etc`
  writable via un `sudo`). Sélectionner le binaire kanata par `uname` (musl/arm64)
  avec sha256 épinglé.
  *Test :* CI containers debian/fedora/arch/**alpine** exécutant
  `install.sh --no-service` + boot avec périphériques stubés.
  → `apk`, `zypper`, `xbps` ajoutés ; un gestionnaire inconnu **n'abandonne
  plus** (il affichait la liste des paquets puis rendait la machine
  installable-nulle-part) ; `--no-deps` ; `systemctl` derrière `command -v` ;
  entrée autostart XDG écrite inconditionnellement ; flake NixOS avec
  `nixosModules` (groupe, règle udev, module) et `homeManagerModules` (daemon,
  unité utilisateur) ; kanata choisi par `uname`.
- [x] **M5.4** **Assets de release complets** : tarball de `linux/` + `_shared/`
  (aujourd'hui la release ne permet pas d'installer). Corriger le typo wrapper
  `shared/`→`_shared/` et le PKGBUILD (LUA_PATH, `lib/`, `_shared/{data,modules}`).
  *Test :* gate layout couvrant PKGBUILD ; smoke-boot depuis les assets de release.
  → La release publiait `install.sh`, le wrapper et **un** fichier Lua : de quoi
  installer rien. Elle publie une tarball portant le driver et l'arbre partagé
  dans la disposition que le daemon attend. Le PKGBUILD produisait un **paquet
  vide** — ses cinq `cp` lisaient `build/linux/` alors que le builder écrit dans
  `build/linux/linux/`, et chacun finissait par `|| true`. Rien ne l'attrapait :
  la gate ne couvrait que les deux packagers `.sh`, et `test-packaging-paths`
  filtre `tools/build` sur `.sh`, ce que `PKGBUILD` n'est pas.
- [x] **M5.5** **[MATÉRIEL] Smoke-test du build LuaJIT statique-musl** (si on
  distribue un LuaJIT) : vérifier que le JIT alloue (pas seulement « compile ») ;
  documenter le fallback `-joff` interpréteur.

### M6 — Tests, CI, robustesse

  → **Obsolète, à rayer.** La décision 4 du §6 (LuaJIT du système, rien de
  vendorisé) a tué la prémisse : `vendor/` ne contient qu'un README et un script
  de fetch.
- [x] **M6.1** **Harnais faux-périphérique uinput** (le manque central) : créer un
  uinput de test, écrire des événements, asserter le chemin décode/grab/replay —
  transforme le décodeur mort en couverture réelle et donne au bug d'intercalage
  un vrai test de régression.
  → `tests/hardware/run_uinput_roundtrip.lua`, exécuté en CI dans le job Linux
  existant (une **étape**, pas un job : en job il coûtait un runner complet pour
  cinq secondes de travail). Il crée un vrai clavier virtuel, attend le nœud que
  le noyau publie, l'ouvre non bloquant, prend `EVIOCGRAB`, écrit une pression,
  une répétition et un relâchement, et les relit. Il asserte aussi les deux
  choses qu'un mock ne peut pas montrer : un descripteur au repos rend `nil` au
  lieu de bloquer, et le nœud disparaît après `UI_DEV_DESTROY`.
- [x] **M6.2** Faire de **luv** (ou la boucle poll FFI) une dépendance dure du
  daemon et l'installer en CI, pour que la boucle d'événements de prod,
  `luv.sleep` et les watchers inotify cessent de ship non testés. Garder toute
  op bit-à-bit et retour `os.execute` **LuaJIT-5.1-safe**.
  → **La question est tranchée dans l'autre sens** : c'est le **FFI** qui est la
  dépendance dure, et il l'était déjà — uinput, evdev et le grab en dépendent
  tous. `luv` reste optionnel et préféré quand il est là. Ce qui manquait, c'est
  que le repli sans luv forkait `/bin/sleep` **une fois par itération de boucle**,
  soit mille fois par seconde sur un daemon au repos ; il passe par `nanosleep`
  en FFI, comme la pause inter-phase de l'injecteur. Les opérations bit-à-bit
  restent écrites arithmétiquement (LuaJIT est 5.1) et les retours `os.execute`
  acceptent les deux conventions.
- [x] **M6.3** **Couverture de parse** de l'entry point Linux (aujourd'hui zéro) ;
  lint conventions Lua étendu à Linux + `_shared/lua` ; router les shell-outs du
  chemin frappe via `shell_runner`.
  → La couverture de parse existait déjà et couvre l'entry point ; elle est
  étendue à `tests/hardware/`, le seul arbre Lua que le runner ne charge jamais.
  Le lint de conventions couvre désormais `linux/platform` et `macos/platform`,
  qui contenaient du Lua qu'aucune vérification n'avait jamais lu. Les shell-outs
  du chemin de frappe sont partis autrement que prévu : l'injecteur et le hook
  n'en font **plus aucun** (uinput direct), et `window_info` et le loader passent
  par `shell_runner`.
- [x] **M6.4** Corriger le **contrat corpus** avant de générer le matcher partagé
  (risque R6 de `TODO.md`) : `backspace_count` = 3 sous Windows/Linux, 1 sous
  macOS. Puis fermer les divergences moteur du bug 12 (non-`auto_expand`, casse,
  priorité, touche magique `\` vs `★`).

---

## 6. Décisions techniques (tranchées le 2026-07-31)

Les cinq arbitrages ont été tranchés avec le mainteneur. Ils sont **fermés** — ne
pas les rouvrir sans raison nouvelle.

1. **Injection → FFI uinput direct.** Écriture dans `/dev/uinput` via FFI LuaJIT,
   `ydotool` supprimé du chemin frappe. Élimine ydotoold root, le flag invalide,
   le fork-par-événement, et **permet le grab** qui corrige la corruption C4. Coût
   accepté : ~200 l de FFI + mapping caractère→keycode à notre charge (via M2).

2. **Transport SNI → libayatana si présente, sinon sidecar `ksni` (Rust).**
   In-process quand `libayatana-appindicator` est là, sinon un petit binaire Rust
   autonome piloté par le daemon. `snixembed` pour les WM XEmbed, extension
   AppIndicator documentée pour GNOME. **Jamais** de dbusmenu en gdbus one-shot
   (cause du tray cassé actuel).

3. **Permissions → groupes `input` (lecture) + `uinput` (écriture).** Ce que font
   kanata/keyd/xremap. Règle udev `static_node` pour `/dev/uinput`,
   `modules-load.d` pour le module. ⚠ `uaccess` sur `/dev/input` **écarté**
   (déconseillé par systemd = keylogging). Avertissement de sécurité franc dans
   l'onboarding (« être dans `input` = clavier lisible globalement »).

4. **LuaJIT → celui du système.** Présent partout (Alpine/musl inclus), pas de
   skew glibc, pas de piège d'allocation JIT du build statique-musl. Déclaré comme
   dépendance de paquet. Vendored seulement si un besoin futur le force.

5. **Séquencement → livrable ASCII de bout en bout après M0+M1**, avant le
   multilingue complet (M2), pour valider vite la capture réelle + l'injection sur
   du vrai matériel. Puis M2 (layout/accents), puis M3/M4 (menu + parité).

---

## 7. Risques

- **R-A** — le grab sans ré-émission fiable **tue le clavier**. Mitigation :
  ungrab-on-panic, watchdog, garder observe-mode en fallback gaté par flag
  jusqu'à validation [MATÉRIEL].
- **R-B** — bascule X11⇄Wayland non testée en CI. Mitigation : unité
  `graphical-session.target` + re-sonde runtime ; test manuel documenté.
- **R-C** — build statique-musl JIT casse silencieusement (piège documenté).
  Mitigation : smoke-test JIT explicite M4.5, fallback `-joff`.
- **R-D** — app-id Wayland non universel → règles par-app dégradées. Mitigation :
  scoper/documenter, ne pas promettre les règles par-app sous Wayland.
- **R-E** — GNOME sans SNI natif → pas de tray par défaut. Mitigation : documenter
  l'extension AppIndicator, prévoir une entrée alternative (CLI/desktop file).
- **R-F** — le corpus hotstrings rejette une implémentation correcte
  (`backspace_count`, R6 de `TODO.md`). Mitigation : corriger le contrat **avant**
  de générer le matcher (M5.4).

---

## 8. Articulation avec `TODO.md` (programme de simplification)

Un agent implémente en parallèle le programme de simplification (`TODO.md`,
Lots 2-10, plusieurs jours). **Ce plan ne crée pas une voie parallèle.** Une
grande partie du travail *menu / partage / gates* de Linux **est déjà dans le
programme** et y cite Linux explicitement ; seul le **cœur moteur** (capture/
injection/layout) et le *packaging* sont du neuf spécifique à Linux.

### 8.1 Carte de recouvrement — qui fait quoi

| Item du plan Linux | Couvert par | Statut |
| --- | --- | --- |
| M3.2/M3.3 renderer partagé + host Linux, suppr. `menu_builder.lua` | **Lot 5.3** (nomme Linux mot pour mot) | ✅ dans le programme |
| M3.4 / M4.7 `linux` dans `KNOWN_PLATFORMS` + manifeste + `features_manifest` | **Lot 4** | ✅ dans le programme |
| M3.6 gate `test-menu-parity` (3 drivers) | **Lot 5 / I3** | ✅ dans le programme |
| §9 mutualisation + single-source gates étendues à Linux | **Lots 4/5/7 + 0.7** | ✅ dans le programme |
| M4.3 résolveur de délais partagé | **Lot 8** (une impl. + corpus) | ✅ dans le programme |
| M4T.1 oracle tooltip / vecteurs | **Lot 8.8** | ✅ dans le programme |
| M6.4 divergences moteur (`\`→`★`, non-`auto_expand`, priorité, contrat corpus) | **Lot 8.1/8.4** | ✅ dans le programme |
| M7.1 résolveurs de chemins Linux | **Lot 7.1** | ✅ dans le programme |
| **M0** coordination kanata | — | ⛔ Linux-only, phase Linux |
| **M1** FFI evdev/uinput + grab | — | ⛔ Linux-only, **matériel** |
| **M2** layout XKB + presse-papiers + détection serveur | — | ⛔ Linux-only, **matériel** |
| **M4** câblage des features hotstrings (trigger/délais/word-expanders UI) | dépend de M1/M2 | ⛔ phase Linux |
| **M4T.2-.4** renderer tooltip GTK/cairo + ancrage | — | ⛔ Linux-only, **matériel** |
| **M5** packaging / systemd / distros | — | ⛔ Linux-only |

### 8.2 Recommandation de séquencement

**Ne pas arrêter l'agent.** Les items ✅ ci-dessus sont déjà planifiés dans le
programme ; les avancer maintenant ne ferait qu'exécuter en désordre les lots
Linux-facing du programme. Et le vrai bloquant d'un hotstrings Linux fonctionnel
— le cœur moteur (M0-M2) — est **spécifique à Linux et se valide sur matériel**,
donc il ne peut pas être fait « en même temps » utilement depuis le checkout
Windows courant.

**La seule chose à garantir** : que l'agent exécute les Lots 4/5/7/8 en traitant
Linux comme **plateforme de premier rang** (renderer + gate de parité + `KNOWN_
PLATFORMS` + `features_manifest` pour **trois** drivers, et fermer les divergences
moteur Linux `\`→`★` / non-`auto_expand`). `TODO.md` le prescrit déjà (Lot 5.3
nomme Linux) — cette carte rend le lien explicite pour qu'aucun travail ne soit
fait deux fois.

**Ordre cible** : (1) l'agent finit le programme de simplification → il pré-bâtit
la fondation menu/partage/gates de Linux ; (2) **phase Linux** = M0 → M1 → M2
(cœur moteur, sur matériel) → M4 (câblage des features sur la fondation déjà
posée) → M4T.2-.4 (tooltip) → M5 (packaging). C'est le sens du séquencement
ASCII-first du §6.5.

Ce fichier (`todo_linux.md`) est séparé de `TODO.md` (édité en parallèle) pour
éviter les conflits ; réconciliés au merge.


---


## 9. Mutualisation cross-driver (axe transverse — checklist)

Objectif : mettre un **maximum dans `_shared` et certifier** que chaque OS rend la
même chose, *modulo* des différences déclarées. Rationnel complet en §3.8.

**À déplacer vers `_shared` (donnée + code Lua) :**

  → **Première moitié à rayer** : `backspace_count = 3` est correct sur les trois
  drivers — c'est un compte **logique**, le 2 physique de macOS est une
  optimisation de préfixe, et une gate le dit désormais en clair. Les divergences
  moteur du bug 12 sont fermées : `auto_expand` est lu (commit antérieur),
  la touche magique est `★` partout, et la priorité de collision est résolue par
  le loader depuis `priority.json`.
- [ ] **Renderer de menu** `_shared/lua/menu/render.lua` partagé **macOS + Linux**
  (AHK garde `MenuRenderer_Build`, tenu identique par la gate). Cf. M3.2.
- [ ] **Manifeste = seule source de structure** : y remonter les rangées codées en
  dur via les 14 capacités du Lot 5. Cf. M3.4.
- [x] **Résolveur de délais** : porter le macOS `hotstrings_config.lua` (Lua pur)
  en module partageable ; à terme **une** implémentation (I5), AHK = jumeau
  épinglé par un corpus de vecteurs. Cf. M4.3.
  → Fait : `_shared/lua/hotstrings/delay_resolver.lua`, macOS y délègue, chaque
  mutation d'ordre passe au rouge **sur les deux drivers**.
- [x] **Algos de tooltip** (tint/layout/dequeue) : de l'**oracle JS** vers
  `_shared/lua/tooltip/*`, consommé par macOS + Linux, épinglé par les vecteurs.
  Cf. M4T.2.
  → tint et layout faits et partagés ; **dequeue non porté** : il n'a pas de
  consommateur Linux tant que l'aperçu LLM n'existe pas ici, et un module
  partagé qu'un seul driver appelle n'est pas de la mutualisation.
- [x] **Catalogue Terminators** : déjà neutre
  (`_shared/lua/keymap/terminators.lua`) — juste le brancher côté Linux. Cf. M4.5.
  → Branché, avec les rangées en masse, le suffixe « (consommé) » et la
  persistance qui manquait au catalogue partagé.
- [x] **Style tooltip** : déjà SSOT (`constants.toml`) — ajouter les clés `*_linux`.

**Les gates qui *certifient* la parité (sans elles, « pareil » est un vœu) :**

  → Les 9 clés ajoutées, chacune avec la raison de sa différence.
- [ ] `test-menu-parity.cjs` (I3) — rend les 3 plateformes, diffe les arbres de
  labels, rouge si divergence non déclarée. Cf. M3.6.
- [x] Ratchet **« aucune rangée de menu hors du renderer »** (baseline 265 AHK +
  399 macOS + 101 Linux).
  → **Déjà en place** avant cette session : `test-menu-rows-outside-renderer.cjs`,
  baselines mesurées à 220 AHK / 301 macOS / 3 Linux, **zéro marge**. Attention :
  la gate désigne `linux/ui/menu/menu_builder.lua` comme « le renderer Linux », donc
  supprimer ce fichier (M3.3) casse la gate — elle doit être repointée dans le
  même changement.
- [x] Bijection `action_id ↔ handler` dans les deux sens, par driver.
  → **Déjà en place** : `test-menu-action-handler-bijection.cjs`, baselines
  `{ahk:0, hs:5, linux:0}`, à la limite.
- [x] « Toute clé-tableau du manifeste a un lecteur ».
  → **Déjà en place** : `test-menu-manifest-keys-have-readers.cjs`.
- [x] Étendre les single-source gates existantes à Linux
  (`test-linux-llm-defaults`, `test-updater-constants`,
  `test-menu-labels-single-source`, `test-priority-parity`).

**Le « modulo OS » = donnée, pas code** : `platforms:["windows","macos","linux"]`
par entrée + `visible_when`/`disabled_when` + `reason_key` (rangée grisée +
tooltip = Convention S). Toute différence entre OS devient auditable parce que
déclarée.


---


## 10. Validation sur matériel réel (aucune n'est couverte par le CI)

> **Procédure écrite** : `static/ergopti_plus/linux/HARDWARE.md` — chaque point
> ci-dessous y a sa commande et la réponse attendue, dans un ordre où un échec
> précoce rend les suivants ininterprétables. Une chose *est* désormais couverte
> par le CI : `tests/hardware/run_uinput_roundtrip.lua` crée un vrai clavier
> virtuel, le grab, écrit et relit — ce qui épingle les numéros d'ioctl, la
> disposition du struct et les bits de capacité. Il tourne sans écran, donc il ne
> dit rien d'un serveur d'affichage, d'un compositeur, d'un panneau ni d'une
> disposition clavier.

  → `test-linux-package-layout` étendu (unité unique, PartOf, pas de DISPLAY,
  PKGBUILD, assets de release), `test-kanata-defalias-parity` étendu (coordination
  des périphériques), `test-tooltip-positioning-reach` mis à jour (Linux lit
  désormais toute la canon de positionnement), `test-port-adapter-matrix` et
  `test-driver-scoped-features-stay-scoped` mis à jour.
> **Ces sept points ne peuvent pas être cochés depuis ce dépôt.** Ils exigent une
> machine Linux avec un serveur d'affichage, un panneau et une vraie disposition
> clavier ; ce checkout est sous Windows. Les cocher serait mentir.
>
> Ce qui *était* livrable d'ici l'est : **`tests/hardware/validate.sh`** répond à
> tout ce qu'une machine peut répondre — permissions, groupes, `/dev/uinput`,
> serveur d'affichage, dump de keymap et son compte de touches, outils de
> presse-papiers, nombre d'unités systemd installées, présence d'un hôte
> StatusNotifierItem — puis pose une à une les douze questions qui demandent
> vraiment des yeux, et écrit **un seul rapport** couvrant les deux moitiés.
> Vérifié : il échoue proprement hors Linux au lieu de faire semblant.
>
> Le reste est une liste que personne ne rejoue, donc qui cesse d'être vraie sans
> que personne le remarque — c'est précisément pourquoi la moitié mécanisable est
> devenue un script. Sur la machine cible :
>
> ```bash
> bash static/ergopti_plus/linux/tests/hardware/validate.sh
> ```

- [ ] Frappe normale capturée sous X11 **et** sous Wayland (post-grab kanata).
- [ ] Expansion accentuée (`NT’ ➜ N’T`, phrase FR) correcte sur les deux serveurs.
- [ ] Frappe rapide pendant expansion → pas de corruption (C4).
- [ ] Bascule logout-X11 → login-Wayland sans reconfiguration (C2).
- [ ] Icône tray + sous-menu Hotstrings fonctionnels (KDE, GNOME+extension, sway).
- [ ] Trigger `★` changeable ; délais réglables ; tooltip au bon style.
- [ ] Install testée par distro-famille (Ubuntu, Fedora, Arch, Alpine, +1 immuable).
