// tools/test/test-linux-ci-evidence.cjs

/**
 * ============================================================================
 * MODULE: Linux CI Evidence Contract Tests
 * DESCRIPTION:
 * Mutation-tests every GitHub dependency result and the evidence requirements
 * that prevent linux-ok from accepting a skipped or unexecuted mandatory lane.
 * The workflow checks read the Linux box through tools/test/ci-pipeline.cjs,
 * which throws when linux-ok or the box itself is missing, so the negative
 * checks below cannot pass against a file that lost the gate they inspect.
 * The manifest's subjects are floored at the count the per-job layout proved,
 * and every harness of test-linux must run under !cancelled(), so a red E2E
 * hides no later harness and a cancelled run stops at once. The unit and E2E
 * counts must be read from what those suites printed: a review hard-coded the
 * unit count and every test stayed green.
 * ============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { findRuntime, run: runLinux } = require('./run-linux-lua.cjs');
const { verifyAggregate } = require('./linux-ci-evidence.cjs');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = JSON.parse(
	fs.readFileSync(path.join(ROOT, '.github', 'linux-ci-coverage.json'), 'utf8')
);
const LINUX_BOX = '.github/workflows/ci-linux.yml';
const WORKFLOW = pipeline.file(LINUX_BOX);
const GATE = pipeline.locate('linux-ok');
const SHA = '0123456789abcdef';
// Native Lua stdio uses host text mode; Bash tee receipts below remain byte-exact.
const NATIVE_LUA_EOL = process.platform === 'win32' ? '\r\n' : '\n';

// The real live-updater probe must expose the same refused HTTP response while
// its original assertion and exit remain red. No release or network is faked as
// accepted: these children deliberately stop at the first release-check refusal.
const updaterProbe = path.join(
	ROOT,
	'static/ergopti_plus/linux/tests/hardware/run_updater_live.lua'
);
const updaterDriver = path.join(ROOT, 'static/ergopti_plus/linux');
// The native Linux lane must never certify POSIX observations with Windows Lua.
const targetCwd = 'C:\\owned checkout\\static\\ergopti_plus\\linux';
const targetArgv = ['tests/run.lua', '--only', 'an exact case with spaces'];
const goodTarget = { status: 0, stdout: 'LuaJIT 2.1.fixture\nLinux\n', stderr: '' };
function observeRouting(platform, receipts) {
	const calls = [],
		reports = [];
	const status = runLinux(targetArgv, {
		platform,
		linuxRoot: targetCwd,
		report: (line) => reports.push(line),
		spawn: (command, args, options) => {
			calls.push({ command, args, options });
			assert.ok(receipts.length, 'no unplanned interpreter or fallback may execute');
			return receipts.shift();
		}
	});
	return { status, calls, reports };
}
const windowsTarget = observeRouting('win32', [goodTarget, { status: 0 }]);
assert.strictEqual(windowsTarget.status, 0);
assert.deepStrictEqual(
	windowsTarget.calls.map((call) => call.command),
	['wsl.exe', 'wsl.exe']
);
assert.deepStrictEqual(windowsTarget.calls[0].args.slice(0, 4), [
	'--exec',
	'luajit',
	'-e',
	windowsTarget.calls[0].args[3]
]);
assert.ok(windowsTarget.calls[0].args[3].includes('jit.os == "Linux"'));
assert.ok(windowsTarget.calls[0].args[3].includes('jit.version'));
assert.ok(windowsTarget.calls[0].options.timeout > 0, 'target preparation is bounded');
assert.deepStrictEqual(windowsTarget.calls[1].args, [
	'--cd',
	targetCwd,
	'--exec',
	'luajit',
	...targetArgv
]);
assert.strictEqual(windowsTarget.calls[1].options.cwd, targetCwd);
assert.strictEqual(windowsTarget.calls[1].options.stdio, 'inherit');
assert.ok(windowsTarget.reports.some((line) => line.includes('Linux via WSL')));
for (const refusal of [
	{ error: Object.assign(new Error('WSL missing'), { code: 'ENOENT' }), status: null },
	{ error: Object.assign(new Error('WSL startup timed out'), { code: 'ETIMEDOUT' }), status: null },
	{ status: 127, stderr: 'luajit missing' },
	{ status: null, signal: 'SIGTERM' },
	{ status: 0, stdout: 'Lua 5.4\nLinux\n' },
	{ status: 0, stdout: 'LuaJIT 2.1.fixture\nWindows\n' }
]) {
	const refused = observeRouting('win32', [refusal]);
	assert.strictEqual(refused.status, 1, 'an unavailable or wrong native target fails the gate');
	assert.strictEqual(refused.calls.length, 1, 'Windows Lua is never a fallback');
}
for (const receipt of [
	{ status: 7 },
	{ status: null, signal: 'SIGTERM' },
	{ status: null, error: new Error('native target launch refused') }
]) {
	const failed = observeRouting('win32', [goodTarget, receipt]);
	assert.strictEqual(failed.status, receipt.status === 7 ? 7 : 1);
}
for (const platform of ['linux', 'darwin']) {
	const direct = observeRouting(platform, [{ status: 0 }, { status: 3 }]);
	assert.strictEqual(direct.status, 3);
	assert.deepStrictEqual(
		direct.calls.map((call) => call.command),
		['luajit', 'luajit']
	);
	assert.deepStrictEqual(direct.calls[1].args, targetArgv);
}
const hostProbeCalls = [];
assert.strictEqual(
	findRuntime((command, args) => {
		hostProbeCalls.push({ command, args });
		return command === 'lua'
			? { status: 0 }
			: { error: Object.assign(new Error('absent'), { code: 'ENOENT' }) };
	}),
	'lua',
	'diagnostic consumers retain host-runtime discovery'
);
assert.deepStrictEqual(
	hostProbeCalls.map((call) => call.command),
	['luajit', 'lua5.4', 'lua']
);

const nativeLua = findRuntime();
assert.ok(nativeLua, 'the real updater probe regression requires the shared Lua runtime');
const updaterScratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-updater-live-evidence-'));
try {
	const refusal = JSON.stringify({
		message:
			'API rate limit exceeded. Bearer ABCDEFGHIJKLMNOP; https://private.invalid/path?sig=secret',
		documentation_url: 'https://docs.github.com/rate-limits'
	});
	// Run the actual fixture wrapper against independent URL decisions. Its
	// release refusal stays red, and authentication never becomes update proof.
	const fixtureToken = 'CI_UPDATER_ONLY_SECRET_MARKER_123456789';
	const releaseOrigin = 'https://api.github.com/repos/adrienm7/ergopti/releases';
	const authenticationCases = [
		[releaseOrigin, true],
		[`${releaseOrigin}?per_page=20&page=2`, true],
		[`${releaseOrigin}?per_page=20`, true],
		['http://api.github.com/repos/adrienm7/ergopti/releases', false],
		['HTTPS://api.github.com/repos/adrienm7/ergopti/releases', false],
		['https://API.GITHUB.COM/repos/adrienm7/ergopti/releases', false],
		['https://api.github.com./repos/adrienm7/ergopti/releases', false],
		['https://api.github.com:443/repos/adrienm7/ergopti/releases', false],
		['https://api.github.com.evil.invalid/repos/adrienm7/ergopti/releases', false],
		['https://evil.api.github.com/repos/adrienm7/ergopti/releases', false],
		['https://api.github.com@evil.invalid/repos/adrienm7/ergopti/releases', false],
		['https://evil.invalid@api.github.com/repos/adrienm7/ergopti/releases', false],
		['https://user:password@api.github.com/repos/adrienm7/ergopti/releases', false],
		[`${releaseOrigin}/`, false],
		[`${releaseOrigin}/latest`, false],
		['https://api.github.com/repos/adrienm7/other/releases', false],
		['https://api.github.com/repos/ADRIENM7/ergopti/releases', false],
		['https://api.github.com/repos/adrienm7/ergopti/%72eleases', false],
		['https://api.github.com/repos/adrienm7/ergopti/x/../releases', false],
		[`${releaseOrigin}#owned`, false],
		[`${releaseOrigin}?per_page=20#owned`, false],
		[`${releaseOrigin}?per_page=20?page=2`, false],
		[`${releaseOrigin}?page=2\n`, false],
		[`${releaseOrigin} `, false],
		['https://github.com/adrienm7/ergopti/releases/download/v1/package.tar.gz', false],
		['https://release-assets.githubusercontent.com/package.tar.gz', false]
	];
	const authenticationHarness = `
local native = { requests = 0 }
local uv = {}
function uv.run() error('synchronous refusal needs no event loop') end
function uv.new_pipe() return {} end
function uv.new_timer() return {} end
function uv.update_time() end -- Model native void-style refresh in this simulated backend.
function uv.timer_start() return true end
function uv.timer_stop() return true end
function uv.read_start(pipe, callback) pipe.read = callback; return true end
function uv.read_stop() return true end
function uv.is_closing(handle) return handle.closing == true end
function uv.close(handle) handle.closing = true end
function uv.write(_, config, callback) native.config = config; callback(nil); return true end
function uv.kill() error('completed receipt must not cancel a live successor') end
function uv.spawn(command, options, callback)
 assert(command == 'curl' and options.detached == true, 'native curl ownership changed')
 native.argv, native.pipes, native.exit = options.args, options.stdio, callback
 native.requests = native.requests + 1
 return {}, 4000 + native.requests
end
package.preload.luv = function() return uv end
package.preload['logger.shim'] = function() return {
 debug = function() end,
 error = function(_, format, detail)
  assert(not tostring(detail):find(os.getenv('GITHUB_TOKEN'), 1, true), 'native logger exposed CI authentication')
  if format == 'HTTP terminal callback raised: %s.' then native.callback_error = detail end
 end,
} end
package.preload['adapters.shell_runner'] = function() return { validate_spawn_args = function() return '' end } end
local driver = assert(arg[1], 'authentication fixture needs the explicit driver root')
package.path = driver .. '/?.lua;' .. driver .. '/?/init.lua;' .. package.path
local Client = dofile(os.getenv('UPDATER_NATIVE_CLIENT'))
local Json = require('json')
local rows = assert(Json.decode(os.getenv('UPDATER_AUTH_CASES')))
local original_headers = { Accept = 'application/vnd.github+json', ['If-None-Match'] = 'original-etag' }
local options = { owner = 'updater', timeout_ms = 9000, follow_redirects = true, https_only = true, etag_compare = '/owned/etag-in', etag_save = '/owned/etag-out', max_body_bytes = 65536 }
local http_status = tonumber(os.getenv('UPDATER_HTTP_STATUS')) or 403
local answer = { ok = false, status = http_status, error = 'HTTP ' .. http_status }
local expected, count, callbacks = nil, 0, 0
local original_get = function(url, headers, sent_options, callback)
 assert(url == expected[1], 'fixture changed original URL')
 assert(headers.Accept == original_headers.Accept and headers['If-None-Match'] == original_headers['If-None-Match'], 'fixture changed ordinary headers')
 if expected[2] and os.getenv('GITHUB_ACTIONS') == 'true' then
  assert(headers.Authorization == 'Bearer ' .. os.getenv('GITHUB_TOKEN'), 'exact release request is not authenticated')
  assert(headers ~= original_headers, 'authentication must not mutate caller headers')
  assert(sent_options ~= options and sent_options.follow_redirects == false, 'authenticated request follows a redirect')
 else
  assert(headers == original_headers and headers.Authorization == nil, 'authentication escaped its exact CI origin')
  assert(sent_options == options, 'non-authenticated request lost exact options identity')
 end
 assert(original_headers.Authorization == nil, 'caller header table was mutated')
 assert(options.follow_redirects == true, 'caller redirect policy was mutated')
 for name, value in pairs(options) do
  assert(name == 'follow_redirects' or sent_options[name] == value, 'request ownership, deadline, cache or limit changed')
 end
 count = count + 1
 local delivered = false
 local sent = Client.get(url, headers, sent_options, function(result)
  assert(result.status == http_status and result.ok == false, 'native HTTP refusal changed')
  answer = result
  assert(callback(result, 'original callback receipt') == 'original callback return')
  delivered = true
 end)
 assert(sent == true and not delivered, 'native adapter must return before completion')
 local argv = table.concat(native.argv, '\\n')
 assert(not argv:find(os.getenv('GITHUB_TOKEN'), 1, true), 'CI token reached native argv')
 assert(argv:find('--config\\n-', 1, true), 'native curl lost private stdin config')
 assert((argv:find('--location', 1, true) == nil) == (expected[2] and os.getenv('GITHUB_ACTIONS') == 'true'), 'native curl redirect policy escaped authentication scope')
 if expected[2] and os.getenv('GITHUB_ACTIONS') == 'true' then
  assert(native.config:find('header = "Authorization: Bearer ' .. os.getenv('GITHUB_TOKEN') .. '"', 1, true), 'native stdin lacks exact CI authentication')
 else
  assert(not native.config:find(os.getenv('GITHUB_TOKEN'), 1, true), 'native stdin authenticated a foreign request')
 end
 local response_body = http_status == 304 and '' or os.getenv('UPDATER_ECHO_CI_TOKEN') == 'true'
  and Json.encode({ message = 'controlled refusal: Bearer ' .. os.getenv('GITHUB_TOKEN')
   .. ' repeated ' .. os.getenv('GITHUB_TOKEN') .. ' suffix kept' })
  or '{"message":"actual refused response"}'
 native.pipes[2].read(nil, response_body .. '\\nERGOPTI_HTTP_STATUS:' .. http_status .. '\\n')
 native.pipes[2].read(nil, nil)
 native.pipes[3].read(nil, nil)
 native.exit(http_status >= 400 and 22 or 0, 0)
 assert(native.callback_error == nil, 'native callback assertion was swallowed')
 assert(delivered and not Client.isActive('updater'), 'native terminal receipt did not settle')
 return sent
end
local trusted_url, getter_calls = os.getenv('UPDATER_TRUSTED_RELEASE_URL'), 0
local manager = { _http_client = { get = original_get }, init = function()
 trusted_url = 'https://api.github.com/repos/untrusted/changed/releases'
end, current_version = function() return '0.0.0-dev.1' end, get_channel = function() return 'dev' end }
if os.getenv('UPDATER_GETTER_ABSENT') ~= 'true' then
 manager.release_api_url = function() getter_calls = getter_calls + 1; return trusted_url end
end
manager.check_for_updates = function(_, callback)
 for _, row in ipairs(rows) do
  expected = row
  assert(manager._http_client.get(row[1], original_headers, options, function(result, receipt)
   assert(result == answer and receipt == 'original callback receipt', 'fixture changed response ownership')
   callbacks = callbacks + 1
   return 'original callback return'
  end) == true, 'fixture changed dispatch result')
 end
 assert(count == #rows and callbacks == #rows, 'fixture skipped a scoped request')
 callback(false, nil, answer.error)
end
package.preload['modules.updater.manager'] = function() return manager end
local original_exit = os.exit
os.exit = function(status)
 assert(manager._http_client.get == original_get, 'authentication wrapper was not released')
 assert(status == 1, 'authentication cannot forgive a release refusal')
 assert(getter_calls == (os.getenv('GITHUB_ACTIONS') == 'true' and 1 or 0), 'trusted release owner was not captured exactly once')
 print('scoped request and cleanup observations: ' .. count)
 original_exit(status)
end
`;
	const customOrigin = 'https://api.github.com/repos/fixture-owner/other-project/releases';
	const authVariants = [
		...['true', 'false', 'TRUE'].map((ci) => ({
			ci,
			origin: releaseOrigin,
			cases: authenticationCases,
			status: 403,
			name: ci
		})),
		{
			ci: 'true',
			origin: customOrigin,
			cases: [
				[customOrigin, true],
				[`${customOrigin}?per_page=20&page=2`, true],
				[releaseOrigin, false],
				[`${releaseOrigin}?per_page=20&page=2`, false],
				[`${customOrigin}/latest`, false],
				['https://api.github.com/repos/untrusted/changed/releases', false]
			],
			status: 403,
			name: 'custom-owner'
		},
		{
			ci: 'true',
			origin: releaseOrigin,
			cases: [[releaseOrigin, true]],
			status: 302,
			name: 'redirect-refusal'
		},
		{
			ci: 'true',
			origin: releaseOrigin,
			cases: [
				[releaseOrigin, true],
				[`${releaseOrigin}?per_page=20&page=2`, true]
			],
			status: 304,
			name: 'conditional-cache-observation'
		},
		...[
			['short-response-echo', 'short'],
			['punctuated-response-echo', 'OPAQUE.valid-~_+/123=='],
			['long-response-echo', 'LONG_ECHO_' + 'Ab09-._~+/'.repeat(300) + '==']
		].map(([name, token]) => ({
			ci: 'true',
			origin: releaseOrigin,
			cases: [[releaseOrigin, true]],
			status: 403,
			name,
			token,
			echo: true
		})),
		// These inert values are valid RFC 6750 credentials. The original probe
		// wrongly rejected short values, >255 bytes, and opaque punctuation.
		...[
			['short-token', 'short'],
			['old-length-boundary', 'x'.repeat(256)],
			['opaque-token', 'OPAQUE.valid-~_+/123=='],
			['long-opaque-token', 'LONG_OPAQUE_' + 'Ab09-._~+/'.repeat(100) + '==']
		].map(([name, token]) => ({
			ci: 'true',
			origin: releaseOrigin,
			cases: [
				[releaseOrigin, true],
				[customOrigin, false],
				['https://release-assets.githubusercontent.com/package.tar.gz', false]
			],
			status: 403,
			name,
			token
		}))
	];
	for (const [caseIndex, variant] of authVariants.entries()) {
		const { ci } = variant;
		const token = variant.token || fixtureToken;
		const evidence = path.join(updaterScratch, `authentication-${caseIndex}-${variant.name}`);
		fs.mkdirSync(evidence);
		const authenticated = spawnSync(
			nativeLua,
			['-e', authenticationHarness, updaterProbe, updaterDriver, updaterScratch],
			{
				encoding: 'utf8',
				env: {
					...process.env,
					LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
					GITHUB_ACTIONS: ci,
					GITHUB_TOKEN: token,
					ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: evidence,
					UPDATER_NATIVE_CLIENT: path.join(updaterDriver, 'adapters/curl_http_client.lua'),
					UPDATER_TRUSTED_RELEASE_URL: `${variant.origin}?per_page=100`,
					UPDATER_HTTP_STATUS: String(variant.status),
					UPDATER_ECHO_CI_TOKEN: variant.echo ? 'true' : 'false',
					UPDATER_AUTH_CASES: JSON.stringify(variant.cases)
				}
			}
		);
		assert.ifError(authenticated.error);
		assert.strictEqual(authenticated.status, 1, 'real release refusal must remain nonzero');
		assert.match(authenticated.stdout, /FAIL the newest release is found/);
		assert.ok(
			authenticated.stdout.includes(
				`scoped request and cleanup observations: ${variant.cases.length}${NATIVE_LUA_EOL}`
			)
		);
		const captured = fs.readFileSync(path.join(evidence, 'http.json'), 'utf8');
		assert.strictEqual(JSON.parse(captured).responses.length, variant.cases.length);
		assert.ok(
			JSON.parse(captured).responses.every((response) => response.status === variant.status)
		);
		if (variant.status === 304) {
			assert.strictEqual(
				(authenticated.stderr.match(/^::notice title=Linux updater live HTTP::/gm) || []).length,
				variant.cases.length,
				'conditional responses are observations; the updater owns cache admission'
			);
			assert.doesNotMatch(authenticated.stderr, /^::error title=Linux updater live HTTP::/m);
			for (const response of JSON.parse(captured).responses) {
				assert.strictEqual(response.body, '', 'a 304 response has no body');
				assert.strictEqual(response.headers_available, false, 'absent headers stay unavailable');
			}
		}
		if (variant.echo) {
			const response = JSON.parse(captured).responses[0];
			assert.strictEqual(response.status, 403);
			assert.strictEqual(
				response.message,
				'controlled refusal: Bearer <secret> repeated <secret> suffix kept'
			);
			assert.strictEqual(JSON.parse(response.body).message, response.message);
			assert.ok(response.error.includes('HTTP 403'), 'real HTTP refusal detail was lost');
			assert.ok(
				authenticated.stderr.includes('controlled refusal:'),
				'echo sanitization dropped all response evidence'
			);
			if (variant.name === 'long-response-echo') {
				assert.ok(
					token.length > 2048,
					'long credential must cross the actual diagnostic clip bound'
				);
				assert.ok(!captured.includes(token.slice(0, 32)), 'clipping exposed a credential fragment');
				assert.ok(
					!authenticated.stdout.includes(token.slice(0, 32)),
					'stdout exposed a credential fragment'
				);
				assert.ok(
					!authenticated.stderr.includes(token.slice(0, 32)),
					'stderr exposed a credential fragment'
				);
			}
		}
		for (const privateText of [token, 'Authorization', 'original-etag', 'user:password']) {
			assert.ok(!authenticated.stdout.includes(privateText), 'stdout leaked private request state');
			assert.ok(!authenticated.stderr.includes(privateText), 'stderr leaked private request state');
			assert.ok(!captured.includes(privateText), 'artifact leaked private request state');
		}
	}

	// The complete original auth matrix above exercises the sole extracted curl
	// producer: exact origin/header/stdin/privacy/status laws are unchanged.
	// These additional controls load the actual managed public port. Native
	// callbacks remain simulated libuv ports; this is not a native-wire proof.
	const managedAuthenticationHarness = authenticationHarness
		.replace(
			'local native = { requests = 0 }',
			`local native = { requests = 0, acquired = 0, closed = 0 }
local function allocated(kind)
 native.acquired = native.acquired + 1
 return { kind = kind }
end`
		)
		.replace(
			'function uv.new_pipe() return {} end',
			"function uv.new_pipe() return allocated('pipe') end"
		)
		.replace(
			'function uv.new_timer() return {} end',
			"function uv.new_timer() return allocated('timer') end\nfunction uv.hrtime() return 1000000 end"
		)
		.replace(
			'function uv.close(handle) handle.closing = true end',
			`function uv.close(handle, callback)
 assert(not handle.closed, 'managed fixture retried an acknowledged native close')
 handle.closing, handle.closed = true, true
 native.closed = native.closed + 1
 if callback then callback() end
end`
		)
		.replace(
			'return {}, 4000 + native.requests',
			"return allocated('process'), 4000 + native.requests"
		)
		.replace(
			"if format == 'HTTP terminal callback raised: %s.' then native.callback_error = detail end",
			`if format == 'HTTP terminal callback raised: %s.'
   or format == 'Owned HTTP terminal callback raised: %s.'
   or format == 'Owned HTTP settlement callback raised: %s.'
   or (format == '%s' and type(detail) == 'string' and detail:find('callback raised.', 1, true)) then
   native.callback_error = 'protected callback raised'
  end`
		)
		.replace(
			"assert(delivered and not Client.isActive('updater'), 'native terminal receipt did not settle')",
			`assert(delivered and not Client.isActive('updater'), 'native terminal receipt did not settle')
 assert(native.acquired == native.closed, 'managed public completion lost a physical close ACK')`
		);
	const managedCases = [
		[releaseOrigin, true],
		[`${releaseOrigin}?per_page=20&page=2`, true],
		[customOrigin, false],
		['https://release-assets.githubusercontent.com/package.tar.gz', false],
		['https://API.GITHUB.COM/repos/adrienm7/ergopti/releases', false],
		['https://api.github.com.evil.invalid/repos/adrienm7/ergopti/releases', false],
		['https://user:password@api.github.com/repos/adrienm7/ergopti/releases', false]
	];
	const managedVariants = [
		{ name: 'ci-scoped', ci: 'true', status: 403 },
		{ name: 'non-ci', ci: 'false', status: 403 },
		{ name: 'conditional', ci: 'true', status: 304 }
	];
	const managedEnvironment = (evidence, ci, status, cases) => ({
		...process.env,
		LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
		GITHUB_ACTIONS: ci,
		GITHUB_TOKEN: fixtureToken,
		ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: evidence,
		UPDATER_NATIVE_CLIENT: path.join(updaterDriver, 'adapters/http_client.lua'),
		UPDATER_TRUSTED_RELEASE_URL: `${releaseOrigin}?per_page=100`,
		UPDATER_HTTP_STATUS: String(status),
		UPDATER_ECHO_CI_TOKEN: 'false',
		UPDATER_AUTH_CASES: JSON.stringify(cases),
		// Real canonical environment admission, confined to this simulated child.
		// No OS settings/helper/route receipt override is provided.
		http_proxy: 'http://127.0.0.1:9',
		https_proxy: 'http://127.0.0.1:9',
		HTTP_PROXY: '',
		HTTPS_PROXY: '',
		all_proxy: '',
		ALL_PROXY: '',
		NO_PROXY: '',
		no_proxy: ''
	});
	for (const variant of managedVariants) {
		const evidence = path.join(updaterScratch, `managed-authentication-${variant.name}`);
		fs.mkdirSync(evidence);
		const observed = spawnSync(
			nativeLua,
			['-e', managedAuthenticationHarness, updaterProbe, updaterDriver, updaterScratch],
			{
				encoding: 'utf8',
				env: managedEnvironment(evidence, variant.ci, variant.status, managedCases)
			}
		);
		assert.ifError(observed.error);
		assert.strictEqual(
			observed.status,
			1,
			'managed authentication cannot forgive the original update refusal'
		);
		assert.match(observed.stdout, /FAIL the newest release is found/);
		assert.ok(
			observed.stdout.includes(`scoped request and cleanup observations: 7${NATIVE_LUA_EOL}`)
		);
		const captured = fs.readFileSync(path.join(evidence, 'http.json'), 'utf8');
		const responses = JSON.parse(captured).responses;
		assert.strictEqual(responses.length, 7);
		assert.ok(responses.every((response) => response.status === variant.status));
		if (variant.status === 304) {
			assert.strictEqual(
				(observed.stderr.match(/^::notice title=Linux updater live HTTP::/gm) || []).length,
				7
			);
			assert.doesNotMatch(observed.stderr, /^::error title=Linux updater live HTTP::/m);
			assert.ok(
				responses.every((response) => response.body === '' && response.headers_available === false)
			);
		}
		for (const privateText of [fixtureToken, 'Authorization', 'original-etag', 'user:password']) {
			assert.ok(
				!observed.stdout.includes(privateText),
				'managed stdout leaked private request state'
			);
			assert.ok(
				!observed.stderr.includes(privateText),
				'managed stderr leaked private request state'
			);
			assert.ok(!captured.includes(privateText), 'managed artifact leaked private request state');
		}
	}
	// A malformed external URI must still reach the original observational
	// wrapper without CI authentication, then fail closed before acquisition.
	const originalGetStart = managedAuthenticationHarness.indexOf('local original_get = function');
	const originalGetEnd = managedAuthenticationHarness.indexOf('local trusted_url, getter_calls');
	assert.ok(originalGetStart >= 0 && originalGetEnd > originalGetStart);
	const refusedGet = `local original_get = function(url, headers, sent_options, callback)
 assert(url == expected[1], 'managed refusal changed the exact invalid URI')
 assert(headers == original_headers and headers.Authorization == nil, 'invalid URI was authenticated')
 assert(sent_options == options, 'invalid URI changed caller options')
 count = count + 1
 local delivered = false
 local sent = Client.get(url, headers, sent_options, function(result)
  assert(result.ok == false and result.status == 0 and result.body == '', 'invalid route fabricated an HTTP response')
  assert(result.error == 'proxy-route-invalid', 'invalid route lost its canonical refusal')
  answer = result
  assert(callback(result, 'original callback receipt') == 'original callback return')
  delivered = true
 end)
 assert(sent == false and delivered, 'invalid route must refuse before native dispatch')
 assert(native.requests == 0 and native.acquired == 0 and native.closed == 0, 'invalid route acquired a native owner')
 assert(native.callback_error == nil and not Client.isActive('updater'), 'invalid refusal lost its completion fence')
 return sent
end
`;
	const refusedManagerStart = managedAuthenticationHarness.indexOf(
		'manager.check_for_updates = function'
	);
	const refusedManagerEnd = managedAuthenticationHarness.indexOf(
		"package.preload['modules.updater.manager']"
	);
	assert.ok(refusedManagerStart > originalGetEnd && refusedManagerEnd > refusedManagerStart);
	const refusedManager = `manager.check_for_updates = function(_, callback)
 assert(#rows == 1, 'invalid route fixture inventory changed')
 expected = rows[1]
 assert(manager._http_client.get(expected[1], original_headers, options, function(result, receipt)
  assert(result == answer and receipt == 'original callback receipt', 'invalid refusal changed response ownership')
  callbacks = callbacks + 1
  return 'original callback return'
 end) == false, 'invalid route dispatch was admitted')
 assert(count == 1 and callbacks == 1, 'invalid route skipped its observed request')
 callback(false, nil, answer.error)
end
`;
	const managedRefusalHarness =
		managedAuthenticationHarness.slice(0, originalGetStart) +
		refusedGet +
		managedAuthenticationHarness.slice(originalGetEnd, refusedManagerStart) +
		refusedManager +
		managedAuthenticationHarness.slice(refusedManagerEnd);
	const invalidEvidence = path.join(updaterScratch, 'managed-authentication-invalid-newline');
	fs.mkdirSync(invalidEvidence);
	const invalid = spawnSync(
		nativeLua,
		['-e', managedRefusalHarness, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: managedEnvironment(invalidEvidence, 'true', 403, [[`${releaseOrigin}?page=2\n`, false]])
		}
	);
	assert.ifError(invalid.error);
	assert.strictEqual(invalid.status, 1, 'a refused managed route must keep the updater red');
	assert.match(invalid.stdout, /FAIL the newest release is found/);
	assert.ok(invalid.stdout.includes(`scoped request and cleanup observations: 1${NATIVE_LUA_EOL}`));
	const invalidCaptured = fs.readFileSync(path.join(invalidEvidence, 'http.json'), 'utf8');
	assert.strictEqual(JSON.parse(invalidCaptured).responses.length, 1);
	assert.strictEqual(JSON.parse(invalidCaptured).responses[0].status, 0);
	assert.strictEqual(JSON.parse(invalidCaptured).responses[0].error, 'proxy-route-invalid');
	for (const privateText of [fixtureToken, 'Authorization', 'original-etag', 'user:password']) {
		assert.ok(!invalid.stdout.includes(privateText));
		assert.ok(!invalid.stderr.includes(privateText));
		assert.ok(!invalidCaptured.includes(privateText));
	}

	for (const token of [
		'',
		fixtureToken + '\n',
		fixtureToken + '\r',
		fixtureToken + ' ',
		fixtureToken + 'é',
		fixtureToken + '\t',
		fixtureToken + '\x01',
		fixtureToken + '\x7f',
		'=',
		fixtureToken + '=interior',
		fixtureToken + '"',
		fixtureToken + '\\',
		fixtureToken + '\r\nX-Injected: true',
		fixtureToken + '"\nurl = "https://foreign.invalid"'
	]) {
		const refused = spawnSync(
			nativeLua,
			['-e', authenticationHarness, updaterProbe, updaterDriver, updaterScratch],
			{
				encoding: 'utf8',
				env: {
					...process.env,
					LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
					GITHUB_ACTIONS: 'true',
					GITHUB_TOKEN: token,
					UPDATER_NATIVE_CLIENT: path.join(updaterDriver, 'adapters/curl_http_client.lua'),
					UPDATER_TRUSTED_RELEASE_URL: `${releaseOrigin}?per_page=100`,
					UPDATER_AUTH_CASES: JSON.stringify(authenticationCases)
				}
			}
		);
		assert.ifError(refused.error);
		assert.notStrictEqual(refused.status, 0);
		assert.match(refused.stderr, /CI updater authentication is unavailable or invalid/);
		assert.doesNotMatch(refused.stdout + refused.stderr, /CI_UPDATER_ONLY_SECRET_MARKER/);
		assert.doesNotMatch(refused.stdout, /installed |scoped request and cleanup/);
	}
	for (const endpoint of [
		null,
		'http://api.github.com/repos/fixture/owned/releases',
		'https://api.github.com:443/repos/fixture/owned/releases',
		'https://api.github.com@evil.invalid/repos/fixture/owned/releases',
		'https://api.github.com/repos/fixture/owned/releases#foreign',
		'https://api.github.com/repos/../owned/releases'
	]) {
		const rejectedOwner = spawnSync(
			nativeLua,
			['-e', authenticationHarness, updaterProbe, updaterDriver, updaterScratch],
			{
				encoding: 'utf8',
				env: {
					...process.env,
					LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
					GITHUB_ACTIONS: 'true',
					GITHUB_TOKEN: fixtureToken,
					UPDATER_GETTER_ABSENT: endpoint === null ? 'true' : 'false',
					UPDATER_TRUSTED_RELEASE_URL: endpoint || '',
					UPDATER_NATIVE_CLIENT: path.join(updaterDriver, 'adapters/curl_http_client.lua'),
					UPDATER_AUTH_CASES: JSON.stringify(authenticationCases)
				}
			}
		);
		assert.ifError(rejectedOwner.error);
		assert.notStrictEqual(rejectedOwner.status, 0);
		assert.match(rejectedOwner.stderr, /CI updater release owner is (unavailable|invalid)/);
		assert.doesNotMatch(rejectedOwner.stdout, /installed |scoped request and cleanup/);
		assert.ok(!rejectedOwner.stderr.includes(fixtureToken));
	}
	// Binary fixture bytes avoid native getenv transcoding the UTF-8 response.
	const responseFile = path.join(updaterScratch, 'response.json');
	fs.writeFileSync(responseFile, refusal);
	const boundedResponseFile = path.join(updaterScratch, 'bounded-response.json');
	fs.writeFileSync(
		boundedResponseFile,
		JSON.stringify({ message: 'refused 100%\r\n::error::foreign ' + 'é'.repeat(2000) })
	);
	const injected = `
package.preload.luv = function() return { run = function() error('a synchronous refusal needs no event loop') end } end
local response_file = assert(io.open(os.getenv('UPDATER_RESPONSE_FILE'), 'rb'))
local fixture_response = assert(response_file:read('*a'))
assert(response_file:close())
local response = { ok = false, status = 403, error = 'HTTP 403', error_body = fixture_response }
local headers, options = { Authorization = 'Bearer ORIGINAL_REQUEST_SECRET' }, { owner = 'updater' }
local original_get = function(url, sent_headers, sent_options, callback)
 assert(url == 'https://api.github.com/owned/releases')
 assert(sent_headers == headers and sent_options == options, 'the observational wrapper changed request ownership')
 io.stdout:write('transport stdout preserved\\n')
 io.stderr:write('transport stderr preserved\\n')
 assert(callback(response, 'owned callback receipt') == 'callback return preserved')
 return true
end
local manager = { _http_client = { get = original_get }, init = function() end,
 release_api_url = function() return 'https://api.github.com/repos/fixture/owned/releases?per_page=100' end,
 current_version = function() return '0.0.0-dev.1' end, get_channel = function() return 'dev' end }
manager.check_for_updates = function(_, callback)
 assert(manager._http_client.get('https://api.github.com/owned/releases', headers, options, function(received, receipt)
  assert(receipt == 'owned callback receipt', 'the wrapper changed callback arguments')
  assert(received == response and received.error_body == fixture_response, 'the wrapper changed the result')
  callback(false, nil, received.error)
  return 'callback return preserved'
 end) == true, 'the wrapper changed the transport return')
end
package.preload['modules.updater.manager'] = function() return manager end
local native_exit = os.exit
os.exit = function(code)
 assert(manager._http_client.get == original_get, 'the probe did not release its observational wrapper')
 io.stderr:write('probe lifecycle cleanup preserved\\n')
 native_exit(code)
end
`;
	const probe = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				GITHUB_TOKEN: fixtureToken,
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: updaterScratch,
				UPDATER_RESPONSE_FILE: responseFile
			}
		}
	);
	assert.ifError(probe.error);
	assert.strictEqual(
		probe.status,
		1,
		'the original failed release-check assertion remains nonzero'
	);
	assert.ok(probe.stdout.includes('transport stdout preserved' + NATIVE_LUA_EOL));
	assert.ok(probe.stderr.includes('transport stderr preserved' + NATIVE_LUA_EOL));
	assert.ok(probe.stderr.includes('probe lifecycle cleanup preserved' + NATIVE_LUA_EOL));
	assert.ok(
		probe.stdout.includes(
			'  check: nil HTTP 403' +
				NATIVE_LUA_EOL +
				'  FAIL the newest release is found' +
				NATIVE_LUA_EOL
		)
	);
	assert.match(
		probe.stderr,
		/::error title=Linux updater live HTTP::.*HTTP 403.*API rate limit exceeded/
	);
	assert.doesNotMatch(
		probe.stderr,
		/ABCDEFGHIJKLMNOP|ORIGINAL_REQUEST_SECRET|private\.invalid|sig=secret/
	);
	const httpReceipt = JSON.parse(fs.readFileSync(path.join(updaterScratch, 'http.json'), 'utf8'));
	assert.strictEqual(httpReceipt.responses.length, 1);
	assert.strictEqual(httpReceipt.responses[0].status, 403);
	assert.strictEqual(
		httpReceipt.responses[0].headers_available,
		false,
		'absent response headers are never invented'
	);
	assert.match(httpReceipt.responses[0].message, /API rate limit exceeded/);
	assert.strictEqual(
		JSON.parse(httpReceipt.responses[0].body).documentation_url,
		'<url>',
		'the same response body is retained with URLs masked'
	);
	assert.doesNotMatch(
		JSON.stringify(httpReceipt),
		/ABCDEFGHIJKLMNOP|ORIGINAL_REQUEST_SECRET|private\.invalid|sig=secret/
	);

	// The bounded same-response detail cannot inject a second workflow command.
	const boundedDir = path.join(updaterScratch, 'bounded');
	fs.mkdirSync(boundedDir);
	const bounded = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				GITHUB_TOKEN: fixtureToken,
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: boundedDir,
				UPDATER_RESPONSE_FILE: boundedResponseFile
			}
		}
	);
	assert.ifError(bounded.error);
	assert.strictEqual(bounded.status, 1);
	assert.ok(bounded.stderr.includes('probe lifecycle cleanup preserved' + NATIVE_LUA_EOL));
	assert.match(bounded.stderr, /100%25%0D%0A::error::foreign/);
	assert.strictEqual(
		(bounded.stderr.match(/^::error/gm) || []).length,
		1,
		'response text cannot create an extra annotation'
	);
	const boundedMessage = JSON.parse(fs.readFileSync(path.join(boundedDir, 'http.json'), 'utf8'))
		.responses[0].message;
	assert.ok(Buffer.byteLength(boundedMessage) <= 2061, 'response body evidence is bounded');
	assert.ok(boundedMessage.endsWith(' <truncated>'));
	assert.ok(
		boundedMessage.startsWith('refused 100%\r\n::error::foreign é'),
		'the actual response retains its UTF-8 prefix'
	);
	assert.ok(!boundedMessage.includes('�'), 'bounded evidence retains complete UTF-8 characters');

	// A refused evidence write cannot replace the actual HTTP failure or
	// interrupt the callback/return/cleanup assertions in the real probe.
	const blockedEvidence = path.join(updaterScratch, 'not-a-directory');
	fs.writeFileSync(blockedEvidence, 'occupied');
	const blocked = spawnSync(
		nativeLua,
		['-e', injected, updaterProbe, updaterDriver, updaterScratch],
		{
			encoding: 'utf8',
			env: {
				...process.env,
				LUA_PATH: `${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua')};${path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')};;`,
				GITHUB_ACTIONS: 'true',
				GITHUB_TOKEN: fixtureToken,
				ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: blockedEvidence,
				UPDATER_RESPONSE_FILE: responseFile
			}
		}
	);
	assert.ifError(blocked.error);
	assert.strictEqual(blocked.status, 1);
	assert.ok(blocked.stderr.includes('probe lifecycle cleanup preserved' + NATIVE_LUA_EOL));
	assert.ok(
		blocked.stdout.includes(
			'  check: nil HTTP 403' +
				NATIVE_LUA_EOL +
				'  FAIL the newest release is found' +
				NATIVE_LUA_EOL
		)
	);
	assert.match(blocked.stderr, /HTTP refusal evidence could not be captured/);

	// Execute the actual Bash owner with controlled build/install/interpreter
	// ports. This checks diagnostics and cleanup, never claims a real update.
	const runnerFixture = path.join(updaterScratch, 'runner');
	const runnerRelative = 'static/ergopti_plus/linux/tests/hardware/run_updater_live.sh';
	const runner = path.join(runnerFixture, runnerRelative);
	fs.mkdirSync(path.dirname(runner), { recursive: true });
	fs.copyFileSync(path.join(ROOT, runnerRelative), runner);
	fs.mkdirSync(path.join(runnerFixture, 'bin'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'tools/build'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/linux'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/_shared'), { recursive: true });
	fs.mkdirSync(path.join(runnerFixture, 'build/linux/bin'), { recursive: true });
	fs.writeFileSync(
		path.join(runnerFixture, 'tools/build/build-linux-driver.sh'),
		'#!/usr/bin/env bash\nexit "${UPDATER_TEST_BUILD_STATUS:-0}"\n'
	);
	fs.writeFileSync(
		path.join(runnerFixture, 'build/linux/install.sh'),
		`#!/usr/bin/env bash
mkdir -p "$HOME/.local/lib/ergopti/_shared" "$XDG_STATE_HOME/ergopti_plus/logs"
printf 'version=0.0.0-dev.2\\n' > "$HOME/.local/lib/ergopti/_shared/build_stamp.txt"
printf 'daemon starting (version 0.0.0-dev.2, fixture)\\n' > "$XDG_STATE_HOME/ergopti_plus/logs/daemon.log"
exit "${'${UPDATER_TEST_INSTALL_STATUS:-0}'}"
`
	);
	fs.writeFileSync(
		path.join(runnerFixture, 'bin/luajit'),
		`#!/usr/bin/env bash
if [ "$1" = -e ]; then exit "${'${UPDATER_TEST_ENV_STATUS:-0}'}"; fi
printf '%s' "$UPDATER_TEST_STDOUT"
printf '%s' "$UPDATER_TEST_STDERR" >&2
printf '%s' "${'${HOME%/home}'}" > "$UPDATER_TEST_WORK_REPORT"
exit "$UPDATER_TEST_STATUS"
`,
		{ mode: 0o755 }
	);
	for (const tool of ['curl', 'sha256sum', 'pkill'])
		fs.writeFileSync(path.join(runnerFixture, 'bin', tool), '#!/usr/bin/env bash\nexit 0\n', {
			mode: 0o755
		});
	for (const fixture of [
		{ phase: 'updater', status: 1, child: 7 },
		{ phase: 'complete', status: 0, child: 0 },
		{ phase: 'build', status: 1, child: 0, build: 19 },
		{ phase: 'install', status: 1, child: 0, install: 20 },
		{ phase: 'environment', status: 2, child: 0, environment: 8 },
		{ phase: 'updater', status: 1, child: 7, blocked: true },
		{ phase: 'complete', status: 0, child: 0, blocked: true }
	]) {
		const evidence = path.join(
			updaterScratch,
			`evidence-${fixture.phase}${fixture.blocked ? '-blocked' : ''}`
		);
		if (fixture.blocked) fs.writeFileSync(evidence, 'occupied diagnostic destination');
		const workReport = path.join(updaterScratch, `work-${fixture.phase}.txt`);
		const stdout = 'original stdout é 100%\n';
		const stderr = 'original stderr HTTP 403\n';
		const result = spawnSync(
			bashExecutable(),
			['-c', 'PATH="./bin:$PATH"; exec bash "$UPDATER_TEST_RUNNER"'],
			{
				cwd: runnerFixture,
				encoding: 'utf8',
				env: {
					...process.env,
					GITHUB_ACTIONS: 'true',
					GITHUB_SHA: SHA,
					UPDATER_TEST_RUNNER: runner.replaceAll('\\', '/'),
					UPDATER_TEST_BUILD_STATUS: String(fixture.build || 0),
					UPDATER_TEST_INSTALL_STATUS: String(fixture.install || 0),
					UPDATER_TEST_ENV_STATUS: String(fixture.environment || 0),
					UPDATER_TEST_STATUS: String(fixture.child),
					UPDATER_TEST_STDOUT: stdout,
					UPDATER_TEST_STDERR: stderr,
					UPDATER_TEST_WORK_REPORT: workReport.replaceAll('\\', '/'),
					ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: evidence.replaceAll('\\', '/')
				}
			}
		);
		assert.ifError(result.error);
		assert.strictEqual(
			result.status,
			fixture.status,
			`${fixture.phase}: diagnostics must retain the actual owner verdict`
		);
		if (!fixture.blocked) {
			const receipt = fs.readFileSync(path.join(evidence, 'result.txt'), 'utf8');
			assert.match(receipt, new RegExp(`^phase=${fixture.phase}$`, 'm'));
			assert.match(receipt, new RegExp(`^exit_status=${fixture.status}$`, 'm'));
			assert.match(
				receipt,
				new RegExp(
					`^cause_exit_status=${fixture.environment || fixture.build || fixture.install || fixture.child}$`,
					'm'
				)
			);
			assert.match(receipt, new RegExp(`^sha=${SHA}$`, 'm'));
		} else {
			assert.match(result.stderr, /Updater evidence directory could not be created/);
			assert.strictEqual(fs.readFileSync(evidence, 'utf8'), 'occupied diagnostic destination');
		}
		if (fixture.phase === 'updater' || fixture.phase === 'complete') {
			assert.ok(result.stdout.startsWith(stdout), 'stdout bytes survive the tee unchanged');
			assert.ok(
				fixture.blocked ? result.stderr.includes(stderr) : result.stderr.startsWith(stderr),
				'stderr bytes survive the tee unchanged'
			);
			if (!fixture.blocked) {
				assert.strictEqual(
					fs.readFileSync(path.join(evidence, 'updater.stdout.log'), 'utf8'),
					stdout
				);
				assert.strictEqual(
					fs.readFileSync(path.join(evidence, 'updater.stderr.log'), 'utf8'),
					stderr
				);
			}
			const cleanup = spawnSync(bashExecutable(), ['-c', 'test ! -d "$UPDATER_TEST_WORK"'], {
				encoding: 'utf8',
				env: { ...process.env, UPDATER_TEST_WORK: fs.readFileSync(workReport, 'utf8') }
			});
			assert.strictEqual(cleanup.status, 0, 'the exact owned work directory is still cleaned');
		}
		if (fixture.status) assert.match(result.stderr, /::error title=Linux updater live::/);
		else assert.doesNotMatch(result.stderr, /::error/);
	}
} finally {
	fs.rmSync(updaterScratch, { recursive: true, force: true });
}

function fixtures() {
	const needs = {};
	const evidence = [];
	for (const [job, contract] of Object.entries(MANIFEST.jobs)) {
		needs[job] = { result: 'success' };
		for (const [subject, count] of Object.entries(contract.subjects))
			evidence.push({
				schema_version: 1,
				job,
				sha: SHA,
				architecture: 'X64',
				distro: 'test-distro',
				session: 'headless',
				interpreter: 'LuaJIT 2.1',
				subjects: { [subject]: count }
			});
	}
	return { needs, evidence };
}

function rejects(mutate, pattern) {
	const state = fixtures();
	mutate(state);
	assert.throws(
		() =>
			verifyAggregate({
				manifest: MANIFEST,
				needs: state.needs,
				evidence: state.evidence,
				expectedSha: SHA
			}),
		pattern
	);
}

verifyAggregate({ manifest: MANIFEST, ...fixtures(), expectedSha: SHA });

for (const job of Object.keys(MANIFEST.jobs)) {
	for (const result of ['failure', 'cancelled', 'skipped', null]) {
		rejects(({ needs }) => {
			needs[job].result = result;
		}, /mandatory job .* concluded/);
	}
}
rejects(({ needs }) => {
	delete needs['test-linux'];
}, /mandatory job test-linux is missing/);
rejects(({ evidence }) => {
	evidence[0].subjects.unit = 0;
}, /no positive executed assertion count/);
rejects(({ evidence }) => {
	delete evidence[0].subjects.unit;
}, /has no evidence for unit/);
rejects(({ evidence }) => {
	evidence[0].sha = 'wrong';
}, /evidence belongs to wrong/);
rejects(({ evidence }) => {
	evidence[0].subjects.unknown = 1;
}, /unclassified subject/);
rejects(({ evidence }) => {
	evidence[0].job = 'unknown';
}, /unclassified job/);
rejects(({ evidence }) => {
	evidence.push({ ...evidence[0] });
}, /duplicate evidence/);
rejects(({ needs }) => {
	needs.unclassified = { result: 'success' };
}, /unclassified Linux job/);

// The gate lives in the Linux box: toJSON(needs) only sees the jobs of its own
// workflow, so from ci.yml it would hold nothing but "linux".
assert.strictEqual(
	GATE.file,
	LINUX_BOX,
	`linux-ok must live in ${LINUX_BOX}, found in ${GATE.file}`
);
assert.match(GATE.body, /node tools\/test\/linux-ci-evidence\.cjs verify/);
assert.match(GATE.body, /pattern:\s*linux-ci-evidence-\*/);
assert.match(GATE.body, /NEEDS:\s*\$\{\{\s*toJSON\(needs\)\s*\}\}/);
assert.strictEqual(
	pipeline.field(GATE.body, 'if'),
	'always()',
	'linux-ok must run after a failed or skipped lane to name it'
);
// needs decides what the gate waits for, the manifest what it fails on. verify
// rejects drift between the two at run time; this fails the same drift locally.
assert.deepStrictEqual(
	[...pipeline.needsOf(GATE.body)].sort(),
	Object.keys(MANIFEST.jobs).sort(),
	'linux-ok needs and .github/linux-ci-coverage.json jobs must name the same Linux jobs'
);
for (const job of Object.keys(MANIFEST.jobs)) {
	assert.strictEqual(
		pipeline.locate(job).file,
		LINUX_BOX,
		`manifest job ${job} must be a job of ${LINUX_BOX}`
	);
}
// The unavailable-environment branches still exist and fail closed; the bans
// below then inspect live text rather than a branch that was deleted.
assert.match(WORKFLOW, /no Wayland socket appeared[^\n]*[\s\S]{0,180}exit 1/);
assert.match(WORKFLOW, /WebKit\/lgi unavailable[^\n]*[\s\S]{0,180}exit 1/);
assert.doesNotMatch(WORKFLOW, /all \$total job\(s\) passed \(or skipped\)/);
assert.doesNotMatch(WORKFLOW, /no Wayland socket appeared[^\n]*[\s\S]{0,180}exit 0/);
assert.doesNotMatch(WORKFLOW, /WebKit\/lgi unavailable[^\n]*[\s\S]{0,180}exit 0/);

