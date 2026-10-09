#!/usr/bin/env bash
# static/ergopti_plus/linux/install/layout_registry.sh

# Ships the layout registry with the installed driver. The daemon reads it below
# the driver root (modules/keymap/layout_registry.lua bundled_dir): the layout
# manager installs the Ergopti layouts offline from it, and the Ergopti
# extension inside it supplies SFB reduction, rolls and the magic key's repeat
# corrections. The release tarball already carries it below its linux/ tree; a
# source checkout keeps it outside both copied trees, so without this step a
# checkout install loses those hotstrings.

# The registry folder below a driver root: the "folder" of the registry settings
# in _shared/modules/layouts/defaults.json, which
# tools/test/test-linux-install-layout-registry.cjs keeps equal to this value.
LAYOUT_REGISTRY_FOLDER="static/layouts/registry"
LAYOUT_REGISTRY_INDEX="index.json"

# Prints the registry folder the installer copies beside the driver, or nothing
# when the driver source already carries it. Fails when neither layout has one:
# an installation without the registry would silently drop the Ergopti hotstrings.
# @param $1 Driver source directory (the tarball's linux/ or the checkout's driver).
# @param $2 Folder holding the driver and _shared/ sources.
layout_registry_source() {
	local driver_source="$1"
	local drivers_root="$2"
	local checkout_registry="${drivers_root}/../layouts/registry"

	if [ -f "${driver_source}/${LAYOUT_REGISTRY_FOLDER}/${LAYOUT_REGISTRY_INDEX}" ]; then
		return 0
	fi
	if [ -f "${checkout_registry}/${LAYOUT_REGISTRY_INDEX}" ]; then
		(cd -- "${checkout_registry}" && pwd -P)
		return 0
	fi
	echo "Layout registry not found beside ${driver_source} nor at ${checkout_registry}." >&2
	return 1
}

# Copies the registry a checkout keeps outside the driver below the installed
# driver root, where a packaged driver carries it. Nothing to do when the driver
# source carried it (an empty source).
# @param $1 Registry folder from layout_registry_source, possibly empty.
# @param $2 Installed driver root.
install_layout_registry() {
	local registry_source="$1"
	local installed_driver="$2"
	local destination="${installed_driver}/${LAYOUT_REGISTRY_FOLDER}"

	[ -n "${registry_source}" ] || return 0
	install -d "${destination}"
	cp -r "${registry_source}/." "${destination}/"
}
