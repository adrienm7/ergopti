# Installation des fichiers XKB Ergopti

Ce document décrit les différentes méthodes d’installation du pilote Ergopti sur les systèmes Linux.

## Comparaison rapide

Deux méthodes d’installation sont proposées :

- Méthode "clean" (recommandée) — installe dans un répertoire d’extensions **non invasif**.
- Méthode "legacy" — modifie directement les fichiers système XKB (utilisée pour compatibilité avec les anciennes distributions).

| Aspect                        | Méthode Clean                            | Méthode Legacy                            |
| ----------------------------- | ---------------------------------------- | ----------------------------------------- |
| **Script Python**             | `xkb_files_installer_clean.py`           | `xkb_files_installer_legacy.py`           |
| **Script d’installation**     | `install.sh --installation-method clean` | `install.sh --installation-method legacy` |
| **Version requise**           | libxkbcommon >= 1.13.0, session Wayland  | Toutes versions, X11 et Wayland           |
| **Emplacement**               | `/usr/share/xkeyboard-config.d/ergopti/` | `/usr/share/X11/xkb/`                     |
| **Modification système**      | Non                                      | Oui                                       |
| **Conflit avec mises à jour** | Non                                      | Possible                                  |
| **Désinstallation**           | Simple (`rm -rf`)                        | Manuelle et complexe                      |
| **Composabilité**             | Oui (avec autres packages)               | Non                                       |

## Détails des méthodes

### Méthode Clean

Seul libxkbcommon lit les répertoires d'extensions. Le serveur Xorg compile ses dispositions avec
son propre `xkbcomp` depuis l'arbre hérité et ne les voit pas : le détecteur choisit donc la
méthode Legacy pour toute session X11, et aussi quand le type de session est indéterminé (SSH,
console). Le fragment `rules/evdev.post` du paquet déclare la règle `layout = types` sous sa forme
non indexée **et** indexée (`layout[1]` à `layout[4]`) : une règle non indexée ne s'applique qu'aux
configurations à une seule disposition, alors que GNOME et KDE compilent toutes les sources
configurées dans une même keymap.

### Méthode Legacy

Le script legacy crée des sauvegardes comme `fichier.ext.1`, `fichier.ext.2`, etc. La commande
`install.sh --uninstall` restaure automatiquement la première sauvegarde (état pré-Ergopti) de
chaque fichier touché. Le type personnalisé est inséré _à l'intérieur_ de la section `xkb_types`
de `types/extra` : un bloc ajouté après la section est une erreur de syntaxe que `xkbcomp` rejette
et que libxkbcommon ignore silencieusement. L'installation est transactionnelle : si le résultat
ne compile pas avec le type présent (`xkbcli`, et `xkbcomp` quand il est installé), chaque fichier
touché est restauré.

## Modes et options de l'installeur

```bash
# Interactif (fzf : version puis variante)
bash install.sh

# Non interactif (CI, scripts)
bash install.sh --yes --version v2_2_1 --variant ergopti_plus

# Désinstallation non interactive (méthode déduite des fichiers installés)
bash install.sh --uninstall --yes
```

Notes :

