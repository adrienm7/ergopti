#!/bin/zsh
# apps/AppCloner.app/Contents/Resources/clone_app.sh
# Usage: clone_app.sh <source_app_path> <clone_name> <color_hex> <open_arg>

LOG=/tmp/clone_app.log
exec >> "$LOG" 2>&1

set -euo pipefail

SOURCE_APP="${1:-}"
CLONE_NAME="${2:-}"
COLOR_HEX="${3:-}"
OPEN_ARG="${4:-}"

echo "=== $(date) SOURCE=$SOURCE_APP NAME=$CLONE_NAME COLOR=$COLOR_HEX ARG=$OPEN_ARG ==="

[[ -z "$SOURCE_APP" ]] && { echo "Error: SOURCE_APP missing"; exit 1; }
[[ ! -d "$SOURCE_APP" ]] && { echo "Error: source not found: $SOURCE_APP"; exit 1; }


# ── 1) Safe name ────────────────────────────────────────────────────────────
safe_name="$(printf '%s' "$CLONE_NAME" | tr ':/' '-' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
[[ -z "$safe_name" ]] && safe_name="Clone"

APPS_DIR="$HOME/Applications"
mkdir -p "$APPS_DIR"
DEST="$APPS_DIR/${safe_name}.app"
[[ -e "$DEST" ]] && DEST="$APPS_DIR/${safe_name}_$(date +%s).app"
echo "DEST=$DEST"

# APFS clone of the source bundle — copy-on-write, near-instant, no disk cost.
# Required for Electron apps (VSCode, etc.): the process reads its own path via
# _NSGetExecutablePath and must sit in a distinct bundle to avoid joining the
# original instance. A binary symlink is not enough — macOS resolves the
# symlink and the real bundle becomes the source again.
cp -cR "$SOURCE_APP/" "$DEST/" 2>/dev/null || cp -R "$SOURCE_APP/" "$DEST/"
echo "Bundle cloned"

CONTENTS="$DEST/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# Keep original signatures in place — we need their entitlements metadata
# (hardened runtime, sandbox, etc.) to be preserved when we re-sign later.

TMPDIR_WORK=$(mktemp -d "/tmp/appcloner.XXXXXX")
trap 'rm -rf "$TMPDIR_WORK"' EXIT


# ── 2) Extract source icon → PNG ────────────────────────────────────────────
SRC_PLIST="$SOURCE_APP/Contents/Info.plist"
SRC_ICON_FILE="$(defaults read "$SRC_PLIST" CFBundleIconFile 2>/dev/null || true)"
[[ -n "$SRC_ICON_FILE" && "${SRC_ICON_FILE##*.}" != "icns" ]] && SRC_ICON_FILE="${SRC_ICON_FILE}.icns"

SRC_ICNS=""
[[ -n "$SRC_ICON_FILE" && -f "$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE" ]] \
  && SRC_ICNS="$SOURCE_APP/Contents/Resources/$SRC_ICON_FILE"
[[ -z "$SRC_ICNS" ]] \
  && SRC_ICNS="$(find "$SOURCE_APP/Contents/Resources" -maxdepth 1 -name '*.icns' | head -n1 || true)"
echo "SRC_ICNS=$SRC_ICNS"

BASE_PNG="$TMPDIR_WORK/base.png"
if [[ -n "$SRC_ICNS" && -f "$SRC_ICNS" ]]; then
  ICONSET_TMP="$TMPDIR_WORK/src.iconset"
  iconutil -c iconset "$SRC_ICNS" -o "$ICONSET_TMP" 2>/dev/null || true
  for sz in "icon_512x512@2x" "icon_512x512" "icon_256x256@2x" "icon_256x256"; do
    [[ -f "$ICONSET_TMP/${sz}.png" ]] && cp "$ICONSET_TMP/${sz}.png" "$BASE_PNG" && echo "PNG: $sz" && break
  done
fi
if [[ ! -f "$BASE_PNG" ]]; then
  echo "Fallback generic icon"
  SRC_INIT="${$(basename "$SOURCE_APP" .app):0:2}"
  cat > "$TMPDIR_WORK/fb.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <rect width="1024" height="1024" rx="220" fill="#888"/>
  <text x="512" y="580" font-family="Helvetica-Bold" font-size="480" font-weight="900"
        fill="#FFF" text-anchor="middle">${SRC_INIT}</text>
