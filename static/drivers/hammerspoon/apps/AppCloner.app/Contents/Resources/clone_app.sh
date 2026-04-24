#!/bin/zsh
# apps/ShortcutBuilder.app/Contents/Resources/clone_app.sh
#
# Crée un clone léger d'une application macOS avec :
#   - bundle ID unique  → pas de regroupement Dock avec l'originale
#   - icône teintée     → couleur personnalisée superposée à l'icône source
#   - wrapper shell     → relance l'app originale (-n = nouvelle instance)
#   - option launch arg → fichier/dossier à passer à l'ouverture
#
# Usage:
#   clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>
#   open_arg : chemin de fichier/dossier à ouvrir, ou "" pour aucun
set -euo pipefail

SOURCE_APP="$1"   # Ex: /Applications/Visual Studio Code.app
CLONE_NAME="$2"   # Ex: "VSCode — Projet A"
COLOR_HEX="$3"    # Ex: "#E04040"   (teinte de l'icône)
OPEN_ARG="$4"     # Ex: "/Users/me/Projects/projA"  ou ""

# ─────────────────────────────────────────────
# 1) Validation
# ─────────────────────────────────────────────
if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Erreur : application source introuvable : $SOURCE_APP" >&2
  exit 1
fi

# ─────────────────────────────────────────────
# 2) Nettoyage du nom → nom de fichier sûr
# ─────────────────────────────────────────────
safe_name="$(printf '%s' "$CLONE_NAME" \
  | sed 's|/|-|g' \
  | sed "s/[^[:alnum:][:space:]'._()-]/_/g" \
  | sed 's/_\{2,\}/_/g' \
  | sed -e 's/^[ _-]*//' -e 's/[ _-]*$//')"
[[ -z "$safe_name" ]] && safe_name="Clone"

DEST="$HOME/Desktop/${safe_name}.app"
if [[ -e "$DEST" ]]; then
  DEST="$HOME/Desktop/${safe_name}_$(date +%s).app"
fi

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ─────────────────────────────────────────────
# 3) Extraction de l'icône source
# ─────────────────────────────────────────────
# Lire le plist de l'app source pour trouver le fichier .icns
SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_ICON_FILE=""
if [[ -f "$SRC_PLIST" ]]; then
  SRC_ICON_FILE="$(defaults read "$SRC_PLIST" CFBundleIconFile 2>/dev/null || true)"
fi
# macOS ajoute parfois automatiquement l'extension
[[ -n "$SRC_ICON_FILE" && "${SRC_ICON_FILE##*.}" != "icns" ]] && SRC_ICON_FILE="${SRC_ICON_FILE}.icns"

SRC_ICNS=""
if [[ -n "$SRC_ICON_FILE" ]]; then
  candidate="$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE"
  [[ -f "$candidate" ]] && SRC_ICNS="$candidate"
fi
# Fallback : premier .icns trouvé dans Resources
if [[ -z "$SRC_ICNS" ]]; then
  SRC_ICNS="$(find "$SOURCE_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -n1 || true)"
fi

