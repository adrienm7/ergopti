// tools/test/lib/linux-private-runtime-fixture.cjs

/**
 * ==============================================================================
 * MODULE: Linux Private Runtime Fixture
 * DESCRIPTION:
 * The .deb and .rpm packagers copy the private runtime prefix the AppImage
 * stages (tools/build/stage-linux-private-runtime.sh) and admit it through the
 * shared environment template. Packaging tests that are not about native ABI
 * stage an existence-only AppDir instead of a real oldest-LTS build.
 *
 * FEATURES & RATIONALE:
 * 1. The component list is read from the template's own admission loop, so a
 *    component added there is staged here without a second list to forget.
 * 2. Files are existence fixtures, never executed: what native code they hold
 *    is proven by the AppImage stager on the oldest supported LTS.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../../..');
const TEMPLATE = path.join(ROOT, 'tools/build/templates/linux-portable-runtime-env.sh');

/** The template variables the admission loop names, relative to the prefix. */
const VARIABLES = Object.freeze({
	ERGOPTI_PACKAGE_PREFIX: '',
	GIO_MODULE_DIR: 'lib/gio/modules',
	GSETTINGS_SCHEMA_DIR: 'share/glib-2.0/schemas'
});

/**
 * Names every file the environment template requires, relative to the prefix.
 * @returns {string[]}
 */
function requiredComponents() {
	const source = fs.readFileSync(TEMPLATE, 'utf8');
	const loop = source.match(/for ERGOPTI_PACKAGE_COMPONENT in \\\n([\s\S]*?); do\n/);
	if (!loop) throw new Error('the environment template has no component admission loop');
	const components = [...loop[1].matchAll(/"\$([A-Z_]+)\/([^"]+)"/g)].map(([, name, rest]) => {
		if (!(name in VARIABLES)) throw new Error(`unknown template variable ${name}`);
		return path.posix.join(VARIABLES[name], rest);
	});
	if (components.length === 0) throw new Error('the component admission loop names nothing');
	return components;
}

/**
 * Stages an AppDir whose usr/ holds the private runtime the packagers copy.
 * @param {string} buildDirectory The packagers' ERGOPTI_LINUX_BUILD_DIR.
 * @returns {string} The AppDir path.
 */
function stageAppDir(buildDirectory) {
	const appdir = path.join(buildDirectory, 'AppDir');
	const prefix = path.join(appdir, 'usr');
	for (const component of requiredComponents()) {
		const file = path.join(prefix, component);
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, 'private runtime existence fixture, never executed\n', { mode: 0o755 });
	}
	const environment = path.join(prefix, 'lib/ergopti/network-runtime-env.sh');
	fs.mkdirSync(path.dirname(environment), { recursive: true });
	fs.copyFileSync(TEMPLATE, environment);
	return appdir;
}

module.exports = { requiredComponents, stageAppDir };
