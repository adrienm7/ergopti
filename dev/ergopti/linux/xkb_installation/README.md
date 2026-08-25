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
| **Version requise**           | libxkbcommon >= 1.13.0                   | Toutes versions                           |
| **Emplacement**               | `/usr/share/xkeyboard-config.d/ergopti/` | `/usr/share/X11/xkb/`                     |
| **Modification système**      | Non                                      | Oui                                       |
| **Conflit avec mises à jour** | Non                                      | Possible                                  |
| **Désinstallation**           | Simple (`rm -rf`)                        | Manuelle et complexe                      |
| **Composabilité**             | Oui (avec autres packages)               | Non                                       |

## Détails des méthodes

### Méthode Legacy

Le script legacy crée des sauvegardes comme `fichier.ext.1`, `fichier.ext.2`, etc. La commande
`install.sh --uninstall` restaure automatiquement la première sauvegarde (état pré-Ergopti) de
chaque fichier touché.

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
- L'activation GNOME/KDE ajoute Ergopti à votre liste existante au lieu de la remplacer.
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

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `ERGOPTI_XKB_EXTENSIONS_ROOT` | `/usr/share/xkeyboard-config.d` | Racine des extensions XKB |
| `ERGOPTI_XKB_SYSTEM_ROOT` | `/usr/share/X11/xkb` | Arbre X11 hérité (liens + patch rules nettoyés) |
| `ERGOPTI_XKB_CACHE_DIR` | `/var/lib/xkb` | Cache XKB purgé après installation |
| `ERGOPTI_XKB_USER_HOME` | home de l'utilisateur appelant | Home isolé pour les tests XCompose |

Codes de sortie du script Python clean : `0` succès - `2` erreur d'usage (argparse) -
`3` paquet incohérent ou keymap non compilable - `4` installation abandonnée.

## Fichiers dans ce dossier

- `install.sh` : script shell complet d'installation interactif (téléchargement, sélection,
  installation)
- `layout_package.py` : cœur partagé et testable (contenus canoniques, validation
  symbols/types, helpers d'activation GNOME/KDE)

Scripts utilisés par `install.sh` :

- `detect_installation_method.sh` : détection automatique de la méthode optimale
- `xkb_files_installer_clean.py` : installeur Python propre (extensions directories)
- `xkb_files_installer_legacy.py` : installeur Python legacy (modification des fichiers système)

Tests (`python tests/run_all_tests.py`) : unitaires du cœur, cohérence de toutes les versions
générées, bout-en-bout bac à sable via les variables ci-dessus, compilation RMLVO réelle quand
le paquet Python `xkbcommon` est présent.

## Références

- libxkbcommon - Packaging keyboard layouts: https://xkbcommon.org/doc/current/md_doc_2packaging-keyboard-layouts.html
