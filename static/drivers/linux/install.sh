#!/bin/sh

# Minimal installer script for Ergopti XKB selector
# Downloads the repository archive (dev branch), extracts the Linux drivers
# folder and runs the interactive selector script.


REPO_OWNER="adrienm7"
REPO_NAME="ergopti"
BRANCH="dev"
TMPDIR="/tmp/ergopti_install_$$"
ZIPNAME="repo.zip"
TARGET_DIR="static/drivers/linux"

SELF_URL="https://raw.githubusercontent.com/adrienm7/ergopti/dev/static/drivers/linux/install.sh"

# Default cache settings
# Can be overridden with --cache-dir and --cache-ttl arguments
CACHE_TTL_DAYS=7
FORCE_DOWNLOAD=0
NO_CACHE=0

# Parse installer-specific options. Stop at '--' to leave remaining args for
# the downstream selector script.
while [ "$#" -gt 0 ]; do
  case "$1" in
    --force)
      FORCE_DOWNLOAD=1; shift;;
    --no-cache)
      NO_CACHE=1; FORCE_DOWNLOAD=1; shift;;
    --cache-ttl)
      CACHE_TTL_DAYS="$2"; shift 2;;
    --cache-dir)
      CACHE_DIR="$2"; shift 2;;
    --)
      shift; break;;
    *)
      break;;
  esac
done

# Remaining args ($@) will be forwarded to the selector script later

echo "Starting Ergopti XKB installer..."

# Ensure curl is present early so re-exec via sudo (when piped) works
if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required but not installed. Please install it and retry."
  exit 1
fi

# If not running as root, try to re-run the installer under sudo.
# When the script is piped (curl | sh), re-execing via sudo will re-download
# and run the installer securely as root. This preserves passed arguments.
if [ "$(id -u)" != "0" ]; then
  echo "Not running as root. Attempting to re-run the installer with sudo..."
  echo "If you prefer, run directly: curl -fsSL $SELF_URL | sudo sh -s -- [args]"
  # Re-run the installer under sudo by downloading it again inside the root shell.
  # $* expands to the original arguments (best-effort quoting for common cases).
  exec sudo sh -c "curl -fsSL '$SELF_URL' | sh -s -- $*"
  # If exec fails, exit with error
  echo "Failed to re-run installer with sudo."
  exit 1
fi

# From here on we are running as root
for cmd in unzip python3; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required but not installed. Please install it and retry."
    exit 1
  fi
done

mkdir -p "$TMPDIR" || exit 1
cd "$TMPDIR" || exit 1

REPO_ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.zip"
echo "Downloading repository archive from $REPO_ZIP_URL"
# Prefer to download only the linux subfolder using 'svn export' if available
# Use GitHub's Subversion bridge to export only the target folder
SVN_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/trunk/${TARGET_DIR}"

# Determine a cache directory. Prefer /var/cache when running as root and
# the original user's cache when available. Allow override via --cache-dir.
if [ -z "$CACHE_DIR" ]; then
  if [ "$(id -u)" -eq 0 ]; then
    # If invoked via sudo, try to use the invoking user's cache if possible
    if [ -n "$SUDO_USER" ]; then
      ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)
      if [ -n "$ORIG_HOME" ]; then
        CACHE_DIR="${XDG_CACHE_HOME:-$ORIG_HOME/.cache}/ergopti"
      else
        CACHE_DIR="/var/cache/ergopti"
      fi
    else
      CACHE_DIR="/var/cache/ergopti"
    fi
  else
    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/ergopti"
  fi
fi
mkdir -p "$CACHE_DIR" 2>/dev/null || CACHE_DIR="/tmp/ergopti_cache"
mkdir -p "$CACHE_DIR" 2>/dev/null || true

