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
const os = require('node:os');
const vm = require('node:vm');
const { createRequire } = require('node:module');
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
		assert.equal(collector.split('\n\treceiveWindowsModelEnvironment();').length - 1, 3);
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

check('Windows model-only receiving bypasses unrelated component prerequisites', () => {
	const file = path.join(ROOT, 'tools/test/test-managed-ollama-protocol.cjs');
	const collector = fs.readFileSync(file, 'utf8');
	const owned = path.join(os.tmpdir(), 'controlled-model-port-no-files');
	const boundary = new Error('controlled model child boundary; no PowerShell executed');
	const calls = [];
	const diagnostics = [];
	const sourceRequire = createRequire(file);
	const modelFs = Object.create(fs);
	modelFs.mkdtempSync = (prefix) => {
		assert.equal(prefix, path.join(os.tmpdir(), 'ergopti-model-environment-'));
		return owned;
	};
	const childProcess = {
		spawnSync(command, args, options) {
			const psHome = path.join('C:\\Windows', 'System32/WindowsPowerShell/v1.0');
			assert.equal(command, path.join(psHome, 'powershell.exe'));
			assert.equal(path.basename(args[args.indexOf('-File') + 1]), 'test_ollama_model_pull.ps1');
			assert.equal(options.cwd, owned);
			assert.equal(options.env.PSModulePath, path.join(psHome, 'Modules'));
			assert.equal(options.env.TEMP, owned);
			assert.equal(options.env.TMP, owned);
			assert.ok(!args.includes('-BuilderOnly'));
			assert.deepEqual(diagnostics, []);
			calls.push(command);
			throw boundary;
		}
	};
	assert.throws(
		() =>
			vm.runInNewContext(
				collector,
				{
					require(name) {
						if (name === 'node:fs') return modelFs;
						if (name === 'node:child_process') return childProcess;
						assert.notEqual(name, 'yaml', 'model receiving must not require npm packages');
						if (name === '../lib/python.cjs')
							return {
								pythonExecutable() {
									throw new Error('model-only receiving must not enter Python fixtures');
								}
							};
						return sourceRequire(name);
					},
					__dirname: path.dirname(file),
					__filename: file,
					Buffer,
					process: {
						argv: [process.execPath, file, '--windows-model-port'],
						platform: 'win32',
						execPath: process.execPath,
						env: { SystemRoot: 'C:\\Windows', PSModulePath: 'foreign-modules' },
						stdout: { write: (value) => diagnostics.push(value) },
						stderr: { write: (value) => diagnostics.push(value) },
						exit(code) {
							throw new Error('unexpected exit before model child: ' + code);
						}
					}
				},
				{ filename: file }
			),
		(error) => error === boundary
	);
	assert.equal(calls.length, 1, 'the existing helper must reach its actual child boundary');
	const route =
		"if (args[0] === '--windows-model-port') {\n\treceiveWindowsModelEnvironment();\n\tprocess.exit(0);\n}";
	const position = collector.indexOf(route);
	assert.ok(position > 0, 'the model-only helper must terminate through an explicit early route');
	assert.equal(collector.lastIndexOf(route), position, 'the route must have one owner');
	for (const sibling of [
		"if (process.platform === 'win32') receiveWindowsComponentShellSetup();",
		'\nreceiveFileFixtureProducer();',
		'\n\treceiveWindowsFilePort();',
		'\n\treceiveWindowsRuntimeHandoff();'
	]) {
		assert.ok(collector.indexOf(sibling) > position, 'the early route must precede ' + sibling);
	}
	const workflow = read('.github/workflows/windows-test-replay.yml');
	assert.equal(
		workflow.split('node tools/test/test-managed-ollama-protocol.cjs --windows-model-port').length -
			1,
		1,
		'the Windows replay must invoke the model-only route once'
	);
});

console.log(`# passed: ${checks}/${checks}`);
