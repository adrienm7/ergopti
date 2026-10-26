// tools/lib/lua-manifest-view.cjs

/**
 * ==============================================================================
 * MODULE: Full Text Of A Lua Driver's Features Manifest
 * DESCRIPTION:
 * The macOS and Linux drivers share one generated manifest table
 * (_shared/lua/features/manifest_data.lua), and each driver's
 * _generated/features_manifest.lua is a single projection call. The parity
 * tests parse the manifest as text, in the layout each driver used to commit,
 * so this returns that layout from the generator's model of the driver.
 * test-lua-features-manifest-projection.cjs proves the model equals what the
 * real Lua files load, so a test reading this text reads what the driver sees.
 * ==============================================================================
 */

'use strict';

const Generator = require('../build/build-features-manifest.js');

// Driver directory under static/ergopti_plus -> platform key of the manifest.
const PLATFORMS = { macos: 'hs', linux: 'linux' };

const cache = new Map();

/**
 * @param {'macos'|'linux'} driver Driver directory.
 * @returns {string} The manifest as the driver's former generated file spelled it.
 */
function luaManifestSource(driver) {
	const platform = PLATFORMS[driver];
	if (platform === undefined) throw new Error(`no Lua features manifest for driver ${driver}`);
	if (!cache.has(driver)) cache.set(driver, Generator.luaDriverManifest(platform).source);
	return cache.get(driver);
}

module.exports = { luaManifestSource };
