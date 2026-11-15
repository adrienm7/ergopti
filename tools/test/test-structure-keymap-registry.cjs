// tools/test/test-structure-keymap-registry.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Keymap Registry Home
 * DESCRIPTION:
 * macos/modules/keymap/registry.lua is the hotstring registry: it stores and
 * looks up the hotstring mappings beside registry_groups and registry_index.
 * The settings pattern `registry$` names the Windows settings registry
 * (infra/registry.ahk), and the keymap branch of the plan sent any single
 * keymap file a logic feature claims to that feature, so S18 moved the
 * hotstring registry into settings/engine while its two siblings waited for
 * hotstrings/engine/expander in S26. The 27 package.loaded sweeps over
 * "^modules%.keymap" then refused S18. This test pins the registry beside its
 * siblings and the Windows registry in settings.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Rules = require('../audit/structure/rules.cjs');

function run() {
	const expander = 'macos/hotstrings/engine/expander';
	for (const name of ['registry', 'registry_groups', 'registry_index']) {
		const target = Rules.mapPath(`macos/modules/keymap/${name}.lua`);
		assert.equal(
			target.split('/').slice(0, -1).join('/'),
			expander,
			`macos/modules/keymap/${name}.lua goes to ${target}`
		);
	}
	assert.equal(Rules.mapPath('windows/infra/registry.ahk'), 'windows/settings/engine/registry.ahk');
	console.log('structure plan keymap registry home: OK');
}

run();
