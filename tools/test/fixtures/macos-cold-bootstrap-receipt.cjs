// tools/test/fixtures/macos-cold-bootstrap-receipt.cjs
// Constructed macOS evidence for portable admission tests; never native proof.
// Preserve the independently authored desktop fixture's literal expected values.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

function coldBootstrapRecord() {
	const hash = (relative) =>
		crypto
			.createHash('sha256')
			.update(fs.readFileSync(path.resolve(__dirname, '../../..', relative)))
			.digest('hex');
	const paths = [
		'/Applications/Xcode.app/Contents/Developer/usr/bin/python3',
		'/Library/Frameworks/Python.framework/Versions/Current/bin/python3',
		'/opt/homebrew/bin/python3',
		'/opt/homebrew/bin/uv',
		'/usr/bin/python3',
		'/usr/bin/uv',
		'/usr/local/bin/python3',
		'/usr/local/bin/uv'
	];
	const profile =
		'(version 1)\n(allow default)\n(deny file-read* process-exec\n' +
		'  (literal "/Applications/Xcode.app/Contents/Developer/usr/bin/python3")\n' +
		'  (literal "/Library/Frameworks/Python.framework/Versions/Current/bin/python3")\n' +
		'  (literal "/opt/homebrew/bin/python3")\n  (literal "/opt/homebrew/bin/uv")\n' +
		'  (literal "/usr/bin/python3")\n  (literal "/usr/bin/uv")\n' +
		'  (literal "/usr/local/bin/python3")\n  (literal "/usr/local/bin/uv")\n)\n';
	const nonce = '01234567-89ab-cdef-0123-456789abcdef';
	const sources = Object.fromEntries(
		[
			'macos/ai/engine/bootstrap/network-retry.sh',
			'macos/ai/engine/local_servers/ensure-mlx-deps.sh',
			'macos/ai/engine/bootstrap/managed_bootstrap_http.py',
			'macos/ai/engine/local_servers/mlx_deps_checker.lua',
			'macos/ai/engine/bootstrap/uv-release.sh',
			'macos/ai/engine/bootstrap/managed-python-release.sh',
			'macos/ai/engine/managed-python-downloads.json',
			'macos/ai/adapters/native_bootstrap_pty.lua',
			'macos/ai/adapters/python_interpreter.lua',
			'macos/core/network/adapters/native_http.py',
			'_shared/core/network/adapters/python_network_proxy_policy.py',
			'_shared/core/lifecycle/engine/core/native_pty_receipt.lua',
			'_shared/core/network/data/proxy_policy.json',
			'_shared/ai/data/managed_python_release.json',
			'_shared/core/text/data/identifiers.sh',
			'macos/uv.lock',
			'macos/pyproject.toml'
		].map((relative) => [relative, hash('static/ergopti_plus/' + relative)])
	);
	return {
		schema_version: 1,
		contract: 'macos-native-cold-bootstrap-v1',
		runner: 'macos-15',
		sha: 'a'.repeat(40),
		receipt: {
			version: 1,
			status: 'passed',
			sha: 'a'.repeat(40),
			build_commit: 'a'.repeat(40),
			platform: 'darwin',
			architecture: 'arm64',
			runtime_environment: 'controlled isolated cold environment',
			signature_verified: true,
			uv: 'uv 0.12.21',
			python: '3.11.16',
			imports: 'passed',
			helpers_retired: true,
			cleanup: true,
			managed_runtime_isolated_exec: true,
			launcher_sha256: '1'.repeat(64),
			hammerspoon_sha256: '2'.repeat(64),
			official_hammerspoon: {
				version: '1.1.1',
				sha256: '11bb1c90faf5427f37c7bd4fe7eab9774ae43e1d5cb020c5b3088dac32849efa',
				bytes: 9704557
			},
			sources,
			diagnostics: {
				'tools/diagnostics/macos_cold_bootstrap.lua': hash(
					'tools/diagnostics/macos_cold_bootstrap.lua'
				),
				'tools/diagnostics/macos_cold_bootstrap.py': hash(
					'tools/diagnostics/macos_cold_bootstrap.py'
				)
			},
			fingerprint: sources['macos/pyproject.toml'] + ':' + sources['macos/uv.lock'],
			isolation: {
				profile_sha256: crypto.createHash('sha256').update(profile).digest('hex'),
				paths,
				host_files_preserved: true,
				observations: [
					{
						path: '/usr/bin/python3',
						sha256: '3'.repeat(64),
						device: '27',
						inode: '123',
						bytes: 1234,
						read_denied: true,
						native: true,
						exec_denied: true
					}
				]
			},
			caller: {
				version: 1,
				success: true,
				state: 'ready',
				runtime_installed: true,
				runtime: 'native Hammerspoon',
				tasks: 1,
				absent_python_selected: true,
				python_resolver: 'unmodified production resolver',
				python_state: 'python_missing',
				native_python_candidates_count: 0,
				denied_runtime_paths: paths,
				receipt_retired: true,
				receipt_removed: true,
				worker_status: 0,
				source_sha256: sources['macos/ai/engine/local_servers/ensure-mlx-deps.sh'],
				native_cli: ['--managed-pty-worker', '1800000'],
				worker_pid: 123,
				receipt_path: '/private/owned/retired-receipt',
				nonce,
				physical_receipt: {
					version: 1,
					nonce,
					state: 'retired',
					group_retired: true,
					guardian_reaped: true,
					pty_eof: true,
					handles_closed: true,
					status_valid: true,
					exit_status: 0,
					worker_status: 0,
					source_admitted: true
				}
			}
		}
	};
}

module.exports = { coldBootstrapRecord };
