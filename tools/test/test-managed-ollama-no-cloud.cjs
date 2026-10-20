// tools/test/test-managed-ollama-no-cloud.cjs

/**
 * ==============================================================================
 * MODULE: Managed Ollama No-Cloud Parity
 * DESCRIPTION:
 * The managed Ollama runtime only serves local models. Ollama 0.40.4 otherwise
 * contacts ollama.com from the daemon (model recommendations, the cloud model
 * cache), so every driver applies the shared serve environment
 * managed_ollama_environment.json (OLLAMA_NO_CLOUD=1) to the server it owns.
 * A user-configured external Ollama is never launched with it.
 *
 * ROOT CAUSE ENCODED:
 * A driver that launches its managed server without the shared declaration, or
 * that copies the variable as its own literal, lets the daemon reach ollama.com
 * or drift from the other drivers.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DECLARATION = 'static/ergopti_plus/_shared/modules/llm/managed_ollama_environment.json';
const read = (relative) => fs.readFileSync(path.join(ROOT, relative), 'utf8');
let checks = 0;

function check(name, run) {
	run();
	checks += 1;
	console.log(`ok ${checks} - ${name}`);
}

check('the shared declaration disables Ollama cloud contact', () => {
	const declaration = JSON.parse(read(DECLARATION));
	assert.deepEqual(Object.keys(declaration).sort(), ['schema_version', 'serve_environment']);
	assert.equal(declaration.schema_version, 1);
	assert.equal(declaration.serve_environment.OLLAMA_NO_CLOUD, '1');
});

check('Windows passes the captured declaration to every managed serve launch', () => {
	const bootstrap = read('static/ergopti_plus/windows/modules/llm/ollama_managed_bootstrap.ahk');
	assert.match(bootstrap, /\\modules\\llm\\managed_ollama_environment\.json"/);
	assert.match(
		bootstrap,
		/"environment", ServeEnvironment, "environment_sha256", this\.Sources\[ServeEnvironment\]/
	);
	const owner = read('static/ergopti_plus/windows/modules/llm/ollama_runtime_owner.ahk');
	assert.match(owner, /"-ServeEnvironmentPath", this\.Options\["environment"\]/);
	const launcher = read('static/ergopti_plus/windows/modules/llm/ollama-runtime-launch.ps1');
	assert.equal(launcher.split("Arguments = 'serve'").length - 1, 1, 'one serve child builder');
	assert.match(
		launcher,
		/New-OllamaRuntimeStart \(.*\) \$request\.port \$modelsPath \$serveEnvironment/
	);
	assert.match(
		launcher,
		/\$serveEnvironment = Read-OllamaServeEnvironment \$ServeEnvironmentPath \$ServeEnvironmentSha256/
	);
});

check(
	'Windows model CLI inherits the captured serve policy before it can start descendants',
	() => {
		const bootstrap = read('static/ergopti_plus/windows/modules/llm/ollama_managed_bootstrap.ahk');
		assert.match(bootstrap, /"-ServeEnvironmentPath", this\.Plan\["environment"\]/);
		assert.match(bootstrap, /"-ServeEnvironmentSha256", this\.Plan\["environment_sha256"\]/);
		const worker = read('static/ergopti_plus/windows/modules/llm/ollama-model-pull.ps1');
		assert.match(
			worker,
			/environment = \$ServeEnvironmentPath; environment_hash = \$ServeEnvironmentSha256/
		);
		assert.match(
			worker,
			/Read-OllamaServeEnvironment \$request\.environment \$request\.environment_hash/
		);
		assert.match(
			worker,
			/New-OllamaRuntimeStart \$Executable \$Port \$ModelsPath \$ServeEnvironment/
		);
		assert.match(worker, /New-OllamaModelStart [^\n]+ \$request\.model \$environment/);
		assert.doesNotMatch(
			worker,
			/\.EnvironmentVariables\[/,
			'the CLI must share the actual serve environment owner'
		);
		const collector = read('tools/test/test-managed-ollama-protocol.cjs');
		assert.match(collector, /\['test_ollama_model_pull\.ps1', 8\]/);
		assert.match(collector, /\['test_ollama_model_environment\.ps1', 3\]/);
		assert.equal(collector.split('\n\treceiveWindowsModelEnvironment();').length - 1, 2);
	}
);

check('Linux loads the declaration and applies it to the owned serve child', () => {
	const factory = read('static/ergopti_plus/linux/modules/llm/runtime_factory.lua');
	assert.match(factory, /require\("modules\.llm\.managed_ollama_environment"\)\.load\(\)/);
	assert.match(factory, /serve_environment = serve_environment,/);
	const loader = read('static/ergopti_plus/linux/modules/llm/managed_ollama_environment.lua');
	assert.match(loader, /"modules\/llm\/managed_ollama_environment\.json"/);
	const composition = read('static/ergopti_plus/linux/modules/llm/runtime_composition.lua');
	assert.match(composition, /for _,row in ipairs\(serve_environment\) do env\[#env\+1\]=row end/);
});

check('macOS builds the declaration into the managed server it starts', () => {
	const contract = JSON.parse(
		read('static/ergopti_plus/_shared/modules/llm/managed_ollama_runtime.json')
	);
	assert.ok(contract.source_fingerprint_paths.includes(DECLARATION));
	assert.ok(
		contract.source_fingerprint_paths.includes(
			'static/ergopti_plus/_shared/go/native_http/serve_environment.go'
		)
	);
	assert.ok(
		contract.native_http_go_test_policy.required_passes.includes(
			'TestServeEnvironmentDisablesOllamaCloud'
		)
	);
	const go = read('static/ergopti_plus/_shared/go/native_http/serve_environment.go');
	assert.match(go, /^\/\/go:embed managed_ollama_environment\.json$/m);
	assert.deepEqual(
		fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/go/native_http/managed_ollama_environment.json')
		),
		fs.readFileSync(path.join(ROOT, DECLARATION))
	);
	const producer = read('tools/build/build-macos-managed-ollama.py');
	assert.match(producer, /nativehttp\.ApplyServeEnvironment\(\); err != nil \{ return err \}/);
});

check('no driver keeps its own OLLAMA_NO_CLOUD literal', () => {
	const tracked = execFileSync('git', ['ls-files', '-z', '--', 'static/ergopti_plus'], {
		cwd: ROOT,
		encoding: 'utf8',
		maxBuffer: 256 * 1024 * 1024
	})
		.split('\0')
		.filter((name) => /^static\/ergopti_plus\/(?:windows|macos|linux)\//.test(name))
		.filter((name) => !/\/tests\//.test(name) && fs.existsSync(path.join(ROOT, name)));
	assert.ok(tracked.length > 500, 'the driver inventory must not be empty');
	const offenders = tracked.filter((name) => {
		const bytes = fs.readFileSync(path.join(ROOT, name));
		return !bytes.includes(0) && bytes.toString('utf8').includes('OLLAMA_NO_CLOUD=');
	});
	assert.deepEqual(offenders, []);
});

console.log(`# passed: ${checks}/${checks}`);
