#!/usr/bin/env bash
# static/ergopti_plus/linux/install/xkb_helpers.sh

# Ships the layout manager's XKB helpers with the installed driver: the
# conversion data (keysym table, symbols template, key types) and the user XKB
# installer with the two modules it imports. The daemon looks for them below
# the driver root (modules/keymap/layout_registry.lua converter_data_path and
# installer_path). The release tarball and every package already carry them
# below linux/ (tools/build/build-linux-driver.sh stages them with this file);
# a source checkout keeps them in static/ergopti/linux, outside the copied
# driver tree, so a checkout install used to fail every layout installation
# with "the XKB conversion data is not shipped with this driver".

# The folders below a driver root, the files the daemon reads in each, and the
# checkout folder they come from, relative to the folder holding the drivers.
XKB_HELPERS_DATA_FOLDER="xkb_generation/data"
XKB_HELPERS_INSTALLER_FOLDER="xkb_installation"
XKB_HELPERS_DATA_FILES=(key_sym.json xkb_symbols.txt xkb_types.txt)
XKB_HELPERS_INSTALLER_FILES=(user_layout_installer.py layout_package.py desktop_activation.py)
XKB_HELPERS_CHECKOUT_FOLDER="../ergopti/linux"

# The sentences this script prints, in the user's language (install/messages.sh).
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"

# Prints the checkout folder the installer copies the helpers from, or nothing
# when the driver source already carries them. Fails when neither layout has
# them: an installation without them can install no keyboard layout.
# @param $1 Driver source directory (the tarball's linux/ or the checkout's driver).
# @param $2 Folder holding the driver and _shared/ sources.
xkb_helpers_source() {
	local driver_source="$1"
	local drivers_root="$2"
	local checkout="${drivers_root}/${XKB_HELPERS_CHECKOUT_FOLDER}"

	if xkb_helpers_complete "${driver_source}"; then
		return 0
	fi
	if [ -f "${checkout}/xkb_generation/data/key_sym.json" ] \
		&& [ -f "${checkout}/xkb_installation/user_layout_installer.py" ]; then
		(cd -- "${checkout}" && pwd -P)
		return 0
	fi
	ergopti_msg xkb_helpers.not_found "${driver_source}" "${checkout}" >&2
	return 1
}

# Succeeds when a driver root holds every helper file the daemon reads.
# @param $1 Driver root.
xkb_helpers_complete() {
	local root="$1" name
	for name in "${XKB_HELPERS_DATA_FILES[@]}"; do
		[ -f "${root}/${XKB_HELPERS_DATA_FOLDER}/${name}" ] || return 1
	done
	for name in "${XKB_HELPERS_INSTALLER_FILES[@]}"; do
		[ -f "${root}/${XKB_HELPERS_INSTALLER_FOLDER}/${name}" ] || return 1
	done
	return 0
}

# Copies the helpers from a checkout folder below a driver root, exactly the
# files the daemon reads: the Python converter, the regeneration script, the
# system-wide installers and the tests stay behind.
# @param $1 Checkout folder (static/ergopti/linux).
# @param $2 Destination driver root.
stage_xkb_helpers() {
	local source="$1"
	local destination="$2"
	local name

	install -d "${destination}/${XKB_HELPERS_DATA_FOLDER}" "${destination}/${XKB_HELPERS_INSTALLER_FOLDER}" || return 1
	for name in "${XKB_HELPERS_DATA_FILES[@]}"; do
		install -m 644 "${source}/xkb_generation/data/${name}" "${destination}/${XKB_HELPERS_DATA_FOLDER}/${name}" || return 1
	done
	for name in "${XKB_HELPERS_INSTALLER_FILES[@]}"; do
		install -m 644 "${source}/xkb_installation/${name}" "${destination}/${XKB_HELPERS_INSTALLER_FOLDER}/${name}" || return 1
	done
}
