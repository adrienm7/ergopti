# Installation des fichiers XKB Ergopti — Résumé et comparaison des méthodes

Ce document fusionne les informations de `README_INSTALLATION.md` et `COMPARISON.md` pour offrir un guide unique et concis d'installation des fichiers XKB d'Ergopti.

## Vue d'ensemble

Deux méthodes d'installation sont proposées :

- Méthode "clean" (recommandée) — installe dans un répertoire d'extensions **non invasif**.
- Méthode "legacy" — modifie directement les fichiers système XKB (utilisée pour compatibilité avec de très anciennes distributions).

## Comparaison rapide

| Aspect                        | Méthode Clean                            | Méthode Legacy           |
| ----------------------------- | ---------------------------------------- | ------------------------ |
| **Script**                    | `xkb_files_installer_clean.py`           | `xkb_files_installer.py` |
| **Version requise**           | libxkbcommon >= 1.13.0                   | Toutes versions          |
| **Emplacement**               | `/usr/share/xkeyboard-config.d/ergopti/` | `/usr/share/X11/xkb/`    |
| **Modification système**      | Non                                      | Oui                      |
| **Conflit avec mises à jour** | Non                                      | Possible                 |
| **Désinstallation**           | Simple (`rm -rf`)                        | Manuelle et complexe     |
| **Composabilité**             | Oui (avec autres packages)               | Non                      |

## Détails des méthodes

### Méthode Clean (libxkbcommon >= 1.13)

Structure d'installation (exemple) :

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

1. Non-invasif — n'altère pas les fichiers système.
2. Priorité de recherche : les extensions sont prises en compte avant le répertoire système.
3. Facile à versionner et à désinstaller.
4. Suit les spécifications XKB modernes.

Comment ça marche (résumé) : libxkbcommon recherche les layouts dans plusieurs emplacements, dont `/usr/share/xkeyboard-config.d/*/` (extensions) avant `/usr/share/X11/xkb`.

### Méthode Legacy (toutes versions)

Structure modifiée :

```
/usr/share/X11/xkb/
├── symbols/
│   └── ergopti  # ajouté ou modifié
├── types/
│   └── ergopti  # ajouté ou modifié
└── rules/
    └── evdev.xml # modifié
```

Inconvénients :

- Modifie des fichiers gérés par le gestionnaire de paquets.
- Risque d'écrasement lors de mises à jour du package system (xkeyboard-config).
- Désinstallation moins triviale.

## Recommandations

- Utilisez la méthode Clean si votre système fournit libxkbcommon >= 1.13.0.
- Utilisez Legacy seulement pour des distributions anciennes sans support d'extensions.

## Utilisation des scripts (emplacement du répertoire)

Les scripts se trouvent dans `static/drivers/linux/` (ou dans le sous-dossier `static/drivers/linux/xkb_installation/` selon l'organisation de la copie sur le site).

### Mode automatique (recommandé)

Le script de sélection détecte automatiquement la meilleure méthode disponible et guide le processus :

```bash
cd static/drivers/linux
python xkb_files_selector.py
```

### Mode non-interactif

Pour une exécution automatisée :

```bash
python xkb_files_selector.py --non-interactive
```

### Forcer une méthode

Forcer la méthode clean :

```bash
python xkb_files_selector.py --installation-method clean
```

Forcer la méthode legacy :

```bash
python xkb_files_selector.py --installation-method legacy
```

### Options utiles

- `--version vX_Y_Z` : sélectionner une version générée
- `--variant <variant>` : choisir la variante (ex. `plus`)
- `--search-dir /path/to` : rechercher des fichiers localement
- `--types 1|2|/path/to/types.txt` : types complets / types sans Ctrl sur accents / custom

## Vérification et diagnostic

Un petit utilitaire de détection est fourni pour savoir quelle méthode sera choisie : il affiche une ligne résumée sur la version détectée de libxkbcommon et une ligne indiquant la méthode choisie, puis retourne un code de sortie (0 = clean, 1 = legacy).

Exemple : (nom actuel du script dans le repo : `detect_installation_method.py`)

```bash
python detect_installation_method.py
# Sortie attendue :
# libxkbcommon X.Y.Z found (meets requirement 1.13.0)
# Using clean installation method.
# exit code 0
```

Si `pkg-config` n'est pas disponible, le script tente une lecture via `dpkg-query` sur les paquets Debian habituels (utile sur Ubuntu / Zorin).

## Migration Legacy → Clean

Si vous avez installé la version legacy et souhaitez migrer :

1. Désinstallez l'ancienne installation (suivez la procédure propre à votre installation legacy).
2. Vérifiez la version de libxkbcommon :

```bash
pkg-config --modversion xkbcommon
```

3. Installez avec la méthode clean :

```bash
python xkb_files_selector.py --installation-method clean
```

4. Vérifiez le fonctionnement :

```bash
setxkbmap ergopti
```

## Désinstallation

### Méthode propre

```bash
sudo rm -rf /usr/share/xkeyboard-config.d/ergopti
```

### Méthode legacy

Consulter la documentation de l'installeur legacy (les fichiers modifiés et les sauvegardes créées) pour restaurer les fichiers d'origine. Le script legacy crée des sauvegardes comme `fichier.ext.1`, `fichier.ext.2`, etc.

## Fichiers dans ce dossier

- `xkb_files_selector.py` : script interactif de sélection et lancement de l'installation
- `xkb_files_installer.py` : installeur legacy (modification des fichiers système)
- `xkb_files_installer_clean.py` : installeur propre (extensions directories)
- `detect_installation_method.py` : script de détection / probe (résumé + code de sortie)

## Tests et diagnostic (rapide)

- Lancez `detect_installation_method.py` pour vérifier la méthode disponible.
- Pour tester la génération d'artefacts (si vous développez), utilisez `xkb_generation/generate_xkb_files.py` depuis le répertoire `static/drivers/linux/`.

## Références

- libxkbcommon — Packaging keyboard layouts: https://xkbcommon.org/doc/current/md_doc_2packaging-keyboard-layouts.html
- XKB Configuration / xkeyboard-config docs: https://xkbcommon.org

---

Si vous souhaitez que j'ajuste le texte (par ex. rendre le fichier en `README.md`, corriger des références de chemins après la récente réorganisation, ou supprimer les anciennes copies en double), dites-le et je m'en occupe.