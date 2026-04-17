#!/bin/zsh
set -euo pipefail

name="$1"
target="$2"
app="$3"
color="$4"
label="$5"

# sanitize name (robust): trim, remove .app suffix if given, replace unsafe chars
raw="$name"
# trim leading/trailing space
raw="$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
# strip trailing .app if user provided it
raw_lc="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
if printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | grep -q '\.app$'; then
  base="${raw%.[aA][pP][pP]}"
else
  base="$raw"
fi
# replace forward slash with hyphen
base="$(printf '%s' "$base" | sed 's|/|-|g')"
# replace any character not alnum, space, dot, underscore, hyphen, parentheses with underscore
base="$(printf '%s' "$base" | sed 's/[^[:alnum:][:space:]._()-]/_/g')"
# collapse multiple underscores
base="$(printf '%s' "$base" | sed 's/_\{2,\}/_/g')"
# trim underscores/spaces at ends
base="$(printf '%s' "$base" | sed -e 's/^[ _-]*//' -e 's/[ _-]*$//')"
# replace underscores with spaces and apply Title Case
base="$(printf '%s' "$base" | perl -pe 's/_/ /g; s/([A-Za-z0-9]+)/ucfirst(lc($1))/ge;')"
if [[ -z "$base" ]]; then
  base="Raccourci"
fi
if [[ "$base" != *.app ]]; then
  san="$base.app"
else
  san="$base"
fi
DEST="$HOME/Desktop/$san"
if [ -e "$DEST" ]; then
  DEST="$HOME/Desktop/${san%.app}_$(date +%s).app"
fi

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RES"

TMPDIR=$(mktemp -d "/tmp/shortcut.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

SVG="$TMPDIR/icon.svg"
cat > "$SVG" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" fill="transparent"/>
  <rect x="64" y="312" rx="56" ry="56" width="896" height="512" fill="${color}"/>
  <rect x="64" y="224" rx="32" ry="32" width="384" height="128" fill="${color}"/>
  <text x="512" y="560" font-family="Helvetica, Arial, sans-serif" font-size="220" font-weight="700" fill="#ffffff" text-anchor="middle" dominant-baseline="middle">${label}</text>
</svg>
EOF

# render SVG to PNG using QuickLook
qlmanage -t -s 1024 -o "$TMPDIR" "$SVG" >/dev/null 2>&1 || true
PNG=$(ls -S "$TMPDIR"/*.png 2>/dev/null | head -n1 || true)
if [ -z "$PNG" ]; then
  echo "Erreur: aucune image PNG produite" >&2
  exit 1
fi

ICONSET="$TMPDIR/icon.iconset"
mkdir -p "$ICONSET"

sips -z 16 16 "$PNG" --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1 || true
sips -z 32 32 "$PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1 || true
sips -z 32 32 "$PNG" --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1 || true
sips -z 64 64 "$PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1 || true
sips -z 128 128 "$PNG" --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1 || true
sips -z 256 256 "$PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1 || true
sips -z 256 256 "$PNG" --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1 || true
sips -z 512 512 "$PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1 || true
sips -z 512 512 "$PNG" --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1 || true
cp "$PNG" "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1 || true

ICONFILE="$RES/icon.icns"
iconutil -c icns "$ICONSET" -o "$ICONFILE" >/dev/null 2>&1 || true

# Info.plist
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>open_target</string>
  <key>CFBundleIdentifier</key>
  <string>fr.b519hs.shortcut.$(date +%s)</string>
  <key>CFBundleName</key>
  <string>${san%.app}</string>
  <key>CFBundleDisplayName</key>
  <string>${san%.app}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>icon.icns</string>
</dict>
</plist>
PLIST

# create executable that opens the target with the chosen app
# Build the file in parts so we expand only the variables we want ($app, $target)
# and avoid expanding runtime vars like $APP_NAME or inner here-doc contents.
cat > "$MACOS/open_target" <<'SH_HEAD'
#!/bin/zsh
# This script opens the target folder with the chosen app (or VS Code CLI)
# and then attempts to maximize the app window (AXZoom) without using
# macOS Full Screen.
SH_HEAD

printf 'APP_PATH="%s"\n' "$app" >> "$MACOS/open_target"
printf 'TARGET="%s"\n\n' "$target" >> "$MACOS/open_target"

cat >> "$MACOS/open_target" <<'SH_BODY'
if command -v code >/dev/null 2>&1; then
  code -n "$TARGET" &> /dev/null & disown
else
  open -a "$APP_PATH" "$TARGET" &> /dev/null & disown
fi

# Compute simple app process name
APP_NAME="$(basename "$APP_PATH" .app)"

# Create a short AppleScript to wait for the process and perform AXZoom on its
# front window. This uses Accessibility (System Events) so the user may need to
# grant permission for automation.
ASFILE="$(mktemp /tmp/zoom.XXXXXX.applescript)"
cat > "$ASFILE" <<'AS'
delay 0.8
tell application "System Events"
  repeat 10 times
    if exists (process "$APP_NAME") then exit repeat
    delay 0.2
  end repeat
  try
    tell process "$APP_NAME"
      set frontmost to true
      try
        tell window 1 to perform action "AXZoom"
      end try
    end tell
  end try
end tell
AS

osascript "$ASFILE" >/dev/null 2>&1 &
(sleep 6; rm -f "$ASFILE") &

SH_BODY

chmod +x "$MACOS/open_target"

touch "$DEST"

echo "$DEST"