</svg>
SVG
  qlmanage -t -s 1024 -o "$TMPDIR_WORK" "$TMPDIR_WORK/fb.svg" >/dev/null 2>&1 || true
  cp "$(ls "$TMPDIR_WORK"/*.png 2>/dev/null | head -1)" "$BASE_PNG" 2>/dev/null || true
fi


# ── 3) Tint — pixel-by-pixel HSV rotation (pure Python stdlib) ──────────────
# No AppleScript, no external dependency. Read/write PNG via struct+zlib,
# rotate hue of every saturated pixel toward the target, preserve B/W regions.
R_INT=$(( 16#${COLOR_HEX:1:2} ))
G_INT=$(( 16#${COLOR_HEX:3:2} ))
B_INT=$(( 16#${COLOR_HEX:5:2} ))

TINTED_PNG="$TMPDIR_WORK/tinted.png"

python3 - "$BASE_PNG" "$TINTED_PNG" "$R_INT" "$G_INT" "$B_INT" <<'TINTEOF'
import sys, math, colorsys, struct, zlib

src, dst = sys.argv[1], sys.argv[2]
r_int, g_int, b_int = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
target_h, target_s, _ = colorsys.rgb_to_hsv(r_int/255, g_int/255, b_int/255)

# Raw PNG reader (8-bit RGB or RGBA only)
def png_read(path):
    with open(path, "rb") as f:
        raw = f.read()
    pos = 8
    width = height = color_type = 0
    idats = []
    while pos < len(raw):
        n = struct.unpack(">I", raw[pos:pos+4])[0]
        t = raw[pos+4:pos+8]
        d = raw[pos+8:pos+8+n]
        if t == b"IHDR":
            width, height = struct.unpack(">II", d[:8])
            color_type = d[9]
        elif t == b"IDAT":
            idats.append(d)
        elif t == b"IEND":
            break
        pos += 12 + n
    channels = 4 if color_type == 6 else 3
    unfiltered = zlib.decompress(b"".join(idats))
    stride = 1 + width * channels
    rows = []
    for y in range(height):
        base = y * stride
        filt = unfiltered[base]
        row = bytearray(unfiltered[base+1 : base+1+width*channels])
        # Apply the per-row PNG filter
        if filt == 1:   # Sub
            for i in range(channels, len(row)):
                row[i] = (row[i] + row[i-channels]) & 0xFF
        elif filt == 2: # Up
            if y > 0:
                prev = rows[y-1]
                for i in range(len(row)):
                    row[i] = (row[i] + prev[i]) & 0xFF
        elif filt == 3: # Average
            prev = rows[y-1] if y > 0 else bytearray(len(row))
            for i in range(len(row)):
                a = row[i-channels] if i >= channels else 0
                row[i] = (row[i] + (a + prev[i]) // 2) & 0xFF
        elif filt == 4: # Paeth
            prev = rows[y-1] if y > 0 else bytearray(len(row))
            for i in range(len(row)):
                a = row[i-channels] if i >= channels else 0
                b2 = prev[i]
                c = prev[i-channels] if i >= channels else 0
                p = a + b2 - c
                pa, pb, pc = abs(p-a), abs(p-b2), abs(p-c)
                pr2 = a if pa <= pb and pa <= pc else (b2 if pb <= pc else c)
                row[i] = (row[i] + pr2) & 0xFF
        rows.append(row)
    return rows, width, height, channels

rows, width, height, channels = png_read(src)

# Hue rotation
out_rows = []
for row in rows:
    out_row = bytearray(len(row))
    for x in range(width):
        i = x * channels
        pr, pg, pb = row[i], row[i+1], row[i+2]
        pa = row[i+3] if channels == 4 else 255
        h, s, v = colorsys.rgb_to_hsv(pr/255, pg/255, pb/255)
        # Preserve near-neutral zones (low saturation)
        if s > 0.12 and v > 0.05:
            h = target_h
            # Blend saturation toward target, weighted by original saturation
            s = s * 0.3 + target_s * 0.7
        nr, ng, nb = colorsys.hsv_to_rgb(h, s, v)
        out_row[i]   = round(nr * 255)
        out_row[i+1] = round(ng * 255)
        out_row[i+2] = round(nb * 255)
        if channels == 4:
            out_row[i+3] = pa
    out_rows.append(out_row)

# PNG writer
def png_write(path, rows, width, height, channels):
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)

    ct = 6 if channels == 4 else 2
    ihdr = struct.pack(">IIBBBBB", width, height, 8, ct, 0, 0, 0)
    raw = b""
    for row in rows:
        raw += b"\x00" + bytes(row)
    idat = zlib.compress(raw, 9)

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", ihdr))
        f.write(chunk(b"IDAT", idat))
        f.write(chunk(b"IEND", b""))

png_write(dst, out_rows, width, height, channels)
print(f"tint OK target_h={target_h:.3f}", flush=True)
TINTEOF

[[ ! -f "$TINTED_PNG" ]] && { echo "Tint failed — copying base PNG"; cp "$BASE_PNG" "$TINTED_PNG"; }


# ── 4) Build .icns (overwrites the bundle's original icons) ─────────────────
ICONSET="$TMPDIR_WORK/clone.iconset"
mkdir -p "$ICONSET"
for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
            "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
            "512:icon_256x256@2x" "512:icon_512x512"; do
  sz="${spec%%:*}"; name="${spec##*:}"
  sips -z "$sz" "$sz" "$TINTED_PNG" --out "$ICONSET/${name}.png" >/dev/null 2>&1 || true
done
cp "$TINTED_PNG" "$ICONSET/icon_512x512@2x.png" 2>/dev/null || true
iconutil -c icns "$ICONSET" -o "$TMPDIR_WORK/AppIcon.icns"

# Overwrite every existing .icns in the bundle with the tinted version —
# we don't know the exact name declared in the cloned Info.plist, so we
# replace them all to be safe.
for existing in "$RES"/*.icns(N); do
  cp "$TMPDIR_WORK/AppIcon.icns" "$existing"
done
cp "$TMPDIR_WORK/AppIcon.icns" "$RES/AppIcon.icns"
echo "icns OK"


# ── 5) Info.plist — edit in place (keep original CFBundleExecutable) ────────
# The cloned bundle already has the source app's Info.plist. We don't rewrite
# it from scratch (that would break Electron/Chromium-specific keys like
# LSEnvironment, NSPrincipalClass, etc.) — only patch what we need.
UNIQUE_ID="fr.b519hs.clone.$(date +%s)"
PLIST="$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${UNIQUE_ID}"      "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string ${UNIQUE_ID}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${safe_name}"            "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleName string ${safe_name}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${safe_name}"     "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string ${safe_name}" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon"             "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$PLIST"
/usr/libexec/PlistBuddy -c "Delete :CFBundleIconName"                  "$PLIST" 2>/dev/null || true
echo "Info.plist patched: id=${UNIQUE_ID}"


# ── 6) OPEN_ARG wrapper (optional) ──────────────────────────────────────────
# If the user picked a file/folder to open, insert a thin zsh wrapper in front
# of the real binary. Otherwise leave the bundle as-is.
if [[ -n "$OPEN_ARG" ]]; then
  SRC_EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$PLIST" 2>/dev/null)"
  REAL_EXE="$MACOS/$SRC_EXE_NAME"
  if [[ -f "$REAL_EXE" ]]; then
    mv "$REAL_EXE" "$REAL_EXE.real"
    cat > "$REAL_EXE" <<WRAPEOF
#!/bin/zsh
exec "\${0}.real" "$OPEN_ARG" "\$@"
WRAPEOF
    chmod +x "$REAL_EXE"
    echo "WRAPPER with OPEN_ARG=$OPEN_ARG"
  fi
fi

cat > "$RES/config.sh" <<CONF
SOURCE_APP="$SOURCE_APP"
OPEN_ARG="$OPEN_ARG"
CONF


# ── 7) Bottom-up ad-hoc re-sign ─────────────────────────────────────────────
# Electron apps (VSCode, Slack, etc.) ship with hardened runtime + notarized
# signatures on every nested helper/framework. Modifying Info.plist invalidates
# the main bundle's sealed-resources manifest, so macOS refuses to launch it
# (crash "quit unexpectedly", Dock shows "?"). `codesign --deep --sign -` is
# unreliable here: it often skips nested Mach-O binaries buried in frameworks.
#
# We re-sign manually bottom-up: dylibs → nested frameworks → nested .app
# bundles (deepest first) → main bundle. `--preserve-metadata=...` keeps each
# component's original entitlements + hardened-runtime flag, which is what
# allows Electron's JIT + V8 to keep working after re-sign.
# Single unified log for the whole clone operation — everything goes into
# /tmp/clone_diag.log so the user only has to cat one file.
DIAG=/tmp/clone_diag.log
SIGN_LOG="$DIAG"
: > "$DIAG"
echo "============================================================" >> "$DIAG"
echo "=== AppCloner — $(date)"                                     >> "$DIAG"
echo "=== Clone: $DEST"                                            >> "$DIAG"
echo "============================================================" >> "$DIAG"
echo "" >> "$DIAG"
echo "── Signing pass ────────────────────────────────────────────" >> "$DIAG"
echo "Re-signing bottom-up (ad-hoc)… (details in $DIAG)"

# Extract the ORIGINAL entitlements from each key executable of the source app
# and stash them as plist files. Relying on `--preserve-metadata=entitlements`
# is unreliable here: it silently drops entitlements when the prior signature
# was stripped by `codesign --force`, or when certain flags combine. Explicit
# --entitlements <file> always wins.
#
# The critical one for Electron is `com.apple.security.cs.disable-library-
# validation` — without it, hardened runtime rejects every ad-hoc dylib with
# "different Team IDs" and the process dies at dyld map time.
ENT_MAIN="$TMPDIR_WORK/entitlements_main.plist"
SRC_MAIN_EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "")"
SRC_MAIN_EXE="$SOURCE_APP/Contents/MacOS/$SRC_MAIN_EXE_NAME"
if [[ -n "$SRC_MAIN_EXE_NAME" && -f "$SRC_MAIN_EXE" ]]; then
  # IMPORTANT: on macOS 12+, `codesign -d --entitlements :-` emits a binary
  # blob (magic 0xfade7171 + length + XML), not plain XML. Passing that blob
  # to `codesign --entitlements` silently ignores it. The `--xml` flag forces
  # plain-XML output, which codesign can then apply correctly at re-sign time.
  codesign -d --entitlements :- --xml "$SRC_MAIN_EXE" > "$ENT_MAIN" 2>/dev/null || true
  # Fallback: older codesign doesn't support --xml. Strip the 8-byte magic
  # header manually if the extraction started with 0xfade7171.
  if [[ -s "$ENT_MAIN" ]] && head -c 4 "$ENT_MAIN" | xxd -p 2>/dev/null | grep -qi "fade7171"; then
    echo "  → Detected binary blob header; stripping 8-byte prefix"          >> "$DIAG"
    tail -c +9 "$ENT_MAIN" > "$ENT_MAIN.clean" && mv "$ENT_MAIN.clean" "$ENT_MAIN"
  fi
  # Validate with plutil — if the output isn't a valid plist, codesign will
  # silently drop it again. plutil -lint tells us up front.
  if [[ -s "$ENT_MAIN" ]] && plutil -lint "$ENT_MAIN" >/dev/null 2>&1; then
    echo "Extracted main entitlements ($(wc -c < "$ENT_MAIN") bytes, valid plist)" >> "$DIAG"
    # Source apps like VSCode ship WITHOUT disable-library-validation —
    # their original sig has a real Apple team-id shared with every nested
    # dylib, so Library Validation passes naturally. After we re-sign the
    # clone ad-hoc with a different bundle ID, the nested dylibs become
    # "different team" and dyld refuses to load them. We must inject
    # disable-library-validation into the entitlements so hardened runtime
    # skips the LV check for this process. Same for allow-unsigned-executable
    # -memory (required for ad-hoc + hardened runtime + JIT).
    if ! grep -q "disable-library-validation" "$ENT_MAIN"; then
      echo "  → Injecting disable-library-validation (required for ad-hoc)"   >> "$DIAG"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENT_MAIN" 2>/dev/null
    fi
    if ! grep -q "allow-unsigned-executable-memory" "$ENT_MAIN"; then
      echo "  → Injecting allow-unsigned-executable-memory"                   >> "$DIAG"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.allow-unsigned-executable-memory bool true" "$ENT_MAIN" 2>/dev/null
    fi
    if ! grep -q "allow-dyld-environment-variables" "$ENT_MAIN"; then
      echo "  → Injecting allow-dyld-environment-variables"                   >> "$DIAG"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.allow-dyld-environment-variables bool true" "$ENT_MAIN" 2>/dev/null
    fi
    if ! grep -q "disable-executable-page-protection" "$ENT_MAIN"; then
      echo "  → Injecting disable-executable-page-protection"                 >> "$DIAG"
      /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-executable-page-protection bool true" "$ENT_MAIN" 2>/dev/null
    fi
    echo "  ✓ Final entitlements after injection:"                            >> "$DIAG"
    grep -E "security\.cs\." "$ENT_MAIN"                                      >> "$DIAG"
  else
    echo "WARNING: entitlements plist from $SRC_MAIN_EXE is invalid or empty" >> "$DIAG"
    # Last resort: synthesize a minimal plist that has exactly what we need.
    # Electron requires allow-jit, allow-unsigned-executable-memory, and
    # disable-library-validation to load ad-hoc-signed dylibs under hardened
    # runtime. This fallback guarantees the clone still launches even when
    # the source entitlement extraction fails.
    cat > "$ENT_MAIN" <<'ENTFALLBACK'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.cs.allow-jit</key><true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>
    <key>com.apple.security.cs.disable-library-validation</key><true/>
    <key>com.apple.security.cs.allow-dyld-environment-variables</key><true/>
    <key>com.apple.security.cs.disable-executable-page-protection</key><true/>
</dict>
</plist>
ENTFALLBACK
    echo "  → Wrote fallback entitlements plist"                              >> "$DIAG"
  fi
fi

# Function: ad-hoc sign a Mach-O, deliberately WITHOUT the hardened-runtime
# flag. Reason: the source binary has hardened runtime + Library Validation
# on, and VSCode's original disable-library-validation entitlement is only
# meaningful under the *original* team signature. After we clone and re-sign
# ad-hoc, every dylib (Electron Framework, Code Helper helpers) carries its
# own original bundle identifier as its effective team-id — the main exe sees
# those as "different team IDs" and LV kills the process at dyld map time.
#
# Dropping `--options runtime` on the main binary disables Library Validation
# entirely for that process: macOS no longer cares whether loaded dylibs
# share a team-id with the loader, which is exactly what we need for a
# re-signed Electron bundle. JIT / allow-unsigned-memory still work because
# those are only restricted UNDER hardened runtime — without it, the process
# is fully permissive. Security posture on a local clone is unchanged
# relative to "running VSCode source directly".
sign_macho_without_runtime() {
  local target="$1"
  echo ">> sign_macho_without_runtime: $target" >> "$SIGN_LOG"
  codesign --force --sign - "$target" >> "$SIGN_LOG" 2>&1 || true
}

sign_macho_with_runtime_and_entitlements() {
  # V8 in recent Electron (30+) requires hardened runtime to be present at
  # process startup — without it, OptimizingCompileTaskExecutor's init hits
  # brk 0 (IMMEDIATE_CRASH) when setting up JIT thread pools. So we need:
  #   --options runtime          : turn hardened runtime back on
  #   --entitlements <plist>     : carry forward disable-library-validation
  #                                (lets ad-hoc dylibs with mismatched team
  #                                IDs load anyway) and allow-jit + friends.
  local target="$1"
  local ent="$2"
  echo ">> sign_macho_with_runtime: $target (ent=$ent)" >> "$SIGN_LOG"
  if [[ -s "$ent" ]]; then
    codesign --force --sign - --options runtime \
             --entitlements "$ent" "$target" >> "$SIGN_LOG" 2>&1 \
      || codesign --force --sign - --options runtime "$target" >> "$SIGN_LOG" 2>&1 \
      || codesign --force --sign - "$target" >> "$SIGN_LOG" 2>&1 || true
  else
    codesign --force --sign - --options runtime "$target" >> "$SIGN_LOG" 2>&1 \
      || codesign --force --sign - "$target" >> "$SIGN_LOG" 2>&1 || true
  fi
}

PRESERVE="--preserve-metadata=entitlements,requirements,flags,runtime"

# Strip quarantine + resource forks on every file so Gatekeeper doesn't flag
# the clone as "downloaded". `xattr -r` isn't available in Apple's xattr, so
# fan out via find. Run before signing — xattr changes don't invalidate seals,
# but it's cleaner to do it first.
find "$DEST" -exec xattr -c {} + 2>/dev/null || true

# Standalone Mach-O files directly in Contents/MacOS (e.g. "Code.real" created
# by the OPEN_ARG wrapper). These sit outside any sub-bundle so no parent seals
# them — they need their own signature pointing at the patched Info.plist hash.
#
# Critical: keep the original entitlements, especially
# `com.apple.security.cs.disable-library-validation`. Without it, hardened
# runtime enforces Library Validation and refuses to load our ad-hoc-signed
# dylibs (no team-id match) — Electron exits instantly with SIGKILL.
find "$DEST/Contents/MacOS" -type f -perm +111 2>/dev/null \
  | while IFS= read -r f; do
      # Mach-O binaries (e.g. Code.real) need the source app's entitlements to
      # pass Library Validation. Shell scripts (our wrapper) don't take them.
      if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        # Code.real needs hardened runtime + entitlements for V8 to init
        sign_macho_with_runtime_and_entitlements "$f" "$ENT_MAIN"
      else
        codesign --force --sign - "$f" 2>/dev/null || true
      fi
    done

# Nested .framework bundles — deepest first, with --deep so every dylib/helper
# inside is re-sealed atomically. `--deep` is reliable *within* a framework
# (bounded scope, no races); it's only unreliable when applied to the whole
# app tree. Parallelism across frameworks would race on shared inodes from
# the APFS clone, so we go serial here.
# Pre-sign Mach-O files that live inside frameworks at depths beyond what
# `--deep` reliably walks. chrome_crashpad_handler (in Electron Framework's
# Helpers/) is the chronic offender: --deep on the framework skips it and the
# framework's outer seal then fails with "file modified: chrome_crashpad_handler".
find "$DEST" -type f -path "*/Frameworks/*" -perm +111 2>/dev/null \
  | while IFS= read -r f; do
      # Only actual Mach-O executables — skip scripts, text, etc.
      if file -b "$f" 2>/dev/null | grep -q "Mach-O"; then
        echo ">> pre-sign mach-o in framework: $f" >> "$SIGN_LOG"
        codesign --force --sign - "$f" >> "$SIGN_LOG" 2>&1 || true
      fi
    done

find "$DEST" -depth -type d -name "*.framework" 2>/dev/null \
  | while IFS= read -r fw; do
      echo ">> sign framework: $fw" >> "$SIGN_LOG"
      codesign --force --deep --sign - $PRESERVE "$fw" >> "$SIGN_LOG" 2>&1 \
        || codesign --force --deep --sign - "$fw" >> "$SIGN_LOG" 2>&1 || true
    done

# Nested .app bundles (helpers, renderer processes) — deepest first, skip root
find "$DEST" -depth -type d -name "*.app" 2>/dev/null \
  | while IFS= read -r nested; do
      [[ "$nested" == "$DEST" ]] && continue
      echo ">> sign nested .app: $nested" >> "$SIGN_LOG"
      codesign --force --deep --sign - $PRESERVE "$nested" >> "$SIGN_LOG" 2>&1 \
        || codesign --force --deep --sign - "$nested" >> "$SIGN_LOG" 2>&1 || true
    done

# Main bundle last — preserves VSCode's hardened-runtime entitlement so Electron
# can still allocate JIT pages under ad-hoc signature
echo ">> sign main bundle: $DEST" >> "$SIGN_LOG"
codesign --force --sign - $PRESERVE "$DEST" >> "$SIGN_LOG" 2>&1 || true

# Verify
if codesign --verify --deep --strict "$DEST" 2>&1 | tail -3; then
  echo "Signature OK"
else
  echo "Signature verify reported issues (may still launch — see log above)"
fi


# ── 8) Dock ─────────────────────────────────────────────────────────────────
touch "$DEST"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f "$DEST" >/dev/null 2>&1 || true

# Edit the Dock plist directly, then lsregister + killall Dock so the Dock
# picks up the correct icon.
python3 - "$DEST" <<'DOCKEOF'
import sys, plistlib, os, subprocess, time

app_path   = sys.argv[1]
plist_path = os.path.expanduser("~/Library/Preferences/com.apple.dock.plist")
lsr        = ("/System/Library/Frameworks/CoreServices.framework"
              "/Frameworks/LaunchServices.framework/Support/lsregister")

with open(plist_path, 'rb') as f:
    dock = plistlib.load(f)

apps = dock.get('persistent-apps', [])
url  = app_path.rstrip('/') + '/'

for e in apps:
    if e.get('tile-data', {}).get('file-data', {}).get('_CFURLString', '') == url:
        print("Already in Dock")
        sys.exit(0)

label = os.path.basename(app_path).removesuffix('.app')
apps.append({
    'GUID': int.from_bytes(os.urandom(4), 'big'),
    'tile-data': {
        'file-data': {'_CFURLString': url, '_CFURLStringType': 15},
        'file-label': label,
        'file-type': 41,
        'parent-mod-date': 0,
    },
    'tile-type': 'file-tile',
})
dock['persistent-apps'] = apps

with open(plist_path, 'wb') as f:
    plistlib.dump(dock, f)

# Force LaunchServices to fully re-index the bundle: unregister, register,
# register again with recursion, then restart Dock. Single `lsregister -f`
# followed by immediate `killall Dock` races in real-world usage — Dock reads
# its cache before LS has finished indexing and displays the "?" placeholder.
subprocess.run([lsr, '-u', app_path], capture_output=True)
subprocess.run([lsr, '-f', '-r', app_path], capture_output=True)
time.sleep(3)
subprocess.run(['killall', 'Dock'], check=False)
time.sleep(2)
# Second killall after Dock has started regenerating its cache from LS —
# ensures it picks up the freshly-registered bundle instead of any stale
# snapshot it had just before the first kill
subprocess.run([lsr, '-f', app_path], capture_output=True)
subprocess.run(['killall', 'Dock'], check=False)
print(f"Added to Dock: {app_path}")
DOCKEOF


# ── 9) Auto-diagnostic launch ───────────────────────────────────────────────
# Everything so far (signing + extraction) has already been appended to $DIAG.
# Here we add post-signing checks + a test launch into the same single file.
{
  echo ""
  echo "============================================================"
  echo "=== Post-signing diagnostic — $(date)"
  echo "============================================================"

  # Snapshot the DiagnosticReports directory BEFORE launch so we can tell
  # which crash reports are new
  DR_DIR="$HOME/Library/Logs/DiagnosticReports"
  PRE_SNAPSHOT=$(mktemp)
  ls -1 "$DR_DIR" 2>/dev/null > "$PRE_SNAPSHOT" || true

  echo ""
  echo "── codesign -dv ────────────────────────────────────────────"
  codesign -dv --verbose=4 "$DEST" 2>&1 || true

  echo ""
  echo "── codesign --verify --deep --strict ───────────────────────"
  codesign --verify --deep --strict --verbose=2 "$DEST" 2>&1 || true

  echo ""
  echo "── spctl -a -vv ────────────────────────────────────────────"
  spctl -a -vv "$DEST" 2>&1 || true

  echo ""
  echo "── xattr -l ────────────────────────────────────────────────"
  xattr -l "$DEST" 2>&1 || true

  echo ""
  echo "── Per-nested-bundle verify (to pinpoint 'file modified') ──"
  for sub in \
      "$DEST/Contents/Frameworks/Electron Framework.framework" \
      "$DEST/Contents/Frameworks/Code Helper.app" \
      "$DEST/Contents/Frameworks/Code Helper (Renderer).app" \
      "$DEST/Contents/Frameworks/Code Helper (GPU).app" \
      "$DEST/Contents/Frameworks/Code Helper (Plugin).app" \
      "$DEST/Contents/Frameworks/Mantle.framework" \
      "$DEST/Contents/Frameworks/Squirrel.framework" \
      "$DEST/Contents/Frameworks/ReactiveObjC.framework"; do
    [[ ! -e "$sub" ]] && continue
    echo ""
    echo "-- $sub --"
    codesign --verify --verbose=4 "$sub" 2>&1 | head -10 || true
  done

  echo ""
  echo "── Entitlements effectively present on Code.real ───────────"
  CODE_REAL="$MACOS/Code.real"
  [[ ! -f "$CODE_REAL" ]] && CODE_REAL="$MACOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$CONTENTS/Info.plist" 2>/dev/null)"
  codesign -d --entitlements :- --xml "$CODE_REAL" 2>&1 | head -50 || true
  echo ""
  echo "── CS flags on main binary ─────────────────────────────────"
  codesign -dvv "$CODE_REAL" 2>&1 | grep -iE "flag|runtime|entitl|CDHash|Identifier" || true

  echo ""
  echo "── LaunchServices registration check ───────────────────────"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -dump 2>/dev/null | grep -B 2 -A 5 "$(basename "$DEST")" | head -40 || true

  echo ""
  echo "── Spotlight metadata ──────────────────────────────────────"
  mdls -name kMDItemContentType -name kMDItemDisplayName -name kMDItemKind "$DEST" 2>&1 || true

  echo ""
  echo "── Test launch (direct exec) ───────────────────────────────"
  # Run the actual CFBundleExecutable directly so stderr is captured. Timeout
  # after 5 s — if it survives that, it's not crashing on direct exec.
  MAIN_EXE_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$CONTENTS/Info.plist" 2>/dev/null || echo "")"
  MAIN_EXE="$MACOS/$MAIN_EXE_NAME"
  echo "Executing: $MAIN_EXE"
  (
    "$MAIN_EXE" 2>&1 &
    LAUNCH_PID=$!
    sleep 5
    if kill -0 "$LAUNCH_PID" 2>/dev/null; then
      echo ""
      echo "── Still alive after 5 s — killing ───────────────────────"
      kill "$LAUNCH_PID" 2>/dev/null || true
      sleep 1
      kill -9 "$LAUNCH_PID" 2>/dev/null || true
      echo "DIRECT_EXEC_RESULT=alive"
    else
      wait "$LAUNCH_PID" 2>/dev/null
      echo ""
      echo "DIRECT_EXEC_RESULT=exited (exit_code=$?)"
    fi
  ) 2>&1 | head -200

  echo ""
  echo "── Test launch via LaunchServices (what Dock does) ─────────"
  # Kill any prior instance first
  pkill -f "$(basename "$DEST")" 2>/dev/null || true
  sleep 1
  # `open` uses LS — same code path as Dock click. Captures LS refusal reason.
  open_out="$(open "$DEST" 2>&1)"
  open_rc=$?
  echo "open exit code: $open_rc"
  echo "open output: $open_out"
  sleep 4
  if pgrep -f "$DEST/Contents/MacOS" >/dev/null; then
    echo "LS_LAUNCH_RESULT=alive"
    pkill -f "$DEST/Contents/MacOS" 2>/dev/null || true
  else
    echo "LS_LAUNCH_RESULT=not_running"
  fi

  echo ""
  echo "── New crash reports since launch ──────────────────────────"
  # Wait for ReportCrash to write the .ips file (can lag by a few seconds)
  sleep 3
  NEW_REPORTS=$(comm -13 <(sort "$PRE_SNAPSHOT") <(ls -1 "$DR_DIR" 2>/dev/null | sort))
  rm -f "$PRE_SNAPSHOT"
  if [[ -z "$NEW_REPORTS" ]]; then
    echo "(no new crash reports)"
  else
    echo "$NEW_REPORTS" | while IFS= read -r report; do
      echo ""
      echo "── REPORT: $report ──────────────────────────────────────"
      head -150 "$DR_DIR/$report" 2>/dev/null || true
    done
  fi

  echo ""
  echo "── Top 10 entitlements preserved on Code.real ──────────────"
  codesign -d --entitlements :- "$MACOS/Code.real" 2>/dev/null | head -40 || true

  echo ""
  echo "=== End of diagnostic ==="
} >> "$DIAG" 2>&1

echo ""
echo "Diagnostic written to $DIAG"
echo "$DEST"