# Query remote commit SHA to use as a cache key. This avoids downloading
# again when the repository didn't change.
REMOTE_SHA=""
COMMITS_API="https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/commits/${BRANCH}"
echo "Querying remote commit id for ${REPO_OWNER}/${REPO_NAME}@${BRANCH}..."
if command -v curl >/dev/null 2>&1; then
  if command -v jq >/dev/null 2>&1; then
    REMOTE_SHA=$(curl -fsSL "$COMMITS_API" 2>/dev/null | jq -r .sha 2>/dev/null || true)
  else
    REMOTE_SHA=$(curl -fsSL "$COMMITS_API" 2>/dev/null | sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([a-f0-9]\{40\}\)".*/\1/p' | head -n1)
  fi
fi

# Cache file name contains repo, branch, target folder and remote sha (if known)
SAFE_TARGET=$(echo "$TARGET_DIR" | tr '/ ' '__')
SHA_PART=${REMOTE_SHA:-unknown}
CACHE_ARCHIVE="$CACHE_DIR/${REPO_NAME}-${BRANCH}-${SAFE_TARGET}-${SHA_PART}.tar.gz"

echo "Cache: $CACHE_DIR (commit=${SHA_PART})"

# If a cache matching the remote commit exists and the user did not force,
# use it directly (fast path).
SKIPPED_DOWNLOAD=0
if [ "$FORCE_DOWNLOAD" -ne 1 ] && [ "$NO_CACHE" -ne 1 ] && [ -f "$CACHE_ARCHIVE" ]; then
  echo "Using cached archive for commit $SHA_PART: $CACHE_ARCHIVE"
  tar -xzf "$CACHE_ARCHIVE" -C "$TMPDIR" 2>/dev/null || true
  EXTRACTED_DIR="$TMPDIR/$(basename "$TARGET_DIR")"
  if [ -d "$EXTRACTED_DIR" ]; then
    SKIPPED_DOWNLOAD=1
  else
    echo "Cached archive seems invalid; will re-download"
  fi
fi
if command -v svn >/dev/null 2>&1; then
  echo "svn detected — exporting only ${TARGET_DIR} from repository (lighter download)"
  if [ "$SKIPPED_DOWNLOAD" -eq 0 ]; then
    if svn export --force "$SVN_URL" "$TARGET_DIR" >/dev/null 2>&1; then
      echo "Exported $TARGET_DIR via svn"
      DOWNLOADED_VIA_SVN=1
    else
      echo "svn export failed, falling back to full zip archive download"
      # Try to resume and use compression; fallback will error if not available
      if ! curl -C - --compressed -fsSL -o "$ZIPNAME" "$REPO_ZIP_URL"; then
        echo "Failed to download repository archive."
        rm -rf "$TMPDIR"
        exit 1
      fi
      DOWNLOADED_VIA_SVN=0
    fi
  fi
else
  if [ "$SKIPPED_DOWNLOAD" -eq 0 ]; then
    if ! curl -C - --compressed -fsSL -o "$ZIPNAME" "$REPO_ZIP_URL"; then
      echo "Failed to download repository archive."
      rm -rf "$TMPDIR"
      exit 1
    fi
  fi
fi

if [ "${DOWNLOADED_VIA_SVN:-0}" = "1" ]; then
  echo "Using files exported via svn"
  EXTRACTED_DIR="$TMPDIR/$TARGET_DIR"
else
  if [ "$SKIPPED_DOWNLOAD" -eq 1 ]; then
    echo "Using files extracted from cache"
  else
    echo "Extracting $TARGET_DIR from archive..."
    if ! unzip -q "$ZIPNAME" "${REPO_NAME}-${BRANCH}/${TARGET_DIR}/*" -d .; then
      echo "Failed to extract files."
      rm -rf "$TMPDIR"
      exit 1
    fi
    EXTRACTED_DIR="${TMPDIR}/${REPO_NAME}-${BRANCH}/${TARGET_DIR}"
  fi
fi
if [ ! -d "$EXTRACTED_DIR" ]; then
  echo "Expected directory not found in archive: $EXTRACTED_DIR"
  rm -rf "$TMPDIR"
  exit 1
fi

# After a successful svn export or zip extraction, store a cache archive
if [ "$SKIPPED_DOWNLOAD" -eq 0 ] && [ "$NO_CACHE" -ne 1 ]; then
  # Create a compact tar.gz containing only the target folder basename so
  # future runs can extract it quickly.
  if [ -d "$EXTRACTED_DIR" ]; then
    PARENT_DIR=$(dirname "$EXTRACTED_DIR")
    BASE_NAME=$(basename "$EXTRACTED_DIR")
    if mkdir -p "$CACHE_DIR" 2>/dev/null; then
      echo "Updating cache: $CACHE_ARCHIVE"
      (cd "$PARENT_DIR" && tar -czf "$CACHE_ARCHIVE" "$BASE_NAME") 2>/dev/null || true
    fi
  fi
fi

SCRIPT="$EXTRACTED_DIR/xkb_files_selector.py"
if [ ! -f "$SCRIPT" ]; then
  echo "Installer script not found: $SCRIPT"
  rm -rf "$TMPDIR"
  exit 1
fi

echo "Running selector script: $SCRIPT"
# If the installer was invoked via sudo, try to forward the user's X11
# environment so setxkbmap / other X calls can open the display.
if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
  echo "Detected invoker user: $SUDO_USER — attempting to forward X11 env"
  # Resolve original user's home
  ORIG_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6 2>/dev/null || true)

  # Try to find DISPLAY and XAUTHORITY from one of the user's processes
  FOUND_DISPLAY=""
  FOUND_XAUTH=""
  for pid in $(pgrep -u "$SUDO_USER" 2>/dev/null || true); do
    if [ -r "/proc/$pid/environ" ]; then
      envvars=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null || true)
      if [ -z "$FOUND_DISPLAY" ]; then
        d=$(printf '%s' "$envvars" | awk -F= '/^DISPLAY=/ {print substr($0, index($0,$2)) ; exit}' )
        if [ -n "$d" ]; then
          FOUND_DISPLAY="$d"
        fi
      fi
      if [ -z "$FOUND_XAUTH" ]; then
        x=$(printf '%s' "$envvars" | awk -F= '/^XAUTHORITY=/ {print substr($0, index($0,$2)) ; exit}' )
        if [ -n "$x" ]; then
          FOUND_XAUTH="$x"
        fi
      fi
    fi
    if [ -n "$FOUND_DISPLAY" ] && [ -n "$FOUND_XAUTH" ]; then
      break
    fi
  done

  # Fallbacks
  if [ -z "$FOUND_DISPLAY" ]; then
    # Try common default
    FOUND_DISPLAY=":0"
  fi
  if [ -z "$FOUND_XAUTH" ]; then
    if [ -n "$ORIG_HOME" ] && [ -f "$ORIG_HOME/.Xauthority" ]; then
      FOUND_XAUTH="$ORIG_HOME/.Xauthority"
    fi
  fi

  if [ -n "$FOUND_DISPLAY" ]; then
    export DISPLAY="$FOUND_DISPLAY"
    echo "Using DISPLAY=$DISPLAY"
  fi
  if [ -n "$FOUND_XAUTH" ]; then
    export XAUTHORITY="$FOUND_XAUTH"
    echo "Using XAUTHORITY=$XAUTHORITY"
  else
    echo "Warning: could not locate XAUTHORITY for $SUDO_USER — X session operations may fail"
  fi