// Native physical admission must retain its real X11 group/map evidence.
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['xkb-source-qualification'], 26);
rejects(({ evidence }) => {
	const document = evidence.find((row) => 'xkb-source-qualification' in row.subjects);
	delete document.subjects['xkb-source-qualification'];
}, /has no evidence for xkb-source-qualification/);
const sourceStep = pipeline.step(
	pipeline.job('e2e-linux'),
	'Qualify actual X11 physical shortcut sources'
);
assert.match(
	pipeline.stepField(sourceStep, 'run') ?? '',
	/run_xkb_source_qualification\.lua \| tee "\$RUNNER_TEMP\/linux-xkb-source\.log"/
);
assert.match(pipeline.stepField(sourceStep, 'run') ?? '', /set -euo pipefail/);
const nativeRecord =
	pipeline.stepField(
		pipeline.step(pipeline.job('e2e-linux'), 'Record mandatory E2E evidence'),
		'run'
	) ?? '';
assert.match(nativeRecord, /xkb_source_assertions=\$\(sed[^\n]+linux-xkb-source\.log/);
assert.match(nativeRecord, /--subject "xkb-source-qualification=\$xkb_source_assertions"/);

// Every subject the per-job layout proved at ca1a4d64a is still required: the
// manifest and linux-ok's needs can shrink together, and verify would then
// accept a box that silently stopped proving something.
const MIN_SUBJECTS = 41;
const subjectCount = Object.values(MANIFEST.jobs).reduce(
	(count, contract) => count + Object.keys(contract.subjects).length,
	0
);
assert.ok(
	subjectCount >= MIN_SUBJECTS,
	`.github/linux-ci-coverage.json requires ${subjectCount} subject(s); the floor is ${MIN_SUBJECTS}`
);
// The six subjects of the former packaging jobs, now all proved by package-linux.
const PACKAGE_SUBJECTS = [
	'build-appimage',
	'build-deb',
	'build-flatpak',
	'build-rpm',
	'smoke-flatpak-run',
	'smoke-tarball-install'
];

// One graph block still owns every former installation and package-run row.
// Pin both the subjects and their execution environments: Docker first-run
// tests need a host runner, while rpm must resolve its own LuaJIT dependency.
const INSTALL_ROWS = [
	['distro-debian', 'install', 'debian:stable-slim'],
	['distro-fedora', 'install', 'fedora:latest'],
	['distro-arch', 'install', 'archlinux:latest'],
	['distro-alpine', 'install', 'alpine:latest'],
	['distro-opensuse', 'install', 'opensuse/tumbleweed:latest'],
	['first-install-ubuntu-22.04', 'first', 'ubuntu:22.04'],
	['first-install-ubuntu-24.04', 'first', 'ubuntu:24.04'],
	['first-install-debian-12', 'first', 'debian:12'],
	['first-install-debian-13', 'first', 'debian:13'],
	['first-install-fedora-41', 'first', 'fedora:41'],
	['first-install-fedora-latest', 'first', 'fedora:latest'],
	['first-install-arch', 'first', 'archlinux:latest'],
	['first-install-opensuse-tumbleweed', 'first', 'opensuse/tumbleweed:latest'],
	['first-install-alpine', 'first', 'alpine:latest'],
	['smoke-deb-install', 'deb', ''],
	['smoke-rpm-install', 'rpm', 'fedora:latest'],
	['smoke-appimage-run', 'appimage', '']
];

/**
 * Assert the single matrix retains every scenario and its host/container split.
 * @param {string} body Installation job body.
 */
function assertInstallMatrix(body) {
	assert.strictEqual(pipeline.field(body, 'container'), '${{ matrix.container }}');
	assert.deepStrictEqual(pipeline.needsOf(body), ['package-linux']);
	assert.match(body, /^      fail-fast: false$/m);
	const rows = [...body.matchAll(/^          - id: ([^\n]+)\n((?:            [^\n]*\n)+)/gm)];
	assert.deepStrictEqual(
		rows.map((row) => row[1]).sort(),
		INSTALL_ROWS.map((row) => row[0]).sort()
	);
	for (const [id, kind, image] of INSTALL_ROWS) {
		const row = rows.find((candidate) => candidate[1] === id)[2];
		const value = (key) =>
			row.match(new RegExp(`^            ${key}: (.*)$`, 'm'))?.[1].replace(/^'(.*)'$/, '$1');
		assert.strictEqual(value('kind'), kind, `${id} scenario`);
		assert.strictEqual(
			value('container'),
			['install', 'rpm'].includes(kind) ? image : '',
			`${id} container`
		);
		if (['install', 'first'].includes(kind))
			assert.strictEqual(value('image'), image, `${id} image`);
		if (id.startsWith('first-install-fedora-')) assert.strictEqual(value('known'), 'webkit');
	}
}

const installJob = pipeline.job('install-linux');
assertInstallMatrix(installJob);
assert.deepStrictEqual(
	Object.keys(MANIFEST.jobs['install-linux'].subjects).sort(),
	INSTALL_ROWS.map((row) => row[0]).sort()
);
assert.deepStrictEqual(
	pipeline
		.jobs(LINUX_BOX)
		.map((job) => job.id)
		.sort(),
	['e2e-linux', 'install-linux', 'linux-ok', 'package-linux', 'test-linux']
);
for (const [id] of INSTALL_ROWS) {
	rejects(({ evidence }) => {
		evidence.splice(
			evidence.findIndex((doc) => id in doc.subjects),
			1
		);
	}, /has no evidence for/);
	assert.throws(() =>
		assertInstallMatrix(
			installJob.replace(`          - id: ${id}\n`, `          - id: lost-${id}\n`)
		)
	);
}
assert.throws(() =>
	assertInstallMatrix(
		installJob.replace("            container: ''", '            container: ubuntu:24.04')
	)
);
const prepare = pipeline.step(installJob, 'Prepare the container');
assert.strictEqual(
	pipeline.stepField(prepare, 'shell'),
	'sh',
	'Alpine needs sh before bash is installed'
);
assert.ok(installJob.indexOf(prepare) < installJob.indexOf('      - uses: actions/checkout@v4'));
const installAsUser = pipeline.step(
	installJob,
	'Install as an ordinary user without runtime dependencies'
);
assert.deepStrictEqual(
	pipeline.runOf(installAsUser),
	[
		'set -euo pipefail',
		'# Model a login, not a nested sudo invocation whose SUDO_UID is root.',
		'sudo -H -u ergopti-ci env -u SUDO_UID -u SUDO_GID -u SUDO_USER bash install.sh --no-deps'
	],
	'the installer must configure a real desktop UID, never root with a substituted HOME'
);
const createUser = pipeline.step(installJob, 'Create the installation user');
assert.match(createUser, /test "\$\(id -u ergopti-ci\)" -ge 1000/);
assert.ok(installJob.indexOf(createUser) < installJob.indexOf(installAsUser));
for (const step of pipeline.steps(installJob)) {
	if (pipeline.runOf(step.body) && step.name !== 'Prepare the container') {
		assert.strictEqual(
			pipeline.stepField(step.body, 'shell'),
			'bash',
			`${step.name} requires pipefail-capable bash`
		);
	}
}

assert.deepStrictEqual(
	Object.keys(MANIFEST.jobs['package-linux']?.subjects ?? {}).sort(),
	PACKAGE_SUBJECTS,
	'package-linux must be the mandatory owner of the six packaging subjects'
);
const packageRecord = pipeline.step(
	pipeline.job('package-linux'),
	'Record mandatory package evidence'
);
for (const subject of PACKAGE_SUBJECTS) {
	assert.match(
		packageRecord,
		new RegExp(`--subject ${subject}=1\\b`),
		`package-linux must record the ${subject} subject`
	);
}

// A failed harness must not hide the ones after it (N2), and a cancelled run
// must not keep them running for minutes (always() did). Every step from the
// E2E harness to the evidence record runs under !cancelled(); the record and
// its upload run only when every harness passed.
const testLinuxSteps = pipeline.steps(pipeline.job('e2e-linux'));
const updaterStep = pipeline.step(
	pipeline.job('e2e-linux'),
	'Update to the newest release and restart'
);
/** The fixture token belongs only to the exact owned updater step. */
function assertUpdaterAuthentication(step) {
	assert.match(step, /^          GITHUB_TOKEN: \$\{\{ github\.token \}\}$/m);
	assert.strictEqual(pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
	assert.match(
		step,
		/^          bash static\/ergopti_plus\/linux\/tests\/hardware\/run_updater_live\.sh$/m
	);
}
assertUpdaterAuthentication(updaterStep);
assert.throws(() =>
	assertUpdaterAuthentication(
		updaterStep.replace('          GITHUB_TOKEN: ${{ github.token }}\n', '')
	)
);
assert.throws(() =>
	assertUpdaterAuthentication(
		updaterStep.replace('${{ github.token }}', '${{ secrets.PAT_ERGOPTI }}')
	)
);
assert.throws(() =>
	assertUpdaterAuthentication(updaterStep.replace('${{ !cancelled() }}', '${{ success() }}'))
);
assert.match(
	updaterStep,
	/^          ERGOPTI_UPDATER_LIVE_EVIDENCE_DIR: \$\{\{ runner\.temp \}\}\/linux-updater-live$/m
);
const updaterEvidence = pipeline.step(
	pipeline.job('e2e-linux'),
	'Upload live updater diagnostic evidence'
);

/**
 * Keep failed updater observations separate from mandatory success receipts.
 * @param {string} step The diagnostic artifact upload step.
 */
function assertUpdaterEvidence(step) {
	assert.strictEqual(pipeline.stepField(step, 'if'), '${{ !cancelled() }}');
	assert.strictEqual(pipeline.stepField(step, 'uses'), 'actions/upload-artifact@v4');
	assert.strictEqual(pipeline.stepField(step, 'continue-on-error'), null);
	assert.match(step, /^          name: linux-updater-live-diagnostics$/m);
	assert.match(step, /^          path: \$\{\{ runner\.temp \}\}\/linux-updater-live$/m);
	assert.match(step, /^          if-no-files-found: error$/m);
}
assertUpdaterEvidence(updaterEvidence);
assert.throws(() =>
	assertUpdaterEvidence(updaterEvidence.replace('${{ !cancelled() }}', '${{ success() }}'))
);
assert.throws(() =>
	assertUpdaterEvidence(
		updaterEvidence.replace('linux-updater-live-diagnostics', 'linux-ci-evidence-e2e-linux')
	)
);
assert.throws(() =>
	assertUpdaterEvidence(
		updaterEvidence.replace('if-no-files-found: error', 'if-no-files-found: ignore')
	)
);
assert.ok(
	pipeline.job('e2e-linux').indexOf(updaterStep) <
		pipeline.job('e2e-linux').indexOf(updaterEvidence)
);
const unitAt = testLinuxSteps.findIndex((candidate) => candidate.name === 'Install LuaJIT');
const recordAt = testLinuxSteps.findIndex(
	(candidate) => candidate.name === 'Record mandatory E2E evidence'
);
assert.ok(
	unitAt >= 0 && recordAt > unitAt + 1,
	'test-linux must run its harnesses between the unit suite and the record'
);
assert.strictEqual(
	testLinuxSteps[unitAt + 1].name,
	'Run virtual-keyboard E2E harness (stubbed)',
	'the stubbed E2E harness must run right after the unit suite'
);
for (const harness of testLinuxSteps.slice(unitAt + 1, recordAt)) {
	assert.strictEqual(
		pipeline.stepField(harness.body, 'if'),
		'${{ !cancelled() }}',
		`test-linux step "${harness.name}" must run under if: \${{ !cancelled() }}`
	);
}
for (const tail of testLinuxSteps.slice(recordAt)) {
	assert.strictEqual(
		pipeline.stepField(tail.body, 'if'),
		null,
		`test-linux step "${tail.name}" must run only when every harness passed`
	);
}
for (const boxJob of pipeline.jobs(LINUX_BOX)) {
	for (const boxStep of pipeline.steps(boxJob.body)) {
		assert.doesNotMatch(
			pipeline.stepField(boxStep.body, 'if') ?? '',
			/\balways\(\)/,
			`${boxJob.id} step "${boxStep.name}" must use !cancelled(), not always(), so a cancelled run stops`
		);
	}
}

// Three subjects are counts, and each must be read from what its suite printed:
// a literal count keeps a floor satisfied by a suite that ran nothing. Every
// other subject is the literal 1 of a step that passed. That no step before a
// record can be skipped, or swallow a failure with `|| true` or a `| tee`
// without pipefail, is pinned pipeline-wide by
// tools/test/test-ci-pipeline-wiring.cjs.
const testLinux = pipeline.job('test-linux');
assert.match(
	pipeline.stepField(pipeline.step(testLinux, 'Run the driver unit test suite'), 'run') ?? '',
	/^node \.\.\/\.\.\/\.\.\/tools\/test\/report\.cjs --name linux-lua --json "\$\{\{ runner\.temp \}\}\/linux-lua\.json" -- luajit tests\/run\.lua$/,
	'the unit suite must write the report its evidence counts'
);
assert.ok(
	(
		pipeline.runOf(
			pipeline.step(pipeline.job('e2e-linux'), 'Run virtual-keyboard E2E harness (stubbed)')
		) ?? []
	).includes('luajit tests/e2e/run_e2e.lua | tee "$RUNNER_TEMP/linux-e2e.log"'),
	'the stubbed E2E harness must keep the log its evidence counts'
);
const unitRecord = pipeline.runOf(pipeline.step(testLinux, 'Record mandatory unit evidence')) ?? [];
const e2eRecord =
	pipeline.runOf(pipeline.step(pipeline.job('e2e-linux'), 'Record mandatory E2E evidence')) ?? [];
const recordScript = [...unitRecord, ...e2eRecord];
for (const line of [
	'unit_assertions=$(jq -r \'.passed\' "$RUNNER_TEMP/linux-lua.json")',
	'e2e_assertions=$(sed -n \'s/^1\\.\\.\\([0-9][0-9]*\\)$/\\1/p\' "$RUNNER_TEMP/linux-e2e.log" | tail -1)',
	'xkb_source_assertions=$(sed -n \'s/^=== \\([0-9][0-9]*\\) check(s), 0 failure(s) ===$/\\1/p\' "$RUNNER_TEMP/linux-xkb-source.log" | tail -1)'
]) {
	assert.ok(
		recordScript.includes(line),
		`the test-linux evidence must read its count with: ${line}`
	);
}
assert.ok(
	recordScript.includes(
		'network_runtime_assertions=$(node tools/test/linux-network-runtime-evidence.cjs "$RUNNER_TEMP/linux-network-runtime.log")'
	),
	'the actual runtime count must come from its independently validated native receipt'
);
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['managed-network-runtime'], 4);
const recorded = [...recordScript.join('\n').matchAll(/--subject "?([a-z0-9-]+)=([^\s"]+)"?/g)];
assert.deepStrictEqual(
	recorded.map((match) => match[1]).sort(),
	[
		...Object.keys(MANIFEST.jobs['test-linux'].subjects),
		...Object.keys(MANIFEST.jobs['e2e-linux'].subjects)
	].sort(),
	'the test-linux record must name exactly the manifest subjects of test-linux'
);
for (const [, subject, value] of recorded) {
	const expected =
		{
			unit: '$unit_assertions',
			'hotstring-e2e': '$e2e_assertions',
			'xkb-source-qualification': '$xkb_source_assertions',
			'http-stream-receipts': '$http_stream_assertions',
			'managed-network-runtime': '$network_runtime_assertions'
		}[subject] ?? '1';
	assert.strictEqual(
		value,
		expected,
		`the test-linux subject ${subject} must record ${expected}, got ${value}`
	);
}

process.stdout.write('PASS: Linux CI requires successful jobs and complete assertion evidence.\n');
