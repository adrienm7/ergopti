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
// The live probe now loads the real Linux pause owner before any check.
// These injected refusal observers must resolve driver and shared modules.
const updaterLuaPath =
	[
		path.join(updaterDriver, '?.lua'),
		path.join(updaterDriver, '?/init.lua'),
		path.join(ROOT, 'static/ergopti_plus/_shared/lua/?.lua'),
		path.join(ROOT, 'static/ergopti_plus/_shared/lua/?/init.lua')
	].join(';') + ';;';
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
 info = function() end,
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
			"local driver = assert(arg[1], 'authentication fixture needs the explicit driver root')",
			`-- These are deterministic simulated pipe/ENOENT receipts, not native-wire evidence.
uv.constants = { O_RDONLY = 0, O_NONBLOCK = 2048 }
native.descriptors, native.next_fd = {}, 6000
function uv.pipe(read_options, write_options)
 assert(read_options.nonblock == true and write_options.nonblock == true, 'conditional pipe lost nonblocking admission')
 native.next_fd = native.next_fd + 2
 local read_fd, write_fd = native.next_fd, native.next_fd + 1
 native.descriptors[read_fd] = { peer = write_fd, direction = 'read', inode = read_fd }
 native.descriptors[write_fd] = { peer = read_fd, direction = 'write', inode = read_fd }
 return { read = read_fd, write = write_fd }
end
function uv.fs_fstat(fd)
 local descriptor = assert(native.descriptors[fd], 'fixture observed an unowned descriptor')
 assert(not descriptor.closed, 'fixture reused a closed descriptor')
 return { dev = 1, ino = descriptor.inode, type = 'fifo' }
end
function uv.pipe_open(handle, fd)
 local descriptor = assert(native.descriptors[fd], 'fixture attached an unowned descriptor')
 assert(not descriptor.closed and descriptor.handle == nil and handle.fd == nil, 'fixture repeated descriptor transfer')
 descriptor.handle, handle.fd = handle, fd
 return true
end
function uv.fs_open(filename, flags, mode)
 assert((filename == '/owned/etag-in' or filename == '/owned/etag-out') and flags == 2048 and mode == 0, 'conditional snapshot escaped its original missing-file fixture')
 return nil, 'ENOENT', 'ENOENT'
end
function uv.fs_read() error('missing validator file cannot yield owned reads') end
function uv.fs_close(fd)
 local descriptor = assert(native.descriptors[fd], 'fixture closed an unowned descriptor')
 assert(not descriptor.closed and descriptor.handle == nil, 'fixture closed a transferred descriptor twice')
 descriptor.closed = true
 return true
end
local driver = assert(arg[1], 'authentication fixture needs the explicit driver root')`
		)
		.replace(
			"assert((argv:find('--location', 1, true) == nil) == (expected[2] and os.getenv('GITHUB_ACTIONS') == 'true'), 'native curl redirect policy escaped authentication scope')",
			`-- Literal eligibility of the unchanged seven authored managedCases, independent of candidate URL parsing.
 local hop_eligible = { true, true, true, true, true, true, false }
 assert(#rows == 7 and type(hop_eligible[count]) == 'boolean', 'managed dispatch inventory lost its literal seven-case eligibility')
 local follows = not (expected[2] and os.getenv('GITHUB_ACTIONS') == 'true')
 if hop_eligible[count] or not follows then
  assert(not argv:find('--location', 1, true), 'managed conditional request must retain sole per-hop redirect ownership')
 else
  assert(argv:find('--location', 1, true), 'literal userinfo exclusion lost original native-follow ownership')
 end
 if hop_eligible[count] then
  assert((argv:find('ERGOPTI_GET_REDIRECT_JSON:', 1, true) ~= nil) == follows, 'managed native receipt lost original caller redirect permission')
 else
  assert(not argv:find('ERGOPTI_GET_REDIRECT_JSON:', 1, true), 'literal userinfo exclusion acquired a managed-hop receipt')
 end
 assert(argv:find('--dump-header\\n/dev/fd/4', 1, true), 'conditional response lost its exact FD4 header destination')
 assert(native.pipes[4] == nil and type(native.pipes[5]) == 'table', 'buffered GET header FD4 collided with body FD3')
 local writer = native.descriptors[assert(native.pipes[5].fd)]
 local reader = native.descriptors[writer.peer]
 assert(writer.direction == 'write' and writer.closed and reader.direction == 'read' and reader.handle and not reader.closed, 'conditional pipe transfer or parent writer close was not acknowledged')`
		)
		.replace(
			"function uv.kill() error('completed receipt must not cancel a live successor') end",
			`function uv.kill(pid, signal)
 assert(pid == -native.group and signal == 0, 'managed group observation targeted another owner')
 assert(native.absent_group == native.group, 'leader exit alone is not group retirement')
 return nil, 'ESRCH', 'ESRCH'
end`
		)
		.replace(
			'native.requests = native.requests + 1',
			`native.requests = native.requests + 1
 native.group, native.absent_group = 4000 + native.requests, nil`
		)
		.replace(
			'native.pipes[3].read(nil, nil)',
			`if http_status == 304 and follows and hop_eligible[count] then
  -- Literal terminal304 endpoints of the original seven cases, not native-argv-derived metadata.
  local final_urls = {
   'https://api.github.com/repos/adrienm7/ergopti/releases',
   'https://api.github.com/repos/adrienm7/ergopti/releases?per_page=20&page=2',
   'https://api.github.com/repos/fixture-owner/other-project/releases',
   'https://release-assets.githubusercontent.com/package.tar.gz',
   'https://API.GITHUB.COM/repos/adrienm7/ergopti/releases',
   'https://api.github.com.evil.invalid/repos/adrienm7/ergopti/releases',
   'https://user:password@api.github.com/repos/adrienm7/ergopti/releases',
  }
  local final_url = assert(final_urls[count], 'literal conditional final endpoint inventory changed')
  assert(url == final_url, 'conditional request differs from independently authored terminal endpoint')
  local terminal = { http_code = 304, response_code = 304, exitcode = 0,
   num_redirects = 0, url_effective = final_url, redirect_url = '' }
  native.pipes[3].read(nil, '\\nERGOPTI_GET_REDIRECT_JSON:\\n' .. final_url .. '\\n\\n' .. Json.encode(terminal) .. '\\n')
 end
 native.pipes[3].read(nil, nil)`
		)
		.replace(
			'native.exit(http_status >= 400 and 22 or 0, 0)',
			`-- Distinct exact-group model receipt, independent of leader/stream ACKs.
 native.absent_group = native.group
 native.exit(http_status >= 400 and 22 or 0, 0)
 -- Child/group and both ordinary stream receipts cannot replace FD4 EOF.
 assert(not delivered, 'managed callback borrowed completion without conditional header EOF')
 reader.handle.read(nil, 'HTTP/1.1 ' .. http_status .. ' Fixture\\r\\nContent-Length: ' .. #response_body .. '\\r\\n\\r\\n')
 assert(not delivered, 'managed callback borrowed header bytes without exact header EOF')
 reader.handle.read(nil, nil)`
		)
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
 if handle.fd then
  local descriptor = assert(native.descriptors[handle.fd], 'managed close lost the attached conditional descriptor')
  assert(descriptor.handle == handle and not descriptor.closed, 'managed close borrowed another descriptor receipt')
  descriptor.closed = true
 end
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
 assert(native.acquired == native.closed, 'managed public completion lost a physical close ACK')
 for _, descriptor in pairs(native.descriptors) do
  assert(descriptor.closed and descriptor.handle and descriptor.handle.closed, 'managed public completion lost conditional descriptor retirement')
 end`
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
				LUA_PATH: updaterLuaPath,
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
				LUA_PATH: updaterLuaPath,
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
				LUA_PATH: updaterLuaPath,
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

// Native cursor-display receipts include the actual scoped dispatcher.
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['window-switch-receipts'], 34);
rejects(({ evidence }) => {
	const document = evidence.find((row) => 'window-switch-receipts' in row.subjects);
	delete document.subjects['window-switch-receipts'];
}, /has no evidence for window-switch-receipts/);
rejects(({ evidence }) => {
	const document = evidence.find((row) => 'window-switch-receipts' in row.subjects);
	document.subjects['window-switch-receipts'] = 33;
}, /window-switch-receipts recorded 33 assertion/);
assert.match(nativeRecord, /window_switch_assertions=\$\(sed[^\n]+linux-window-switch\.log/);
assert.match(nativeRecord, /--subject "window-switch-receipts=\$window_switch_assertions"/);

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
// --no-deps is deliberately preserved: these five source installs require a
// compiler supplied by their caller, whereas first-run provisioning belongs
// to the real installer. Runtime packages must remain absent from preparation.
for (const [id, buildPackages] of [
	['distro-debian', ['gcc', 'libc6-dev']],
	['distro-fedora', ['gcc', 'glibc-devel']],
	['distro-arch', ['gcc', 'glibc']],
	['distro-alpine', ['gcc', 'musl-dev', 'linux-headers']],
	['distro-opensuse', ['gcc', 'glibc-devel']]
]) {
	const entry = installJob.match(
		new RegExp(`^          - id: ${id}\\n([\\s\\S]*?)(?=^          - id:|^    container:)`, 'm')
	);
	assert.ok(entry, `Missing original source-install lane: ${id}`);
	const prep = entry[1].match(/^            prep: (.+)$/m);
	assert.ok(prep, `Missing actual preparation: ${id}`);
	const words = prep[1].split(/\s+/);
	for (const pkg of buildPackages)
		assert.ok(words.includes(pkg), `${id} lacks source-build prerequisite ${pkg}`);
	assert.ok(!words.includes('luajit'), `${id} preparation hides a missing runtime dependency`);
}
const firstInstallFixture = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/linux/tests/distro/e2e_install.sh'),
	'utf8'
);
assert.match(firstInstallFixture, /^mkdir -p "\$\{E2E_HOME\}\/ergopti\/tools\/build"$/m);
assert.match(
	firstInstallFixture,
	/^cp "\$\{SRC\}\/tools\/build\/build-linux-native-output\.sh" "\$\{E2E_HOME\}\/ergopti\/tools\/build\/"$/m
);
assert.ok(
	firstInstallFixture.indexOf('cp "${SRC}/tools/build/build-linux-native-output.sh"') <
		firstInstallFixture.indexOf('section "Installer"')
);
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
// Manual diagnostics can qualify packages after failed E2E receiving, while
// both the mandatory verdict and automatic release admission remain strict.
const manualPackageJob = pipeline.job('package-linux');
assert.deepStrictEqual(pipeline.needsOf(manualPackageJob), ['e2e-linux']);
assert.deepStrictEqual(pipeline.needsOf(pipeline.job('e2e-linux')), ['test-linux']);
assert.strictEqual(pipeline.field(pipeline.job('e2e-linux'), 'if'), null);
assert.strictEqual(
	pipeline.field(manualPackageJob, 'if'),
	"${{ !cancelled() && (needs.e2e-linux.result == 'success' || (github.event_name == 'workflow_dispatch' && needs.e2e-linux.result == 'failure')) }}",
	'manual packaging must retain unit admission, cancellation and automatic E2E admission'
);
// The frozen acceptance table is independent of the workflow expression.
// Evaluate only after the exact source guard above admits this closed predicate.
const diagnosticEvents = ['push', 'pull_request', 'workflow_dispatch', 'schedule', 'unknown'];
const diagnosticResults = ['success', 'failure', 'cancelled', 'skipped', null, 'unknown'];
const admittedPackageCases = new Set([
	'push:success:false',
	'pull_request:success:false',
	'workflow_dispatch:success:false',
	'workflow_dispatch:failure:false',
	'schedule:success:false',
	'unknown:success:false'
]);
const diagnosticExpression = pipeline
	.field(manualPackageJob, 'if')
	.slice(3, -2)
	.replace('needs.e2e-linux.result', "needs['e2e-linux'].result")
	.replace('needs.e2e-linux.result', "needs['e2e-linux'].result");
let diagnosticCaseCount = 0;
for (const event of diagnosticEvents) {
	for (const result of diagnosticResults) {
		for (const cancelled of [false, true]) {
			const actual = require('node:vm').runInNewContext(
				diagnosticExpression,
				{
					cancelled: () => cancelled,
					needs: { 'e2e-linux': { result } },
					github: { event_name: event }
				},
				{ timeout: 100 }
			);
			assert.strictEqual(actual, admittedPackageCases.has(`${event}:${result}:${cancelled}`));
			diagnosticCaseCount++;
		}
	}
}
assert.strictEqual(diagnosticCaseCount, 60);

assert.strictEqual(
	pipeline.field(pipeline.job('release'), 'if'),
	"github.event_name == 'push' && needs.validate.outputs.release == 'true'",
	'manual package diagnostics must never publish a release'
);
rejects(({ needs }) => {
	assert.strictEqual(needs['package-linux'].result, 'success');
	needs['e2e-linux'].result = 'failure';
}, /mandatory job e2e-linux concluded/);

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

// Native/unit subject counts must be read from what their suites printed:
// a literal count keeps a floor satisfied by a suite that ran nothing. Every
// other subject is the literal 1 of a step that passed. That no step before a
// record can be skipped, or swallow a failure with `|| true` or a `| tee`
// without pipefail, is pinned pipeline-wide by
// tools/test/test-ci-pipeline-wiring.cjs.
const testLinux = pipeline.job('test-linux');
/**
 * Requires the actual original unit reporter and its immediate pipeline receipt.
 * @param {string} job The actual test-linux job from the canonical pipeline loader.
 */
function assertLinuxUnitFailureLog(job) {
	const unit = pipeline.step(job, 'Run the driver unit test suite');
	assert.strictEqual(pipeline.stepField(unit, 'working-directory'), 'static/ergopti_plus/linux');
	assert.strictEqual(pipeline.stepField(unit, 'id'), 'linux_unit');
	assert.strictEqual(pipeline.stepField(unit, 'shell'), 'bash');
	assert.strictEqual(pipeline.stepField(unit, 'if'), null);
	assert.strictEqual(pipeline.stepField(unit, 'continue-on-error'), null);
	const code = pipeline.runOf(unit);
	assert.ok(Array.isArray(code) && code.length === 7, 'the original unit pipeline must be present');
	const capture = ' 2>&1 | tee "$RUNNER_TEMP/linux-unit.log"';
	assert.ok(code[2].endsWith(capture), 'both public streams reach the single log');
	const reporter = code[2].slice(0, -capture.length);
	assert.match(
		reporter,
		/^node \.\.\/\.\.\/\.\.\/tools\/test\/report\.cjs --name linux-lua --json "\$\{\{ runner\.temp \}\}\/linux-lua\.json" -- luajit tests\/run\.lua$/,
		'the unit suite must write the report its evidence counts'
	);
	assert.deepStrictEqual(
		code,
		[
			'set -euo pipefail',
			'set +e',
			reporter + capture,
			'unit_pipeline_status=("${PIPESTATUS[@]}")',
			'set -e',
			'if [ "${unit_pipeline_status[0]}" -ne 0 ]; then exit "${unit_pipeline_status[0]}"; fi',
			'exit "${unit_pipeline_status[1]}"'
		],
		'capture both statuses immediately; retain the reporter failure and refuse a failed log sink'
	);
	const upload = pipeline.step(job, 'Upload failed unit log');
	assert.strictEqual(
		pipeline.stepField(upload, 'if'),
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	);
	assert.strictEqual(pipeline.stepField(upload, 'uses'), 'actions/upload-artifact@v4');
	assert.strictEqual(pipeline.stepField(upload, 'continue-on-error'), null);
	assert.match(upload, /^          name: linux-unit-failure-log$/m);
	assert.match(upload, /^          retention-days: 7$/m);
	assert.match(upload, /^          path: \$\{\{ runner\.temp \}\}\/linux-unit\.log$/m);
	assert.match(upload, /^          if-no-files-found: error$/m);
	const steps = pipeline.steps(job);
	const at = steps.findIndex((step) => step.name === 'Run the driver unit test suite');
	assert.strictEqual(steps[at + 1]?.name, 'Upload failed unit log');
}
assertLinuxUnitFailureLog(testLinux);
// Build every altered source before the expected rejection: a missing anchor is red.
const unitLogMutations = [
	['set -euo pipefail', 'set -eu'],
	['unit_pipeline_status=("${PIPESTATUS[@]}")', 'unit_pipeline_status=("$?")'],
	[
		'unit_pipeline_status=("${PIPESTATUS[@]}")\n          set -e',
		'set -e\n          unit_pipeline_status=("${PIPESTATUS[@]}")'
	],
	['then exit "${unit_pipeline_status[0]}"', 'then exit 0'],
	['exit "${unit_pipeline_status[1]}"', 'exit 0'],
	['-- luajit tests/run.lua 2>&1 | tee', '-- luajit tests/run.lua || true 2>&1 | tee'],
	['-- luajit tests/run.lua 2>&1 | tee', '-- luajit tests/run.lua | tee'],
	['working-directory: static/ergopti_plus/linux', 'working-directory: static/ergopti_plus'],
	["failure() && !cancelled() && steps.linux_unit.outcome == 'failure'", 'success()'],
	["failure() && !cancelled() && steps.linux_unit.outcome == 'failure'", 'failure()'],
	['path: ${{ runner.temp }}/linux-unit.log', 'path: ${{ runner.temp }}'],
	['if-no-files-found: error', 'if-no-files-found: ignore']
];
assert.strictEqual(
	unitLogMutations.length,
	12,
	'all independent diagnostic wiring mutations are present'
);
for (const [from, to] of unitLogMutations) {
	const unit = pipeline.step(testLinux, 'Run the driver unit test suite');
	const upload = pipeline.step(testLinux, 'Upload failed unit log');
	const target = unit.includes(from) ? unit : upload;
	assert.strictEqual(
		target.split(from).length - 1,
		1,
		'the actual diagnostic mutation anchor is unique'
	);
	assert.strictEqual(testLinux.split(target).length - 1, 1, 'the selected actual step is unique');
	const changed = testLinux.replace(target, () => target.replace(from, () => to));
	assert.notStrictEqual(changed, testLinux);
	assert.throws(() => assertLinuxUnitFailureLog(changed));
}
/**
 * Keeps the original unit and upload intact, then annotates only their own log.
 * @param {string} job Actual test-linux job from the canonical pipeline loader.
 */
function assertLinuxUnitFailureExcerpt(job) {
	assertLinuxUnitFailureLog(job);
	const excerpt = pipeline.step(job, 'Emit Configuration assertion from failed unit log');
	assert.strictEqual(
		pipeline.stepField(excerpt, 'if'),
		"${{ failure() && !cancelled() && steps.linux_unit.outcome == 'failure' }}"
	);
	assert.strictEqual(pipeline.stepField(excerpt, 'shell'), 'bash');
	assert.strictEqual(pipeline.stepField(excerpt, 'working-directory'), null);
	assert.strictEqual(pipeline.stepField(excerpt, 'continue-on-error'), null);
	assert.strictEqual(pipeline.stepField(excerpt, 'uses'), null);
	assert.deepStrictEqual(pipeline.runOf(excerpt), [
		'node tools/test/linux-unit-failure-excerpt.cjs "$RUNNER_TEMP/linux-unit.log"'
	]);
	const steps = pipeline.steps(job);
	const uploadAt = steps.findIndex((step) => step.name === 'Upload failed unit log');
	assert.strictEqual(
		steps[uploadAt + 1]?.name,
		'Emit Configuration assertion from failed unit log'
	);
	const nativeSteps = steps.slice(uploadAt + 2, uploadAt + 5);
	assert.deepStrictEqual(
		nativeSteps.map((step) => step.name),
		[
			'Saved ordered-pair Manager — early genuine native source lifetimes',
			'Saved ordered-pair Manager — independent observation after failed units',
			'Run manual official runtime and model acceptance'
		],
		'only the exact two independent native observations may precede unchanged manual IA'
	);
	const managerScript = [
		'set -euo pipefail',
		'if ! command -v Xvfb >/dev/null; then',
		"  echo 'ENVIRONMENT: early saved-pair Manager prerequisite refused: Xvfb is absent' >&2",
		'  exit 2',
		'fi',
		'sudo modprobe uinput',
		'if sudo python3 tests/hardware/run_manager_input_owner_real.py > "$RUNNER_TEMP/linux-manager-input-owner-early.log" 2>&1; then',
		'  manager_status=0',
		'else',
		'  manager_status=$?',
		'fi',
		'cat "$RUNNER_TEMP/linux-manager-input-owner-early.log"',
		'exit "$manager_status"'
	];
	for (const [index, outcome] of ['success', 'failure'].entries()) {
		const body = nativeSteps[index].body;
		assert.strictEqual(
			pipeline.stepField(body, 'if'),
			"${{ !cancelled() && steps.linux_unit.outcome == '" + outcome + "' }}"
		);
		assert.strictEqual(pipeline.stepField(body, 'continue-on-error'), null);
		assert.strictEqual(pipeline.stepField(body, 'timeout-minutes'), '3');
		assert.strictEqual(pipeline.stepField(body, 'working-directory'), 'static/ergopti_plus/linux');
		assert.strictEqual(pipeline.stepField(body, 'shell'), null);
		assert.strictEqual(pipeline.stepField(body, 'env'), null);
		const expected =
			index === 0
				? managerScript
				: managerScript.map((line) =>
						line.replaceAll(
							'linux-manager-input-owner-early.log',
							'linux-manager-input-owner-unit-failure.log'
						)
					);
		assert.deepStrictEqual(
			pipeline.runOf(body),
			expected,
			'the independent native observations retain genuine prerequisites and original native exit'
		);
	}
	const manual = nativeSteps[2].body;
	assert.strictEqual(
		pipeline.stepField(manual, 'if'),
		"${{ github.event_name == 'workflow_dispatch' && !inputs.release && !cancelled() }}"
	);
	assert.strictEqual(pipeline.stepField(manual, 'continue-on-error'), null);
	assert.strictEqual(pipeline.stepField(manual, 'timeout-minutes'), '18');
	assert.deepStrictEqual(pipeline.runOf(manual), [
		'set -euo pipefail',
		'sudo python3 "$GITHUB_WORKSPACE/tools/ci/ubuntu_apt.py" -y --no-install-recommends curl zstd',
		'python3 static/ergopti_plus/linux/tests/hardware/run_ollama_runtime_acceptance.py \\',
		'  --repository "$GITHUB_WORKSPACE" \\',
		'  --evidence "$RUNNER_TEMP/ollama-runtime-acceptance" \\',
		'  --lua luajit'
	]);
}
assertLinuxUnitFailureExcerpt(testLinux);
for (const name of [
	'Saved ordered-pair Manager — early genuine native source lifetimes',
	'Saved ordered-pair Manager — independent observation after failed units'
]) {
	const step = pipeline.step(testLinux, name);
	for (const [label, altered] of [
		['omitted native observation', ''],
		['duplicated native observation', step + '\n\n' + step],
		['disabled native observation', step.replace(pipeline.stepField(step, 'if'), 'false')],
		[
			'wrong native observation outcome',
			step
				.replace("outcome == 'success'", "outcome == 'skipped'")
				.replace("outcome == 'failure'", "outcome == 'skipped'")
		],
		['forgiven native observation', step + '\n        continue-on-error: true'],
		[
			'native fixture replaced',
			step.replace('sudo python3 tests/hardware/run_manager_input_owner_real.py', 'true')
		],
		['kernel module load omitted', step.replace('sudo modprobe uinput', 'true')],
		[
			'kernel module load forgiven',
			step.replace('sudo modprobe uinput', 'sudo modprobe uinput || true')
		],
		['native status replaced', step.replace('manager_status=$?', 'manager_status=0')],
		['native exit forged', step.replace('exit "$manager_status"', 'exit 0')],
		['missing Xvfb passed', step.replace('exit 2', 'exit 0')],
		['native clock increased', step.replace('timeout-minutes: 3', 'timeout-minutes: 4')],
		['native shell replaced', step + '\n        shell: bash -c true']
	]) {
		assert.strictEqual(
			testLinux.split(step).length - 1,
			1,
			'the actual native observation must occur once'
		);
		const changed = testLinux.replace(step, () => altered);
		assert.notStrictEqual(changed, testLinux, label);
		assert.throws(() => assertLinuxUnitFailureExcerpt(changed), label);
	}
}
const successNativeStep = pipeline.step(
	testLinux,
	'Saved ordered-pair Manager — early genuine native source lifetimes'
);
const failureNativeStep = pipeline.step(
	testLinux,
	'Saved ordered-pair Manager — independent observation after failed units'
);
const nativeOrderMarker = '__ERGOPTI_NATIVE_OBSERVATION_ORDER__';
assert.ok(!testLinux.includes(nativeOrderMarker));
const swappedNativeObservations = testLinux
	.replace(successNativeStep, () => nativeOrderMarker)
	.replace(failureNativeStep, () => successNativeStep)
	.replace(nativeOrderMarker, () => failureNativeStep);
assert.throws(
	() => assertLinuxUnitFailureExcerpt(swappedNativeObservations),
	'success and failure-only native observations must keep their exact order'
);

const unitExcerptMutations = [
	[
		'name: Emit Configuration assertion from failed unit log',
		'name: Omitted Configuration assertion'
	],
	["failure() && !cancelled() && steps.linux_unit.outcome == 'failure'", 'success()'],
	["failure() && !cancelled() && steps.linux_unit.outcome == 'failure'", 'failure()'],
	['shell: bash', 'shell: sh'],
	['shell: bash', 'shell: bash\n        continue-on-error: true'],
	['shell: bash', 'shell: bash\n        working-directory: static/ergopti_plus/linux'],
	['"$RUNNER_TEMP/linux-unit.log"', '"$RUNNER_TEMP/another.log"'],
	['"$RUNNER_TEMP/linux-unit.log"', '"$RUNNER_TEMP/linux-unit.log" || true'],
	['node tools/test/linux-unit-failure-excerpt.cjs', 'node tools/test/report.cjs']
];
assert.strictEqual(
	unitExcerptMutations.length,
	9,
	'every independent excerpt wiring mutation is present'
);
for (const [from, to] of unitExcerptMutations) {
	const excerpt = pipeline.step(testLinux, 'Emit Configuration assertion from failed unit log');
	assert.strictEqual(excerpt.split(from).length - 1, 1, 'the excerpt mutation anchor is unique');
	assert.strictEqual(testLinux.split(excerpt).length - 1, 1, 'the actual excerpt step is unique');
	const changed = testLinux.replace(excerpt, () => excerpt.replace(from, () => to));
	assert.notStrictEqual(changed, testLinux);
	assert.throws(() => assertLinuxUnitFailureExcerpt(changed));
}
const actualExcerpt = pipeline.step(testLinux, 'Emit Configuration assertion from failed unit log');
assert.throws(
	() =>
		assertLinuxUnitFailureExcerpt(
			testLinux.replace(actualExcerpt, () => actualExcerpt + '\n\n' + actualExcerpt)
		),
	'a duplicate annotation must be rejected by the actual step loader'
);
const actualUpload = pipeline.step(testLinux, 'Upload failed unit log');
assert.strictEqual(testLinux.split(actualUpload).length - 1, 1);
assert.strictEqual(testLinux.split(actualExcerpt).length - 1, 1);
const swapMarker = '__ERGOPTI_CONFIGURATION_EXCERPT_SWAP__';
assert.ok(
	!testLinux.includes(swapMarker),
	'the temporary swap marker is absent from the actual job'
);
const reorderedExcerpt = testLinux
	.replace(actualUpload, () => swapMarker)
	.replace(actualExcerpt, () => actualUpload)
	.replace(swapMarker, () => actualExcerpt);
assert.notStrictEqual(reorderedExcerpt, testLinux);
assert.throws(
	() => assertLinuxUnitFailureExcerpt(reorderedExcerpt),
	'the annotation cannot interrupt original unit-to-uploader adjacency'
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
	'xkb_source_assertions=$(sed -n \'s/^=== \\([0-9][0-9]*\\) check(s), 0 failure(s) ===$/\\1/p\' "$RUNNER_TEMP/linux-xkb-source.log" | tail -1)',
	'window_switch_assertions=$(sed -n \'s/^Native window receipts: \\([0-9][0-9]*\\) passed, 0 failed, 0 skipped$/\\1/p\' "$RUNNER_TEMP/linux-window-switch.log" | tail -1)'
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
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['nix-installed-runtime'], 7);
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['retained-fd-sha256'], 12);
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['managed-http-output'], 18);
assert.strictEqual(MANIFEST.jobs['e2e-linux'].subjects['managed-http-public'], 30);
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
			'managed-network-runtime': '$network_runtime_assertions',
			'nix-installed-runtime': '$nix_runtime_assertions',
			'retained-fd-sha256': '$fd_sha256_assertions',
			'managed-http-output': '$managed_http_output_assertions',
			'managed-http-public': '$managed_http_public_assertions',
			'updater-native-namespace-cleanup': '$updater_native_namespace_assertions',
			'updater-temp-ownership': '$updater_temp_ownership_assertions',
			'updater-temp-allocation': '$updater_temp_allocation_assertions',
			'updater-archive-pipeline': '$updater_archive_assertions',
			'archive-source-crypto': '$archive_crypto_assertions',
			'archive-source-bin-parent': '$archive_bin_parent_assertions',
			'archive-private-snapshot': '$archive_snapshot_assertions',
			'connect-terminal-protocol-model': '$connect_protocol_assertions',
			'window-switch-receipts': '$window_switch_assertions',
			'native-fixture-family': '$native_family_assertions'
		}[subject] ?? '1';
	assert.strictEqual(
		value,
		expected,
		`the test-linux subject ${subject} must record ${expected}, got ${value}`
	);
}

process.stdout.write('PASS: Linux CI requires successful jobs and complete assertion evidence.\n');
