#!/usr/bin/env bash
# tools/generate_appcast.sh
#
# ==============================================================================
# SCRIPT: Sparkle appcast generator
# DESCRIPTION:
# Emits a minimal Sparkle-compatible appcast XML file that tells Sparkle where
# to download the next release and how to verify it. Called by release.yml
# after the selected archive has been signed and verified with sign_update.
#
# All inputs are read from environment variables so the script is usable both
# from CI and from a maintainer's terminal without argument juggling.
#
# REQUIRED ENV VARS:
#   ERGOPTI_VERSION  — semver string, e.g. "1.2.3"
#   ERGOPTI_BUILD    — integer build number (CFBundleVersion in Info.plist)
#   ERGOPTI_CHANNEL  — update channel id (_shared/modules/updater/channels.json)
#   SPARKLE_SIG_FILE — path to the .sig file written by sign_update
#   ARCHIVE_DIR      — fresh signed archives and their publication receipt
#   ZIP_PATH         — explicit historical ZIP input (without ARCHIVE_DIR)
#   GH_OWNER         — GitHub organisation / user name
#   GH_REPO          — GitHub repository name
#   OUTPUT_PATH      — where to write the finished appcast-{channel}.xml
# ==============================================================================

set -euo pipefail

# Fresh CI uses the exact publication signing receipt; explicit historical ZIP
# callers keep their strict fragment/length contract in the same owning helper.
node "$(dirname "$0")/macos-release-publication.cjs" appcast