- Le fichier de types complet est **toujours** installé : il porte les couches Maj / Verr Maj /
  AltGr / raccourcis. L'ancien choix « sans Ctrl » a été supprimé car il cassait les raccourcis
  sur les touches accentuées (issue #84).
- Les variantes `_ansi` ne sont pas fusionnables avec les ISO : ce sont de vraies dispositions
  distinctes (ê, j et plusieurs symboles changent de touche). Utilisez `--ansi` sur un clavier
  physique ANSI.
- L'activation GNOME/KDE place Ergopti **en tête** de votre liste existante sans en retirer
  aucune : GNOME saisit avec la première source de la liste, donc une disposition ajoutée en
  fin de liste resterait inactive.
- L'activation ne s'exécute **jamais** sous `sudo`. GNOME conserve la liste des dispositions
  dans le dconf de l'utilisateur, joignable par son bus D-Bus de session : un écrit root
  atterrit dans les réglages de root et ne change rien de visible (issue #84). `install.sh`
  copie les fichiers sous `sudo`, puis relance l'installeur sans privilèges avec
  `--activate-only`. Lancé en root malgré tout, celui-ci redescend vers l'utilisateur du
  bureau (`runuser`) en reconstruisant `XDG_RUNTIME_DIR` et `DBUS_SESSION_BUS_ADDRESS`.
- La valeur écrite est **relue** ensuite : dconf renvoie un succès même quand l'écriture n'a
  rien changé, et un tel silence est exactement le mode de panne de l'issue #84.
- Seul le bureau qui possède le réglage compte comme activé. `gsettings` réussit sous Sway,
  Hyprland ou niri sans que ces compositeurs le lisent : dans ce cas l'installeur affiche le
  fragment de configuration exact à coller dans le fichier du compositeur, avec repli sur
  `~/.config/environment.d/` pour un compositeur Wayland inconnu.
- Après installation, `xkbcli compile-keymap` vérifie que la disposition se résout via le
  chemin de recherche de la distribution **et** contient le type `ERGOPTI_SEVEN_LEVEL`, seule
  puis à côté de `us` dans les deux ordres. Cette vérification ne dépend d'aucun bureau : elle
  distingue « paquet invisible » de « session qui n'utilise pas la disposition ».
- Sur GNOME, `mru-sources` est aligné sur `sources` : gnome-shell active au démarrage la première
  entrée de la liste des dispositions récentes, pas la première de `sources`.
- Sur KDE Plasma, `LayoutList` et `VariantList` sont deux listes alignées par index et `Use=true`
  est obligatoire ; la méthode Legacy y est écrite comme `fr` + `Ergopti_vX_Y_Z`, jamais avec le
  `+` de GNOME. Un signal D-Bus `org.kde.keyboard.reloadConfig` demande la relecture.
- Les fichiers `.XCompose` générés échappent les antislashs et guillemets dans les chaînes : un
  `"\"` non échappé faisait ignorer les séquences suivantes par libxkbcommon.
- La désinstallation refuse de choisir si des artefacts clean et legacy coexistent, ou si aucune
  installation n'est détectée. Dans le premier cas, relancez avec
  `--installation-method clean|legacy` après avoir vérifié la méthode à retirer.
- L'installation écrit dans les répertoires XKB système et requiert donc `sudo`. Un ancien mode
  `--user` a été retiré : le chemin qu'il utilisait n'était pas chargé par libxkbcommon et son
  isolation vis-à-vis des fichiers système n'était pas garantie.

### Surcharge des répertoires (tests / bac à sable)

L'installeur lit ces variables d'environnement avant ses chemins par défaut ; elles permettent
d'exécuter toute l'installation dans un dossier temporaire — c'est ainsi que la suite de tests
exécute le vrai CLI sans droits root :

| Variable                      | Défaut                          | Rôle                                            |
| ----------------------------- | ------------------------------- | ----------------------------------------------- |
| `ERGOPTI_XKB_EXTENSIONS_ROOT` | `/usr/share/xkeyboard-config.d` | Racine des extensions XKB                       |
| `ERGOPTI_XKB_SYSTEM_ROOT`     | `/usr/share/X11/xkb`            | Arbre X11 hérité (liens + patch rules nettoyés) |
| `ERGOPTI_XKB_CACHE_DIR`       | `/var/lib/xkb`                  | Cache XKB purgé après installation              |
| `ERGOPTI_XKB_USER_HOME`       | home de l'utilisateur appelant  | Home isolé pour les tests XCompose              |

Codes de sortie du script Python clean : `0` succès - `2` erreur d'usage (argparse) -
`3` paquet incohérent ou keymap non compilable - `4` installation abandonnée.

## Fichiers dans ce dossier

- `install.sh` : script shell complet d'installation interactif (téléchargement, sélection,
  installation)
- `layout_package.py` : cœur partagé et testable (contenus canoniques, validation
  symbols/types, helpers de fusion GNOME/KDE)
- `desktop_activation.py` : activation de session partagée par les deux installeurs
  (détection du bureau, abandon des privilèges, écriture puis relecture, instructions
  manuelles par compositeur, vérification de la keymap, retrait des entrées à la
  désinstallation)

Scripts utilisés par `install.sh` :

- `detect_installation_method.sh` : détection automatique de la méthode optimale
- `xkb_files_installer_clean.py` : installeur Python propre (extensions directories)
- `xkb_files_installer_legacy.py` : installeur Python legacy (modification des fichiers système)

Tests (`python tests/run_all_tests.py`) : unitaires du cœur, cohérence de toutes les versions
générées, bout-en-bout bac à sable des deux installeurs via les variables ci-dessus, compilation
réelle avec `xkbcli` (>= 1.13 pour la méthode Clean) et `xkbcomp` quand ils sont installés, dont
la reproduction des deux régressions historiques (règle non indexée, type hors section).

## Références

- libxkbcommon - Packaging keyboard layouts: https://xkbcommon.org/doc/current/md_doc_2packaging-keyboard-layouts.html
