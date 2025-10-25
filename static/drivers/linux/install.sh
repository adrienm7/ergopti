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
python3 "$SCRIPT" "$@"

RET=$?
echo "Cleaning up..."
rm -rf "$TMPDIR"

if [ $RET -eq 0 ]; then
  echo "Installer finished successfully."
else
  echo "Installer exited with code $RET"
fi

exit $RET
