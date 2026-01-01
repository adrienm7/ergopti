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

### Méthode Clean (libxkbcommon >= 1.13)

Structure d’installation (exemple) :

```
/usr/share/xkeyboard-config.d/ergopti/
├── symbols/
│   └── ergopti
├── types/
│   └── ergopti
├── rules/
│   └── evdev.xml
└── .XCompose (optionnel)
```

Avantages techniques :

1. Non-invasif — n’altère pas les fichiers système.
2. Priorité de recherche : les extensions sont prises en compte avant le répertoire système.
3. Facile à versionner et à désinstaller.
4. Suit les spécifications XKB modernes.

Comment ça marche (résumé) : libxkbcommon recherche les layouts dans plusieurs emplacements, dont `/usr/share/xkeyboard-config.d/*/` (extensions) avant `/usr/share/X11/xkb`.

### Méthode Legacy (toutes versions)

Structure modifiée :

```
/usr/share/X11/xkb/
├── symbols/
│   └── ergopti  # ajouté ou modifié
├── types/
│   └── ergopti  # ajouté ou modifié
└── rules/
    └── evdev.xml # modifié
```

Inconvénients :

- Modifie des fichiers gérés par le gestionnaire de paquets.
- Risque d’écrasement lors de mises à jour du package system (xkeyboard-config).
- Désinstallation moins triviale.

## Recommandations

- Utilisez la méthode Clean si votre système fournit libxkbcommon >= 1.13.0.
- Utilisez Legacy seulement pour des distributions anciennes sans support d’extensions.

### Installation automatique avec install.sh (recommandé)

Le script `install.sh` gère automatiquement le téléchargement, la sélection interactive (via fzf) et l’installation :

**Installation depuis internet (recommandé) :**

```bash
branch="main"; curl -fsSL "https://raw.githubusercontent.com/adrienm7/ergopti/$branch/static/drivers/linux/xkb_installation/install.sh" | BRANCH="$branch" bash
```

**Installation locale depuis le dépôt cloné :**

```bash
cd static/drivers/linux/xkb_installation
bash install.sh
```

Le script détecte automatiquement la meilleure méthode disponible (Clean ou Legacy) et propose une confirmation interactive.

### Forcer une méthode d’installation avec install.sh

Pour forcer l’utilisation de la méthode Clean (recommandé) :

```bash
bash install.sh --installation-method clean
```

Pour forcer la méthode Legacy (anciennes distributions uniquement) :

```bash
bash install.sh --installation-method legacy
```

**Note :** L’option `--installation-method` permet de contourner la détection automatique. Utilisez-la si vous connaissez précisément la méthode que vous souhaitez utiliser.

### Installation manuelle directe avec Python

Vous pouvez également utiliser directement les scripts Python d’installation :

**Méthode Clean :**

```bash
python3 xkb_files_installer_clean.py --xkb /chemin/vers/ergopti.xkb --types /chemin/vers/xkb_types.txt --xcompose /chemin/vers/.XCompose
```

**Méthode Legacy :**

```bash
python3 xkb_files_installer_legacy.py --xkb /chemin/vers/ergopti.xkb --types /chemin/vers/xkb_types.txt --xcompose /chemin/vers/.XCompose
```

### Options des scripts Python

- `--xkb <chemin>` : (Requis) Chemin vers le fichier .xkb de la disposition
- `--types <chemin>` : (Optionnel) Chemin vers le fichier de définition des types
- `--xcompose <chemin>` : (Optionnel) Chemin vers le fichier .XCompose

## Vérification et diagnostic

Un script shell de détection est fourni pour déterminer automatiquement quelle méthode sera utilisée. Il vérifie la version de libxkbcommon et retourne un code de sortie (0 = clean, 1 = legacy) :

```bash
bash detect_installation_method.sh
# Sortie attendue :
# libxkbcommon X.Y.Z found (meets requirement 1.13.0)
# Using clean installation method.
# exit code 0
```

Ce script :

- Détecte automatiquement libxkbcommon via `pkg-config`
- Propose optionnellement de compiler la dernière version si la version système est insuffisante
- Gère les chemins de bibliothèques personnalisés (`PKG_CONFIG_PATH`, `LD_LIBRARY_PATH`)
- Fournit un diagnostic clair de la méthode qui sera utilisée

## Désinstallation

### Méthode Clean

```bash
sudo rm -rf /usr/share/xkeyboard-config.d/ergopti
```

Il faudra également supprimer manuellement la ligne Ergopti dans `/usr/share/X11/xkb/rules/evdev` si nécessaire.

### Méthode Legacy

Le script legacy crée des sauvegardes comme `fichier.ext.1`, `fichier.ext.2`, etc. Il suffit de restaurer les fichiers originaux en supprimant les fichiers modifiés et en renommant les sauvegardes.

## Fichiers dans ce dossier

- `install.sh` : script shell complet d’installation interactif (téléchargement, sélection, installation)

Scripts utilisés par `install.sh` :

- `detect_installation_method.sh` : script de détection automatique de la méthode optimale
- `xkb_files_installer_clean.py` : installeur Python propre (extensions directories)
- `xkb_files_installer_legacy.py` : installeur Python legacy (modification des fichiers système)

## Références

- libxkbcommon — Packaging keyboard layouts: https://xkbcommon.org/doc/current/md_doc_2packaging-keyboard-layouts.html. Ce lien décrit en détail le fonctionnement des répertoires d’extensions XKB pour des installations non invasives.
