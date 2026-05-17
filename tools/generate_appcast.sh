#!/usr/bin/env bash
# tools/generate_appcast.sh
#
# ==============================================================================
# SCRIPT: Sparkle appcast generator
# DESCRIPTION:
# Emits a minimal Sparkle-compatible appcast XML file that tells Sparkle where
# to download the next release and how to verify it. Called by release.yml
# after the zip has been signed with sign_update.
#
# All inputs are read from environment variables so the script is usable both
# from CI and from a maintainer's terminal without argument juggling.
#
# REQUIRED ENV VARS:
#   ERGOPTI_VERSION  — semver string, e.g. "1.2.3"
#   ERGOPTI_BUILD    — integer build number (CFBundleVersion in Info.plist)
#   ERGOPTI_CHANNEL  — "main" or "dev"
#   SPARKLE_SIG_FILE — path to the .sig file written by sign_update
#   ZIP_PATH         — path to Ergopti.app.zip
#   GH_OWNER         — GitHub organisation / user name
#   GH_REPO          — GitHub repository name
#   OUTPUT_PATH      — where to write the finished appcast-{channel}.xml
# ==============================================================================

set -euo pipefail

: "${ERGOPTI_VERSION:?Required: ERGOPTI_VERSION}"
: "${ERGOPTI_BUILD:?Required: ERGOPTI_BUILD}"
: "${ERGOPTI_CHANNEL:?Required: ERGOPTI_CHANNEL}"
: "${SPARKLE_SIG_FILE:?Required: SPARKLE_SIG_FILE}"
: "${ZIP_PATH:?Required: ZIP_PATH}"
: "${GH_OWNER:?Required: GH_OWNER}"
: "${GH_REPO:?Required: GH_REPO}"
: "${OUTPUT_PATH:?Required: OUTPUT_PATH}"

TAG="v${ERGOPTI_VERSION}"
ZIP_URL="https://github.com/${GH_OWNER}/${GH_REPO}/releases/download/${TAG}/Ergopti.app.zip"
ZIP_SIZE="$(wc -c < "${ZIP_PATH}" | tr -d ' ')"
SIG="$(cat "${SPARKLE_SIG_FILE}")"
PUB_DATE="$(date -R)"

cat > "${OUTPUT_PATH}" << EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"
     xmlns:sparkle="http://www.andymattes.com/xml/namespaces/sparkle/1.0"
     xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Ergopti</title>
    <link>https://github.com/${GH_OWNER}/${GH_REPO}</link>
    <item>
      <title>Ergopti ${ERGOPTI_VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${ERGOPTI_BUILD}</sparkle:version>
      <sparkle:shortVersionString>${ERGOPTI_VERSION}</sparkle:shortVersionString>
      <enclosure
        url="${ZIP_URL}"
        sparkle:edSignature="${SIG}"
        length="${ZIP_SIZE}"
        type="application/octet-stream"
      />
    </item>
  </channel>
</rss>
EOF

echo "[appcast] ${OUTPUT_PATH} — channel=${ERGOPTI_CHANNEL} version=${ERGOPTI_VERSION} size=${ZIP_SIZE}"
