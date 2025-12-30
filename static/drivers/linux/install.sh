#!/bin/sh

# Installer launcher for Ergopti:
# 1. Download the repository (git clone preferred, else zip)
# 2. Run the interactive XKB selector Python script from the downloaded repo
# 3. Install the XKB files selected (needs sudo, the script will prompt for it)

REPO_OWNER="adrienm7"
REPO_NAME="ergopti"
BRANCH="main"
TARGET_SUBPATH="static/drivers/linux"
SELECTOR_SCRIPT_NAME="xkb_files_selector"



# Check requirements
for cmd in python3 curl unzip fzf; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd is required but not installed. Please install it and retry."
    exit 1
  fi
done



# Create a secure temporary directory
# Prefer mktemp when available, otherwise fall back to a $$-based name
if command -v mktemp >/dev/null 2>&1; then
  TMPDIR="$(mktemp -d /tmp/ergopti_xkb.XXXXXX)" || TMPDIR="/tmp/ergopti_xkb_$$"
else
  TMPDIR="/tmp/ergopti_xkb_$$"
fi

mkdir -p "$TMPDIR" || exit 1
cd "$TMPDIR" || exit 1
trap 'rc=$?; rm -rf "$TMPDIR" >/dev/null 2>&1 || true; exit $rc' EXIT



# Prompt user for branch selection using fzf
echo "Fetching available branches from ${REPO_OWNER}/${REPO_NAME}..."
REPO_GIT_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"

# Get list of branches from remote repository
BRANCHES=$(git ls-remote --heads "$REPO_GIT_URL" 2>/dev/null | sed 's|.*refs/heads/||' | sort)

if [ -z "$BRANCHES" ]; then
	echo "Failed to fetch branches, using 'main' as default"
	BRANCH="main"
else
	# Use fzf to select branch, with main as default
	SELECTED_BRANCH=$(echo "$BRANCHES" | fzf --height=10 --prompt="Select branch: " --query="main" --select-1 --exit-0)
	
	if [ -n "$SELECTED_BRANCH" ]; then
		BRANCH="$SELECTED_BRANCH"
	else
		echo "No branch selected, using 'main' as default"
		BRANCH="main"
	fi
fi

echo "Using branch: $BRANCH"
echo ""



echo "Starting Ergopti installer: fetching repository ${REPO_OWNER}/${REPO_NAME}@${BRANCH}"
REPO_ZIP_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${BRANCH}.zip"
ZIPNAME="repo.zip"

# Try git sparse-checkout of the target subpath to avoid downloading the whole repository
# If it doesn’t work, fall back to a shallow full clone, or even to the zip archive
REPO_DIR="${TMPDIR}/${REPO_NAME}-${BRANCH}"REPO_GIT_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}.git"if command -v git >/dev/null 2>&1; then
  echo "Attempting git sparse-checkout of ${TARGET_SUBPATH} (lightweight)..."
  if git clone --depth 1 --no-checkout --filter=blob:none --branch "$BRANCH" "$REPO_GIT_URL" "$REPO_DIR" >/dev/null 2>&1; then
    # initialize sparse-checkout and set path
    if cd "$REPO_DIR" && git sparse-checkout init --cone >/dev/null 2>&1 && git sparse-checkout set "$TARGET_SUBPATH" >/dev/null 2>&1 && git checkout --quiet "$BRANCH" >/dev/null 2>&1; then
      echo "Sparse checkout of ${TARGET_SUBPATH} succeeded"
    else
      echo "Sparse-checkout not supported or failed; falling back to shallow clone"
      cd "$TMPDIR" || true
      rm -rf "$REPO_DIR"
      if git clone --depth 1 --branch "$BRANCH" "$REPO_GIT_URL" "$REPO_DIR" >/dev/null 2>&1; then
        echo "Repository cloned to $REPO_DIR"
      else
        echo "git clone failed; will try archive download"
        REPO_DIR=
      fi
    fi
  else
    echo "git clone (no-checkout) failed; will try archive download"
    REPO_DIR=
  fi
fi

# Fallback to zip archive when git not available or clone failed
if [ -z "${REPO_DIR}" ] || [ ! -d "$REPO_DIR" ]; then
  echo "Downloading archive..."
  if ! curl -C - --compressed -fsSL -o "$ZIPNAME" "$REPO_ZIP_URL"; then
    echo "Failed to download repository archive." >&2
    exit 1
  fi
  echo "Extracting archive..."
  if ! unzip -q "$ZIPNAME"; then
    echo "Failed to extract archive." >&2
    exit 1
  fi
  REPO_DIR="${TMPDIR}/${REPO_NAME}-${BRANCH}"
fi





# Launch the selector script from the downloaded repository
SELECTOR_PY="$REPO_DIR/${TARGET_SUBPATH}/$SELECTOR_SCRIPT_NAME.py"
if [ ! -f "$SELECTOR_PY" ]; then
  echo "Selector script not found: $SELECTOR_PY" >&2
  exit 1
fi

echo "Launching selector: $SELECTOR_PY"
python3 "$SELECTOR_PY" "$@"

RET=$?
echo "Done. Cleaning up..."
exit $RET
