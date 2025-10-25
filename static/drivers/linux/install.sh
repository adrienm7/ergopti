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
if command -v svn >/dev/null 2>&1; then
  echo "svn detected — exporting only ${TARGET_DIR} from repository (lighter download)"
  if svn export --force "$SVN_URL" "$TARGET_DIR" >/dev/null 2>&1; then
    echo "Exported $TARGET_DIR via svn"
    DOWNLOADED_VIA_SVN=1
  else
    echo "svn export failed, falling back to full zip archive download"
    if ! curl -fsSL -o "$ZIPNAME" "$REPO_ZIP_URL"; then
      echo "Failed to download repository archive."
      rm -rf "$TMPDIR"
      exit 1
    fi
    DOWNLOADED_VIA_SVN=0
  fi
else
  if ! curl -fsSL -o "$ZIPNAME" "$REPO_ZIP_URL"; then
    echo "Failed to download repository archive."
    rm -rf "$TMPDIR"
    exit 1
  fi
fi

if [ "${DOWNLOADED_VIA_SVN:-0}" = "1" ]; then
  echo "Using files exported via svn"
  EXTRACTED_DIR="$TMPDIR/$TARGET_DIR"
else
  echo "Extracting $TARGET_DIR from archive..."
  if ! unzip -q "$ZIPNAME" "${REPO_NAME}-${BRANCH}/${TARGET_DIR}/*" -d .; then
    echo "Failed to extract files."
    rm -rf "$TMPDIR"
    exit 1
  fi

  EXTRACTED_DIR="${TMPDIR}/${REPO_NAME}-${BRANCH}/${TARGET_DIR}"
fi
if [ ! -d "$EXTRACTED_DIR" ]; then
  echo "Expected directory not found in archive: $EXTRACTED_DIR"
  rm -rf "$TMPDIR"
  exit 1
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
