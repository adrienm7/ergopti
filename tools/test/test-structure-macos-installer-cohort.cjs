// tools/test/test-structure-macos-installer-cohort.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan macOS Installer Cohort
 * DESCRIPTION:
 * The macOS AI installers (ensure-mlx-deps.sh, ensure-ollama-deps.sh,
 * ensure-ollama-native-deps.sh, ensure-managed-pyobjc.sh) source and run their
 * helpers as "$SCRIPT_DIR/<name>", and the launcher's PTY guardian admits the
 * four installers in one directory. The ai/engine split sent them to
 * local_servers, ollama and bootstrap by their stems, so an installer no
 * longer found network-retry.sh beside it and the guardian refused all four.
 * This test pins the whole cohort in one folder, the folder the guardian's
 * modules/llm join becomes, while the rest of ai/engine is still split.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Rules = require('../audit/structure/rules.cjs');

const COHORT = [
	'ensure-mlx-deps.sh',
	'ensure-ollama-deps.sh',
	'ensure-ollama-native-deps.sh',
	'ensure-managed-pyobjc.sh',
	'network-retry.sh',
	'native_python_bootstrap.sh',
	'uv-release.sh',
	'managed-python-release.sh',
	'managed-pyobjc.json',
	'managed-python-downloads.json',
	'managed_bootstrap_http.py'
];

function run() {
	for (const name of COHORT)
		assert.equal(
			Rules.mapPath(`macos/modules/llm/${name}`),
			`macos/ai/engine/${name}`,
			`macos/modules/llm/${name} stays beside the other installers`
		);
	// The split still applies to everything else in the folder.
	assert.equal(
		Rules.mapPath('macos/modules/llm/managed_ollama_runtime.py'),
		'macos/ai/engine/ollama/managed_ollama_runtime.py'
	);
	assert.equal(
		Rules.mapPath('macos/modules/llm/managed_network_check.py'),
		'macos/ai/engine/bootstrap/managed_network_check.py'
	);
	console.log('structure plan macOS installer cohort: OK');
}

run();
