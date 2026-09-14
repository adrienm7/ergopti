#!/usr/bin/env bash
# tools/build/bundle-macos-luasocket.sh
# Bundle the real synchronous boot transport required before the event loop starts.
set -euo pipefail

app="${1:?application bundle required}"
work="${2:?fresh dependency build directory required}"
test "$(uname -s)" = Darwin
test -d "$app/Contents/Frameworks/Hammerspoon.app"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Frameworks/Hammerspoon.app/Contents/Info.plist")" = 1.1.1
mkdir "$work"

# Hammerspoon 1.1.1 embeds Lua 5.4.7. Compile only the extension, never a second
# Lua runtime: all Lua symbols must resolve to the embedded interpreter.
curl --fail --silent --show-error --location --max-time 120 \
	https://www.lua.org/ftp/lua-5.4.7.tar.gz -o "$work/lua.tar.gz"
curl --fail --silent --show-error --location --max-time 120 \
	https://codeload.github.com/lunarmodules/luasocket/tar.gz/refs/tags/v3.1.0 -o "$work/luasocket.tar.gz"
printf '%s  %s\n' \
	9fbf5e28ef86c69858f6d3d34eccc32e911c1a28b4120ff3e84aaa70cfbf1e30 "$work/lua.tar.gz" \
	bf033aeb9e62bcaa8d007df68c119c966418e8c9ef7e4f2d7e96bddeca9cca6e "$work/luasocket.tar.gz" | shasum -a 256 --check
tar -xzf "$work/lua.tar.gz" -C "$work"
tar -xzf "$work/luasocket.tar.gz" -C "$work"

source_dir="$work/luasocket-3.1.0/src"
config="$app/Contents/Resources/static/ergopti_plus/macos"
test -f "$config/init.lua"
mkdir -p "$config/socket"
sources=()
for source in luasocket timeout buffer io auxiliar compat options inet usocket except select tcp udp; do
	sources+=("$source_dir/$source.c")
done
clang -O2 -bundle -undefined dynamic_lookup -arch arm64 -arch x86_64 \
	-mmacosx-version-min=13.0 -DLUASOCKET_NODEBUG -DUNIX_HAS_SUN_LEN \
	-I"$work/lua-5.4.7/src" "${sources[@]}" -o "$config/socket/core.so"
lipo "$config/socket/core.so" -verify_arch arm64 x86_64
cp "$source_dir/socket.lua" "$config/socket.lua"
cp "$work/luasocket-3.1.0/LICENSE" "$config/socket/LICENSE"
codesign --force --sign - "$config/socket/core.so"
codesign --verify --strict "$config/socket/core.so"