# ─────────────────────────────────────────────
# 4) Construction de l'icône teintée
# ─────────────────────────────────────────────
# Extraire la PNG 512px depuis le .icns source (si disponible)
BASE_PNG="$TMPDIR_WORK/base.png"
if [[ -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
  # iconutil décompresse en iconset, on prend la plus grande taille disponible
  ICONSET_TMP="$TMPDIR_WORK/src.iconset"
  iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" >/dev/null 2>&1 || true
  # Prendre la plus grande résolution disponible
  for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256" "icon_128x128@2x"; do
    candidate="$ICONSET_TMP/${sz}.png"
    if [[ -f "$candidate" ]]; then
      cp "$candidate" "$BASE_PNG"
      break
    fi
  done
fi

# Si on n'a pas réussi à extraire l'icône source, créer une icône générique
if [[ ! -f "$BASE_PNG" ]]; then
  SRC_NAME="$(basename "$SOURCE_APP" .app)"
  INITIALS="$(printf '%s' "$SRC_NAME" | awk '{for(i=1;i<=NF&&i<=2;i++) printf toupper(substr($i,1,1))}' FS=' ')"
  [[ -z "$INITIALS" ]] && INITIALS="${SRC_NAME:0:2}"
  SVG_FALLBACK="$TMPDIR_WORK/fallback.svg"
  cat > "$SVG_FALLBACK" <<SVGEOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" ry="220" fill="#888888"/>
  <text x="512" y="512" font-family="Helvetica-Bold,Arial,sans-serif" font-size="420" font-weight="900"
        fill="#FFFFFF" text-anchor="middle" dominant-baseline="middle">${INITIALS}</text>
</svg>
SVGEOF
  qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$SVG_FALLBACK" >/dev/null 2>&1 || true
  FALLBACK_PNG="$(ls -S "$TMPDIR_WORK"/*.png 2>/dev/null | head -n1 || true)"
  [[ -n "$FALLBACK_PNG" ]] && cp "$FALLBACK_PNG" "$BASE_PNG"
fi

# Superposer une teinte de couleur semi-transparente sur l'icône source
# On génère un overlay SVG de même taille et on le composite via sips ou qlmanage
TINTED_PNG="$TMPDIR_WORK/tinted.png"
if [[ -f "$BASE_PNG" ]]; then
  # Récupérer la taille réelle de la PNG source
  IMG_W="$(sips -g pixelWidth "$BASE_PNG" 2>/dev/null | awk '/pixelWidth/{print $2}' || echo 512)"
  IMG_H="$(sips -g pixelHeight "$BASE_PNG" 2>/dev/null | awk '/pixelHeight/{print $2}' || echo 512)"

  # Créer un SVG overlay de teinte (50 % opacité)
  OVERLAY_SVG="$TMPDIR_WORK/overlay.svg"
  cat > "$OVERLAY_SVG" <<SVGEOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="${IMG_W}" height="${IMG_H}">
  <rect width="${IMG_W}" height="${IMG_H}" fill="${COLOR_HEX}" opacity="0.45"/>
</svg>
SVGEOF

  # Convertir l'overlay SVG en PNG via qlmanage
  qlmanage -t -s "$IMG_W" -o "$TMPDIR_WORK/ov" "$OVERLAY_SVG" >/dev/null 2>&1 || true
  OVERLAY_PNG="$(ls -S "$TMPDIR_WORK/ov"/*.png 2>/dev/null | head -n1 || true)"

  if [[ -n "$OVERLAY_PNG" && -f "$OVERLAY_PNG" ]]; then
    # Assurer que l'overlay a la bonne taille
    sips -z "$IMG_H" "$IMG_W" "$OVERLAY_PNG" >/dev/null 2>&1 || true
    # Composer : base_png + overlay_png via AppleScript (CISourceOverCompositing)
    COMPOSE_SCRIPT="$TMPDIR_WORK/compose.applescript"
    cat > "$COMPOSE_SCRIPT" <<ASEOF
use framework "Foundation"
use framework "AppKit"
use framework "CoreImage"
use scripting additions

set basePath to "$BASE_PNG"
set overlayPath to "$OVERLAY_PNG"
set outPath to "$TINTED_PNG"

set baseImg  to current application's NSImage's alloc()'s initWithContentsOfFile:basePath
set overlayImg to current application's NSImage's alloc()'s initWithContentsOfFile:overlayPath

set sz to baseImg's |size|()
set rep to current application's NSBitmapImageRep's alloc()'s ¬
    initWithBitmapDataPlanes:(missing value) ¬
    pixelsWide:(sz's width) pixelsHigh:(sz's height) ¬
    bitsPerSample:8 samplesPerPixel:4 hasAlpha:true ¬
    isPlanar:false colorSpaceName:"NSCalibratedRGBColorSpace" ¬
    bytesPerRow:0 bitsPerPixel:0

set ctx to current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:rep
current application's NSGraphicsContext's setCurrentContext:ctx

baseImg's drawInRect:{origin:{x:0, y:0}, |size|:{width:(sz's width), height:(sz's height)}} ¬
    fromRect:{origin:{x:0, y:0}, |size|:{width:(sz's width), height:(sz's height)}} ¬
    operation:(current application's NSCompositingOperationSourceOver) fraction:1.0

overlayImg's drawInRect:{origin:{x:0, y:0}, |size|:{width:(sz's width), height:(sz's height)}} ¬
    fromRect:{origin:{x:0, y:0}, |size|:{width:(sz's width), height:(sz's height)}} ¬
    operation:(current application's NSCompositingOperationSourceOver) fraction:1.0

(ctx's flushGraphics())

set pngData to rep's representationUsingType:(current application's NSBitmapImageFileTypePNG) |properties|:(missing value)
pngData's writeToFile:outPath atomically:true
ASEOF
    osascript "$COMPOSE_SCRIPT" >/dev/null 2>&1 || cp "$BASE_PNG" "$TINTED_PNG"
  else
    cp "$BASE_PNG" "$TINTED_PNG"
  fi
else
  # Aucune icône source disponible → icône teintée pure
  TINTED_PNG="$TMPDIR_WORK/tinted_fallback.png"
  TINTED_SVG="$TMPDIR_WORK/tinted.svg"
  SRC_NAME="$(basename "$SOURCE_APP" .app)"
  INITIALS="$(printf '%s' "$SRC_NAME" | awk '{for(i=1;i<=NF&&i<=2;i++) printf toupper(substr($i,1,1))}' FS=' ')"
  [[ -z "$INITIALS" ]] && INITIALS="${SRC_NAME:0:2}"
  cat > "$TINTED_SVG" <<SVGEOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" ry="220" fill="${COLOR_HEX}"/>
  <text x="512" y="512" font-family="Helvetica-Bold,Arial,sans-serif" font-size="420" font-weight="900"
        fill="#FFFFFF" text-anchor="middle" dominant-baseline="middle">${INITIALS}</text>
</svg>
SVGEOF
  qlmanage -t -s 1024 -o "$TMPDIR_WORK/tf" "$TINTED_SVG" >/dev/null 2>&1 || true
  TINTED_PNG_TMP="$(ls -S "$TMPDIR_WORK/tf"/*.png 2>/dev/null | head -n1 || true)"
  [[ -n "$TINTED_PNG_TMP" ]] && cp "$TINTED_PNG_TMP" "$TINTED_PNG"
fi

# ─────────────────────────────────────────────
# 5) Génération du .icns pour le clone
# ─────────────────────────────────────────────
ICONSET="$TMPDIR_WORK/clone.iconset"
mkdir -p "$ICONSET"

if [[ -f "$TINTED_PNG" ]]; then
  sips -z 16   16   "$TINTED_PNG" --out "$ICONSET/icon_16x16.png"      >/dev/null 2>&1 || true
  sips -z 32   32   "$TINTED_PNG" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null 2>&1 || true
  sips -z 32   32   "$TINTED_PNG" --out "$ICONSET/icon_32x32.png"      >/dev/null 2>&1 || true
  sips -z 64   64   "$TINTED_PNG" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null 2>&1 || true
  sips -z 128  128  "$TINTED_PNG" --out "$ICONSET/icon_128x128.png"    >/dev/null 2>&1 || true
  sips -z 256  256  "$TINTED_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1 || true
  sips -z 256  256  "$TINTED_PNG" --out "$ICONSET/icon_256x256.png"    >/dev/null 2>&1 || true
  sips -z 512  512  "$TINTED_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1 || true
  sips -z 512  512  "$TINTED_PNG" --out "$ICONSET/icon_512x512.png"    >/dev/null 2>&1 || true
  cp "$TINTED_PNG"                    "$ICONSET/icon_512x512@2x.png"   2>/dev/null || true
fi

ICONFILE="$RES/AppIcon.icns"
iconutil -c icns "$ICONSET" -o "$ICONFILE" >/dev/null 2>&1 || true

# ─────────────────────────────────────────────
# 6) Info.plist du clone
# ─────────────────────────────────────────────
# Bundle ID unique : base sur timestamp pour garantir l'unicité
UNIQUE_ID="fr.b519hs.clone.$(date +%s%N | head -c 16)"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
  <key>CFBundleIdentifier</key>
  <string>${UNIQUE_ID}</string>
  <key>CFBundleName</key>
  <string>${safe_name}</string>
  <key>CFBundleDisplayName</key>
  <string>${safe_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleVersion</key>
  <string>1.0</string>
  <key>LSUIElement</key>
  <false/>
</dict>
</plist>
PLIST

# ─────────────────────────────────────────────
# 7) Exécutable launcher
# ─────────────────────────────────────────────
# -n force une nouvelle instance distincte (pas de regroupement avec l'originale)
# L'app parente doit supporter plusieurs instances ou être une app Electron/non-singleton
cat > "$MACOS/launcher" <<'LAUNCHER_HEAD'
#!/bin/zsh
# Wrapper léger : ouvre l'app source comme nouvelle instance distincte.
# Le bundle ID différent garantit que le Dock ne la groupe pas avec l'originale.
LAUNCHER_HEAD

printf 'SOURCE_APP="%s"\n' "$SOURCE_APP" >> "$MACOS/launcher"
printf 'OPEN_ARG="%s"\n\n' "$OPEN_ARG"  >> "$MACOS/launcher"

cat >> "$MACOS/launcher" <<'LAUNCHER_BODY'
if [[ -n "$OPEN_ARG" && -e "$OPEN_ARG" ]]; then
  # -n : nouvelle instance  |  --args : transmet l'argument à l'app
  open -n -a "$SOURCE_APP" "$OPEN_ARG" &>/dev/null & disown
else
  open -n -a "$SOURCE_APP" &>/dev/null & disown
fi
LAUNCHER_BODY

chmod +x "$MACOS/launcher"

# Forcer le rafraîchissement du cache d'icône macOS
touch "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

echo "$DEST"
