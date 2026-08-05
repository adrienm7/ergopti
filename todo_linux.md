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

## 3. Le paysage technique (ce que la recherche a établi)

> Sources primaires citées dans `docs/research/` (dump des 7 agents). Toute
> affirmation runtime est à **revalider sur matériel réel** — c'est la discipline
> du driver Linux (le CI ne teste rien de tout ça).

### 3.1 Capture + injection : evdev + uinput est la **seule** voie universelle

- **Aucun mécanisme Wayland unique ne couvre tous les compositeurs en 2026.**
- **evdev+uinput est agnostique au serveur d'affichage** parce qu'il est au
- **Bindings LuaJIT-FFI existants** pour ne pas tout réécrire :

### 3.2 Le grab (EVIOCGRAB) est ce qui corrige la corruption à la racine

Les observateurs sans grab (espanso) *documentent notre bug* : désync de
modificateurs et intercalage sur frappe rapide (espanso issues #588, #914,
#1507, #1575). Les daemons qui **grab + ré-émettent** (keyd, kanata, kmonad,
xremap) possèdent l'ordre des événements et peuvent **mettre en file** les
touches tapées pendant l'expansion. `EVIOCGRAB` + ré-émission via notre propre
uinput est le **seul** design qui corrige C4.

### 3.3 Coordination kanata : chaîner, pas rivaliser