fi

# Run the selector. Running as root is required for system changes; the exported
# DISPLAY/XAUTHORITY above allow X calls to reach the user's X server when
# possible. We'll capture stderr and treat common X11 authorization/display
# messages as informational (non-fatal) to avoid alarming red errors.
SEL_STDERR="$TMPDIR/selector_stderr.txt"
rm -f "$SEL_STDERR" 2>/dev/null || true

python3 "$SCRIPT" "$@" 2>"$SEL_STDERR"
RET=$?

# Inspect stderr for common X authorization/display messages
if [ -s "$SEL_STDERR" ]; then
  # Patterns considered non-fatal and user-facing as informational
  X_PATTERNS="Authorization required|no authorization protocol|Cannot open display|No protocol specified"
  if grep -Ei "$X_PATTERNS" "$SEL_STDERR" >/dev/null 2>&1; then
    echo "Info: The installer couldn't apply the layout inside the user's X session automatically."
    echo "      This is non-fatal — the keyboard files were installed. To apply the layout manually, run as the logged-in user:"
    echo "        localectl set-x11-keymap fr <VARIANT>"
    echo "      or"
    echo "        DISPLAY=:0 setxkbmap fr -variant <VARIANT>"
    echo "      If you prefer the installer to attempt applying the layout later, re-run it from an active user session (not via sudo piping)."
    # remove the matched lines so we don't re-print them below
    grep -viE "$X_PATTERNS" "$SEL_STDERR" >"${SEL_STDERR}.filtered" || true
    mv "${SEL_STDERR}.filtered" "$SEL_STDERR" || true
  fi

  # Any remaining stderr lines (unexpected errors) should still be shown.
  if [ -s "$SEL_STDERR" ]; then
    echo "--- Additional output from selector (stderr) ---" >&2
    cat "$SEL_STDERR" >&2
    echo "--- end selector stderr ---" >&2
  fi
fi

echo "Cleaning up..."
rm -rf "$TMPDIR"

if [ $RET -eq 0 ]; then
  echo "Installer finished successfully."
else
  echo "Installer exited with code $RET"
fi

exit $RET