- Le périphérique de sortie de kanata s'appelle **exactement `kanata`** (défaut
- **Fix :** générer le defcfg kanata avec
- **kanata ne peut pas remplacer notre moteur** : `defseq` exige une touche

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
2. **Petit sidecar** contre une implémentation prête : crate Rust **`ksni`** (SNI +
3. `yad --notification` **uniquement** en fallback X11-XEmbed (invisible sur GNOME
Pour les WM sans hôte SNI (dwm/i3/vieux XFCE) : proxy **`snixembed`** (SNI→XEmbed).
espanso **n'a aucun tray Linux** à copier (son search-bar est indisponible sous
Linux) ; ksni est ce qu'utilisent les daemons Rust/Go qui affichent un tray.

### 3.7 Permissions et universalité distro

- **Accès `/dev/input` (lecture)** : groupe `input` (défaut des distros), mais
- **Accès `/dev/uinput` (écriture)** : règle udev
- **Piège LuaJIT statique-musl** *(mesuré, classe de bug documentée)* : le JIT
- **glibc version skew** : un binaire lié dynamiquement contre une glibc récente
- **Non-systemd** : pas de réponse portable unique — systemd `--user` en primaire
- **NixOS** : un script qui hardcode `/usr`/`#!/bin/bash` ne tourne pas. Livrer un
- **Immuables** (Silverblue/Kinoite/SteamOS/MicroOS) : `/usr` en lecture seule →
- **Flatpak/Snap** : un daemon qui a besoin de `/dev/uinput` **ne peut pas** être

### 3.8 Le menu n'est partagé qu'à ~20 % aujourd'hui — mutualiser au maximum

C'est le constat unanime des 4 agents de cartographie de parité, et c'est
l'occasion de faire mieux. « Le menu est partagé » n'est vrai qu'à moitié :

- `menu_manifest.json` décrit la **structure de premier niveau** (ordre des
- **macOS ne lit même pas le manifeste** : son sous-menu hotstrings est
- **~80 % des rangées visibles** (les sous-menus par catégorie, les toggles par
- **Les deux drivers matures divergent déjà** : macOS a 4 toggles d'aperçu (bulle

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
- bijection `action_id ↔ handler` dans les deux sens (toute action du manifeste
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

- [ ] **M3.3 — supprimer `linux/ui/menu/menu_builder.lua`** au profit du renderer
      partagé. Contrainte d'ordre ci-dessus : deux ratchets désignent ce fichier
      par son nom et doivent être repointés dans le même changement.
      → **Mesuré le 2026-08-05** (`--measure`) : le fichier contient **134 sites de
        rangée**. Les supprimer signifie migrer 134 rangées en entrées manifeste de
        type `list`/`action`/`group` avec leurs fournisseurs — et l en-tête du
        ratchet le dit : router par `ManifestMenu.build` ne fait **pas** baisser le
        compte, seule une migration `list` l a jamais fait.
      → **Cet item demande à Linux d aller plus loin que les deux autres pilotes.**
        macOS a 301 rangées hors renderer, Windows 220 ; ni l un ni l autre n a
        fait cette migration, et le ratchet existe précisément parce que
        « l interdire aujourd hui voudrait dire réécrire deux couches de menu d un
        coup ». Formulé comme « supprimer le fichier », M3.3 vise un état qu aucun
        pilote de référence n a atteint.
      → **Décision à prendre avant de commencer.** Aujourd hui le ratchet déclare
        `menu_builder.lua` « le renderer Linux », donc les 134 rangées comptent
        comme *dedans* et Linux affiche 2/2 : il n existe aucune pression chiffrée
        vers la migration. Le premier pas honnête est de repointer le ratchet pour
        qu il mesure la vraie dette — ce qui fait passer Linux de 2 à 134 et
        ressemble à une régression alors que c est un changement de définition.
        C est un arbitrage du mainteneur sur ce que le nombre veut dire, pas une
        décision à prendre en passant.
- [x] **M3.4 — fait** le 2026-08-05. `_build_shortcuts` passe par
      `ManifestMenu.build("shortcuts_menu", …)` et `extensions_shortcuts` a perdu
      sa restriction `["ahk"]`. Détails dans l item de §11.3.
- [x] **M3.6 — certifié** le 2026-08-05 pour Linux, au **runtime**.
      → Les portes de `tools/test` lisent le manifeste et la **source**. Elles
        attrapent une ligne promise qu aucun handler ne répond, et un pilote qui
        construit des lignes qu aucun manifeste ne décrit. Aucune ne voit le
        troisième cas : un handler qui existe, est enregistré, est atteint — et
        n ajoute rien, parce qu une garde au-dessus est sortie tôt ou qu une clé de
        contexte était mal orthographiée. Cette ligne est déclarée, gérée,
        invisible, et tout reste vert. C est arrivé deux fois (les onze lignes de
        gestes, la catégorie dynamique grisée).
      → `linux/tests/unit/meta/test_menu_matches_manifest.lua` construit le plateau
        entier avec le builder du démon et vérifie chaque `action`, `group` et
        `section_header` que le manifeste promet à `linux`. Il tourne dans la suite
        du pilote, donc sur un vrai Linux en CI et sur le LuaJIT de chaque distro.
        Vérifié rouge : neutraliser le rendu manifeste des hotstrings nomme les six
        lignes disparues.
      → Il couvre aussi « aucun sous-menu vide » : un sous-menu qui s ouvre sur rien
        est pire qu absent, l utilisateur ne peut pas le distinguer d une
        fonctionnalité qui a échoué à charger.
      → **Hors périmètre, assumé** : les lignes `dynamic`, `feature` et `toggle`,
        dont le libellé appartient au handler ou à l appelant — le ratchet de
        bijection pose sur elles la question plus étroite « un handler est-il
        enregistré ». Et les 39 lignes cachées sans `reason_key` : ce compteur est
        une dette gelée par son propre ratchet, pas une certification.


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

## 10. Validation sur matériel réel

> **Procédure écrite** : `static/ergopti_plus/linux/HARDWARE.md` — chaque point
> ci-dessous y a sa commande et la réponse attendue, dans un ordre où un échec
> précoce rend les suivants ininterprétables. Une chose *est* désormais couverte
> par le CI : `tests/hardware/run_uinput_roundtrip.lua` crée un vrai clavier
> virtuel, le grab, écrit et relit — ce qui épingle les numéros d'ioctl, la
> disposition du struct et les bits de capacité. Il tourne sans écran, donc il ne
> dit rien d'un serveur d'affichage, d'un compositeur, d'un panneau ni d'une
> disposition clavier.

> **Ces sept points ne peuvent pas être cochés depuis ce dépôt.** Ils exigent une
> machine Linux avec un serveur d'affichage, un panneau et une vraie disposition
> clavier ; ce checkout est sous Windows. Les cocher serait mentir.
>
> Ce qui *était* livrable d'ici l'est, et il y en avait plus que « une checklist
> en prose ». Deux de ces sept points avaient un **cœur mécanisable qui n'avait
> jamais été écrit** :
>
> - **`tests/hardware/run_grab_race.lua`** — la propriété qui donne son nom au
>   jalon (`"abcd"` → `"acd"`, §4 de HARDWARE.md) n'était vérifiée **que par
>   lecture**. Un backend enregistré peut affirmer l'ordre que notre code
>   *entend*, et il est structurellement incapable d'affirmer que le noyau est
>   d'accord ; un grab en particulier est invisible pour un mock — un `ioctl` qui
>   retourne 0 à un enregistreur ne dit rien de si le bureau voit encore le
>   périphérique. Ce harnais crée un vrai clavier, prend le grab, écrit une rafale
>   **entrelacée** (effacements synthétiques + frappes utilisateur au milieu) et
>   vérifie qu'elle revient entière et dans l'ordre.
> - **`tests/hardware/run_layout_resolution.lua`** — chaque test unitaire de
>   `keyboard_layout` analysait une keymap **que ce dépôt a écrite**, c'est-à-dire
>   testait l'analyseur contre les hypothèses de son auteur. Celui-ci compile les
>   vraies dispositions système (`fr`, `es`, `us`, `de`) et vérifie que chacune
>   tape ses propres accents **et refuse ceux des autres, en entier**. Et il ne
>   demande **aucun serveur d'affichage** : `xkbcli compile-keymap` produit le
>   même texte qu'un dump de session — la session décide *quelle* disposition est
>   active, pas ce qu'une disposition contient. C'est ce qui le rend exécutable en
>   CI, et c'est le cas « pack espagnol sur clavier français » vérifié pour de bon.
>
> Les deux sont câblés dans le job `test-linux` existant **en étapes, pas en jobs**
> (les minutes GitHub Actions sont à 95 %), et appelés par `validate.sh`.
>
> **`tests/hardware/validate.sh`** répond en plus à tout ce qu'une machine peut
> répondre — permissions, groupes, `/dev/uinput`, serveur d'affichage, dump de
> keymap et son compte de touches, outils de presse-papiers, nombre d'unités
> systemd installées, présence d'un hôte StatusNotifierItem — puis pose une à une
> les questions qui demandent vraiment des yeux, et écrit **un seul rapport**
> couvrant les deux moitiés. Vérifié : les trois harnais sortent en **2**
> (« cette machine ne peut pas héberger ce test ») hors Linux, distinct d'un
> échec — sinon un runner mal configuré se lirait comme un driver cassé.
>
> Le reste est une liste que personne ne rejoue, donc qui cesse d'être vraie sans
> que personne le remarque — c'est précisément pourquoi la moitié mécanisable est
> devenue un script. Sur la machine cible :
>
> ```bash
> bash static/ergopti_plus/linux/tests/hardware/validate.sh
> ```

> **Vérifié sur un vrai noyau Linux le 2026-08-05** (CI dispatché sur branche,
> donc `event_name != 'push'` et la chaîne de release ne peut pas partir) :
>
> - `run_uinput_roundtrip` : **11/11**. Les numéros d'ioctl, la taille du struct,
>   les offsets et les bits de capacité sont exécutés, plus seulement lus.
> - `run_grab_race` : **12/12**. La propriété C4 — la corruption qui donne son nom
>   au jalon — est prouvée : rafale entrelacée (effacements synthétiques + frappe
>   utilisateur au milieu), tout revient entier et dans l'ordre.
> - `run_layout_resolution` : `fr` rend **169 caractères typables**, tape `é è à ç
>   ù` en frappe native, n'a **aucune touche** pour `ñ`, et refuse `señor` **en
>   entier** en nommant `ñ` comme bloqueur. `us` 104 caractères, refuse `é ñ ç`.
>   `de` tape `ä ö ü ß`. Réponse mesurée à la question « pack espagnol » : sur
>   clavier espagnol `ñ` se tape et `á` se colle — les voyelles accentuées y sont
>   des compositions à touche morte, pas des frappes uniques.
>
> Ces trois-là ne sont donc plus « à valider » : ils sont exécutés à chaque CI.
> Ce qui reste ci-dessous est ce qui exige un écran, un panneau et des yeux.

### 10.1 — Ce qu'un opérateur doit constater de ses yeux

> Ces lignes ne sont **pas** des tâches d'implémentation, et leur donner la forme
> `- [ ]` était une erreur de structure : aucun travail de code ne peut les
> cocher. Ce sont des observations sur un bureau Linux réel, elles vivent dans
> `HARDWARE.md`, et `validate.sh` les pose une par une.
>
> La moitié mécanisable de chacune est faite et tourne en CI — voir la note sous
> chaque ligne pour savoir laquelle exactement, et ce qui reste.


- 👁 Frappe normale capturée sous X11 **et** sous Wayland (post-grab kanata).
      *(le cœur — capture, grab, ré-émission — est vérifié ; reste la partie
      « le texte apparaît bien dans une vraie fenêtre », sur les deux serveurs)*
- 👁 Expansion accentuée (`NT’ ➜ N’T`, phrase FR) correcte sur les deux serveurs.
      *(la résolution de disposition est vérifiée sur de vraies keymaps ; reste
      la frappe réelle dans une application)*
- 👁 Frappe rapide pendant expansion → pas de corruption (C4).
      *(l'ordre des événements est prouvé sur un vrai noyau ; reste la
      confirmation visuelle dans un éditeur)*
- 👁 Bascule logout-X11 → login-Wayland sans reconfiguration (C2).
      *(la moitié mécanisable est vérifiée : `run_display_server.lua` tourne sous
      **Xvfb** puis sous **sway headless**, même binaire, zéro configuration entre
      les deux, et le cas piège — DISPLAY laissé positionné comme le fait XWayland
      sur toute session Wayland — est celui qui est testé. Reste que la session
      redémarre bien l'unité, ce qui exige une vraie ouverture de session)*
- 👁 Icône tray + sous-menu Hotstrings fonctionnels (KDE, GNOME+extension, sway).
      *(la moitié qui échoue **en silence** est vérifiée à chaque CI :
      `run_tray_symbols.lua` charge les trois sonames et résout les quinze
      symboles contre de vraies libayatana et GTK3 — 15/15. Un soname faux ou un
      symbole déplacé ne donne ni erreur ni crash, juste pas d'icône, et aucun
      test unitaire ne peut l'attraper puisqu'il doit stubber, et qu'un stub
      répond à n'importe quel nom. Reste que l'icône soit **visible**, ce qui
      exige un panneau qui héberge un StatusNotifierWatcher)*
- 👁 Trigger `★` changeable ; délais réglables ; tooltip au bon style.


## 11. Parité hotstrings Linux ↔ macOS/Windows (audit du 2026-08-05)

> **Question posée :** « a-t-on sur Linux 100 % des features hotstrings de AHK et
> HS ? notamment l'UI pour créer des hotstrings perso, les tooltips de différentes
> couleurs, définir les délais d'expansion… on doit aussi avoir exactement le même
> sous-menu hotstrings sur Linux que sur Windows et macOS. »
>
> **Réponse : non.** Six dimensions auditées en parallèle, chacune réfutée par un
> sceptique indépendant chargé de démolir ses conclusions : **46 écarts confirmés**,
> 3 réfutés (ceux-là étaient du travail en cours pendant l'audit). Onze sont
> bloquants au sens strict : la fonctionnalité est inatteignable ou fait le
> contraire de ce que le contrôle annonce.
>
> Ce que §5 mesurait, c'est ce qui avait été **construit**. Personne n'avait
> comparé **ligne à ligne** avec les deux autres pilotes, et c'est là que se
> cachait l'essentiel : des surfaces entières câblées à moitié, dont le côté
> visible passait tous les gates existants.

### 11.2 — Bloquants restants

- [x] **La fenêtre de réglages n exécutait pas son script dans WebKit** — corrigé.
      La cause n était dans aucune des sept hypothèses ci-dessous : `load_html(html,
      nil)` donne à la page une origine opaque `about:blank`, où les assignations
      `window.X` ne survivent pas. Le second argument est une URI de base, et il
      vaut `"file:///"` désormais (`ui/webview_manager.lua`). Le harnais de pièges
      d erreurs avait servi à établir que la page était saine, ce qui a déplacé
      l attention de la page vers la façon dont elle était chargée.
      → Journal d enquête conservé : sept hypothèses éliminées, dont aucune n était
        la bonne, ce qui est précisément ce qui rend le journal utile.

  **Journal d enquête (conservé).** Trouvé par
      `tests/hardware/run_webview_push.lua`, reproductible : `window.setData` est
      `undefined`, donc l hôte — qui garde `if(window.setData)` — jette chaque push.
      L éditeur, lui, est **vert et stable** (5/5, payload de 146 octets reçu), ce qui
      établit que le mécanisme de push et le harnais fonctionnent.
      → **Éliminé localement** : le script EST inliné (aucune balise externe ne
        survit dans l une ou l autre page) ; la balise est au niveau `body`, après
        les `<template>`, pas dedans ; les trois blocs assemblés **parsent** (page
        réassemblée et chaque bloc compilé) ; `makeHostBridge` répond `function`,
        donc les blocs 1 et 2 s exécutent bien.
      → **Éliminé en CI** : ce n est pas une interférence entre fenêtres — depuis que
        chaque page tourne dans son propre processus, l éditeur est vert et celle-ci
        échoue seule.
      → Une assignation explicite `window.setData = setData` en fin de fichier n y a
        rien changé, ce qui **exclut** la simple non-globalisation d une déclaration :
        si le script s exécutait jusqu au bout, cette ligne suffirait. L hypothèse
        restante est que le troisième bloc ne s exécute pas du tout, ou lève avant sa
        fin — à instrumenter avec un `window.onerror` posé AVANT les scripts de la
        page, ce que le harnais ne fait pas encore.
      → **Pas une troncature** non plus : la taille du bloc assemblé et celle du
        fichier sur disque se réconcilient exactement (l écart correspondait à un
        ajout fait après la mesure).

- [x] **Bascules par famille de règle dynamique** — fait le 2026-08-05 pour les
      4 familles que ce pilote enregistre (date, date_fr, date_long_fr,
      text_expansion_personal_information), dans l ordre et sous les libellés des
      deux autres pilotes, date du jour substituée, plus les deux lignes « tout
      activer / tout désactiver ».
      → **Le bloquant consigné ici était faux.** Il disait que
        `register_date_rules` enregistrait les trois règles de date « en lot, sans
        identifiant ». La lecture tranche : `add_rule(suffix, section, resolver)`
        porte une section depuis toujours, `register_date_rules` passe
        `date`/`datefr`/`datelongfr`, et `match_buffer(buffer, group, prédicat)`
        filtre dessus. Rien n était bloqué — ce pilote passait `nil` en prédicat
        aux **deux** sites d appel, `match_buffer` et `preview`. Le travail était
        dans le pilote, pas dans le moteur.
      → Le défaut visé est « une bascule qui écrit un booléen que rien ne relit » :
        sans le prédicat, la préférence se serait persistée, la coche affichée, et
        le pilote aurait continué de taper. Les trois assertions de fond du test
        de régression sont rouges quand on remet `nil`.

- [x] **Les trois familles de préfixes (iban, phone, ssn)** — faites le
      2026-08-05. Le manifeste les déclarait depuis toujours, Windows et macOS les
      rendaient, et aucun code Linux n en enregistrait une seule : la
      fonctionnalité était trois lignes dans un fichier que personne ne lisait, sur
      un pilote sur trois.
      → Ce ne sont **pas** des règles dynamiques. Un préfixe n a pas de touche de
        validation — taper `0750` EST le déclencheur — donc ce sont des mappings
        auto-expansifs ordinaires (`prefix_rules.lua`), remis au moteur habituel
        via un fournisseur injecté dans `hotstrings_config`. C est aussi pourquoi
        leur bascule ne peut pas être lue au moment du match : elle doit retirer
        les mappings, donc déclencher un rechargement.
      → Les seuils viennent du moteur partagé (`compute_prefix_counts`,
        `spaced_prefix`), pas d une deuxième implémentation.
      → **Prérequis livré séparément** : chaque mapping est `is_private`, et rien
        sur Linux n honorait ce drapeau. Sans lui, porter les préfixes aurait écrit
        l IBAN en clair dans `events_hotstring`, dans le `events_json` que l export
        multi-machines réplique, et dans le journal de 14 jours.
      → **Deux défauts trouvés en chemin**, tous deux corrigés avec leur test :
        `load_all()` sortait avant d ajouter les mappings du fournisseur quand
        aucun TOML n était trouvé (deux fichiers sans rapport, l un punissant
        l autre) ; et la garde d arguments de `inject()` imprimait
        `tostring(backspace_count)`, donc un appelant qui inversait ses deux
        arguments journalisait la charge depuis la position censée ne jamais en
        contenir.

### 11.3 — Majeurs et mineurs restants

- [x] **Menu Raccourcis Linux pilotable par le manifeste** — fait le 2026-08-05.
      La restriction `["ahk"]` disait « aucun pilote Lua n a ce concept », ce qui
      était faux pour les deux : macOS l implémente depuis que son menu Raccourcis
      existe, Linux depuis le 2026-08-05. Elle avait survécu à une tentative de
      correction parce qu un menu qui ne dispatche rien **par id** ne peut pas se
      voir promettre une ligne par id — le ratchet de bijection l aurait signalé.
      → Ce que le changement rend en échange : `keyboard_slots` était déclaré pour
        toutes les plateformes et Linux ne peut pas y répondre (aucune capture
        d accord, aucun stockage d assignation dans `modules/shortcuts/manager.lua`),
        donc le renderer aurait journalisé un avertissement « pas de fournisseur »
        à chaque construction. Restreint à `ahk`+`hs`, avec sa clé de raison dans
        les 21 locales — cela consigne un écart qui existait déjà, ce menu ne lisant
        aucun manifeste avant.
## 12. Gestes 3/4/5 doigts sur Linux (audit du 2026-08-05)

> **Demande :** « fais un audit de comment faire sur Linux pour mapper les gestes
> 3 doigts / 4 doigts / 5 doigts, swipe up/down, tap etc. et assigne-leur des
> actions », puis amener le sous-menu Gestes à parité.

### 12.1 — Le fait qui tranche l'architecture

**libinput plafonne les gestes tactiles à 4 doigts.** Vérifié mot pour mot dans
`src/evdev-mt-touchpad-gestures.c` (libinput 1.31.3) — la dernière instruction de
`tp_gesture_post_events()` est :

```c
if (tp->gesture.finger_count <= 4)
```

Un swipe à 5 doigts n'entre jamais dans la machine à états : aucun
`LIBINPUT_EVENT_GESTURE_SWIPE_BEGIN` avec `finger_count = 5` n'existe. Et la
documentation officielle dit que libinput « ne supporte pas les taps à quatre
doigts ni aucun tap au-delà », les taps sortant comme
`BTN_LEFT/RIGHT/MIDDLE` et jamais comme gestes.

> Deux agents de recherche se sont **contredits** sur ce point. Celui qui affirmait
> « il n'y a pas de plafond à 4 » citait le code de *comptage* des contacts et le
> prenait pour la *grille* des gestes. La contradiction a été tranchée en allant
> lire le corps complet de la fonction, pas en arbitrant entre deux résumés.

Conséquence chiffrée : sur les 36 slots simples déclarés dans
`_shared/modules/actions/actions.toml`, libinput peut en servir **16 au plus**
(3 et 4 doigts × 8 directions) et **zéro** des quatre taps.

### 12.2 — La route retenue

**Lire le nœud `/dev/input/eventN` du pavé tactile directement, SANS EVIOCGRAB**,
en décodant le protocole MT type B (slots `ABS_MT_*`) plus les bits
`BTN_TOOL_{FINGER,DOUBLETAP,TRIPLETAP,QUADTAP,QUINTTAP}` — le même mécanisme FFI
que `adapters/evdev_reader.lua` utilise déjà pour le clavier, sur un troisième
slot de lecture.

Rien de neuf à installer : `install.sh` ajoute déjà l'utilisateur aux groupes
`input` et `uinput` et pose la règle udev.

- **Pas de grab sur le pavé** : evdev est diffusé, plusieurs lecteurs voient tout.
- **Le compte de doigts vient du matériel**, pas du nombre de contacts localisés :
- **Sonde de capacité à l'ouverture** : le noyau ne publie `BTN_TOOL_QUADTAP` que

### 12.3 — Alternatives rejetées (à ne PAS re-proposer)

- **Binder `libinput.so` en FFI** — perdu sur la capacité (plafond ci-dessus), et
- **Générer une config pour un outil existant** (façon kanata) — aucun outil
- **Scraper `libinput debug-events`** — le header de `adapters/evdev_reader.lua`
- **Réutiliser `device_finder.find_pointer()`** — il renvoie le premier

### 12.4 — Ce qui ne marchera pas, et qu'il faut dire

- [ ] **20 des 36 slots sont physiquement hors d'atteinte sur certaines machines.**
      La spec Microsoft Precision Touchpad n'exige que 3 contacts simultanés.
- [ ] **Le bureau agira sur le même geste.** Lecture sans grab ⇒ sur GNOME 47+,
      KWin, Hyprland et cosmic-comp les swipes 3 et 4 doigts sont déjà réclamés :
      l'action du démon **et** celle du bureau se déclenchent. Non corrigeable sans
      le grab qui tue le curseur. Argument pour faire du **5 doigts** l'espace de
      noms primaire du pilote : rien d'autre sous Linux ne peut le réclamer.
- [ ] **Les slots 2 doigts (9 sur 36) se battront avec le défilement**, partout.
- [ ] **Aucun processus externe ne peut déplacer/focaliser/fermer une fenêtre sous
      Wayland.** Une action « aller à l'espace 3 » ne peut s'exprimer que comme une
      combinaison de touches que le compositeur lie déjà — et Hyprland, sway, i3,
      niri et river ne livrent aucune liaison par défaut.
### 12.5 — Les étapes

- [x] Slot `TOUCHPAD` ajouté, **sans grab** — grabber le pavé prendrait le pointeur
      au compositeur, et evdev est diffusé, donc lire en parallèle ne coûte rien.
      Sonde de capacité faite sans ioctl, validée sur vrai noyau (8/8).
- [x] `process_frame` retiré, avec ses 508 lignes de tests et la logique qu il
      était seul à utiliser (`_slot_for_dir`, `_compute_dir`, seuils, état de suivi).
      → **Une régression évitée de justesse** : un de ces tests épinglait qu un
        maintien immobile de 2 s n est PAS un tap. Mon décodeur classait par
        distance seule — poser les doigts aurait déclenché l action liée. Le
        plafond de temps est porté dans `mt_decoder`, horloge injectable (le bug
        d origine était `os.clock()`, dont le temps CPU n avance presque pas dans
        un démon I/O-bound).
      → Et une duplication de moins : `_slot_for_dir` orthographiait les mêmes
        noms de slots que `_slot_for_gesture`. Deux orthographes d une règle,
        c est exactement ce qui a produit `up_right` contre `right_up`.
- [x] `start_reading()` lit réellement : `touchpad_finder.find()` →
      `evdev_reader.open(path, TOUCHPAD)` → `mt_decoder` → `dispatch_gesture`,
      avec `pump()` branché sur le tick du démon.
      → Il **refuse et le dit** sans pavé, au lieu de prétendre lire. La ligne de
        menu « lecteur actif » basculait un talon et annonçait le contraire dans
        21 langues ; elle dit vrai maintenant.
- [x] Émission par **uinput**. `xdotool` est X11 seulement : sous Wayland la
      commande réussit, le shell sort zéro, et le geste ne fait rien — aucune
      erreur à trouver, et ça ressemble exactement à un slot non lié.
      → Table de 18 noms (ce que le catalogue utilise réellement), **bornée par un
        test** qui parcourt chaque combo généré : ajouter une action avec un nom
        absent fait échouer la suite au lieu de produire un geste muet.
      → Repli xdotool conservé quand le périphérique ne s’ouvre pas.
- [x] Capacité matérielle remontée au menu : les slots que le matériel ne peut pas
      servir sont **grisés avec une raison traduite** (21 locales), pas livrés
      vivants. Capacité illisible ⇒ tout reste offert.
- [x] **Tests du nouveau chemin** — faits. Les trois trous nommés ici sont
      couverts : `test_gesture_pump_chain.lua` va du lecteur au dispatch avec un
      lecteur factice, `test_gesture_dispatch.lua` lit la liste de slots
      **déclarée** (c est ce qui a attrapé `up_right` contre `right_up`), et
      `test_combo_press_order.lua` vérifie l ordre exact écrit sur le périphérique
      — un modificateur relâché avant sa touche donne une frappe nue, et aucun test
      de parsing ne peut le voir.
      → Ajouté depuis : `test_gesture_under_load.lua` couvre la borne de drain et
        `SYN_DROPPED`, les deux risques que l audit avait laissés « non testables ».
### 12.6 — Risques identifiés avant d'écrire une ligne

- [ ] **La trace d’événements du décodeur est une reconstruction, pas une capture.**
      Les fixtures de `test_mt_decoder.lua` sont dérivées du protocole documenté,
      pas d’un vrai pilote. `run_touchpad_capability.lua` a validé le format des
      **bitmaps** publiés par le noyau, ce qui est une autre question que
      l’entrelacement des événements dans une trame.
      → Capturer un vrai pavé (`evtest` ou `libinput record`) et rebâtir les
        fixtures dessus. Demande votre machine.
- [x] **`MAX_EVENTS_PER_DRAIN = 256` vérifié** le 2026-08-05. « Ne reproduit que
      sous charge » avait été lu comme « n est testable que sous charge », ce qui
      était faux : la charge ne fait que changer l arithmétique, et l arithmétique
      s énonce. Une trame à 5 doigts fait 16 événements (dérivée du vocabulaire du
      décodeur, pas comptée à la main, pour qu un axe ajouté plus tard déplace le
      chiffre) : la borne en tient 16, et couvre encore les 12 trames d un loop
      affamé 100 ms — cent fois sa cadence nominale. Un geste à cheval sur deux
      drains est décodé correctement, ce qui est le vrai risque : la borne est un
      point de rendu, pas une frontière.
- [x] **`SYN_DROPPED` vérifié** le 2026-08-05. La remise à zéro était déjà testée
      au niveau du décodeur ; ce qui ne l était pas, c est la panne que l audit
      annonçait — que le geste **suivant** hérite du compte périmé. Cinq doigts
      posés, trame perdue, puis swipe à trois : le geste sort bien à trois. Et le
      geste que la perte a interrompu n émet rien, y compris quand la perte
      survient une trame avant le lever, où tout ce qui le nomme a déjà été vu.
