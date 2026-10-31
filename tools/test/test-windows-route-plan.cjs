// tools/test/test-windows-route-plan.cjs

/**
 * ==============================================================================
 * MODULE: Windows Route Plan Vector Replay
 * DESCRIPTION:
 * Replays _shared/tests/corpus/network/route_plan_vectors.json through the
 * Windows PowerShell twin (windows/vendor/ergopti_route_plan.ps1), which the
 * Lua, Go and shell twins already answer, then checks the owned Ollama
 * daemon's proxy environment over stub lookups and the relay tunnel probe
 * against a fake relay. PowerShell 7 runs it off Windows; the module keeps
 * Windows PowerShell 5.1 syntax, which the Windows CI lane runs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MODULE = path.join(ROOT, 'static/ergopti_plus/windows/vendor/ergopti_route_plan.ps1');
const VECTORS = path.join(
	ROOT,
	'static/ergopti_plus/_shared/tests/corpus/network/route_plan_vectors.json'
);
const ORIGINS = path.join(ROOT, 'static/ergopti_plus/_shared/modules/network/route_origins.json');

const runtime =
	process.platform === 'win32'
		? path.join(process.env.SystemRoot, 'System32/WindowsPowerShell/v1.0/powershell.exe')
		: 'pwsh';

// The replay runs in the module's own host and prints one JSON answer per
// vector; the assertions stay here so a silent host cannot pass them.
const REPLAY = `
$ErrorActionPreference = 'Stop'
. $env:ERGOPTI_ROUTE_PLAN_MODULE
$Corpus = Get-Content -LiteralPath $env:ERGOPTI_ROUTE_PLAN_VECTORS -Raw -Encoding UTF8 | ConvertFrom-Json
$Answers = New-Object System.Collections.ArrayList
foreach ($Case in $Corpus.plans) {
	$Plan = New-ErgoptiRoutePlan @($Case.entries)
	if ($Plan.Ok) { [void]$Answers.Add(@{ proxy = $Plan.Proxy; no_proxy = $Plan.NoProxy }) }
	else { [void]$Answers.Add(@{ reason = $Plan.Reason }) }
}
$Settled = New-ErgoptiRoutePlan @($Corpus.redirects.plan)
if (-not $Settled.Ok) { throw 'The redirect plan was refused.' }
$Redirects = New-Object System.Collections.ArrayList
foreach ($Target in $Corpus.redirects.targets) {
	$Answer = Resolve-ErgoptiRoutePlanRedirect $Settled $Target.url
	if ($Answer.Ok) { [void]$Redirects.Add(@{ route = $Answer.Route }) }
	else { [void]$Redirects.Add(@{ reason = $Answer.Reason }) }
}
$Reasons = @($script:ErgoptiRoutePlanEmpty, $script:ErgoptiRoutePlanInvalid,
	$script:ErgoptiRoutePlanConflict, $script:ErgoptiRoutePlanUnplannedHost)
@{ plans = @($Answers); redirects = @($Redirects); reasons = $Reasons } | ConvertTo-Json -Depth 4 -Compress
`;

// -EncodedCommand: a script on stdin makes the host echo terminal controls.
/**
 * Runs one PowerShell script with the module's paths in its environment.
 * @param {string} script The script.
 * @param {object} extra More environment variables.
 * @returns {object} The decoded JSON it printed.
 */
function runPowerShell(script, extra = {}) {
	const encoded = Buffer.from(script, 'utf16le').toString('base64');
	const child = spawnSync(runtime, ['-NoProfile', '-NonInteractive', '-EncodedCommand', encoded], {
		cwd: ROOT,
		env: {
			...process.env,
			ERGOPTI_ROUTE_PLAN_MODULE: MODULE,
			ERGOPTI_ROUTE_PLAN_VECTORS: VECTORS,
			...extra
		},
		encoding: 'utf8',
		windowsHide: true,
		timeout: 60000
	});
	assert.equal(child.error, undefined, `PowerShell must run: ${child.error?.message}`);
	assert.equal(child.status, 0, `the replay failed:\n${child.stdout}\n${child.stderr}`);
	return JSON.parse(child.stdout.trim());
}

const answers = runPowerShell(REPLAY);
const corpus = JSON.parse(fs.readFileSync(VECTORS, 'utf8'));

assert.ok(corpus.plans.length >= 20, 'the plan corpus shrank below its reviewed size');
assert.ok(
	corpus.redirects.targets.length >= 7,
	'the redirect corpus shrank below its reviewed size'
);
assert.equal(answers.plans.length, corpus.plans.length, 'every plan vector has an answer');
assert.equal(
	answers.redirects.length,
	corpus.redirects.targets.length,
	'every redirect vector has an answer'
);
// route_origins.json owns the closed refusal enum the twins answer with.
assert.deepEqual(
	[...answers.reasons].sort(),
	[...JSON.parse(fs.readFileSync(ORIGINS, 'utf8')).refusals].sort(),
	'the module refuses with exactly the reasons of route_origins.json'
);
corpus.plans.forEach((vector, index) => {
	assert.deepEqual(answers.plans[index], vector.expect, `plan: ${vector.name}`);
});
corpus.redirects.targets.forEach((vector, index) => {
	assert.deepEqual(answers.redirects[index], vector.expect, `redirect: ${vector.name}`);
});

// The owned daemon's environment over stub lookups: Lookups maps an origin to
// its first route ("direct", a relay URI, "env" for an exported relay, "fail").
const DAEMON = `
$ErrorActionPreference = 'Stop'
. $env:ERGOPTI_ROUTE_PLAN_MODULE
$Cases = $env:ERGOPTI_DAEMON_CASES | ConvertFrom-Json
$Answers = New-Object System.Collections.ArrayList
foreach ($Case in $Cases) {
	$Lookups = $Case.lookups
	$Bypass = $Case.no_proxy
	$Resolve = {
		param($Origin)
		$Route = $Lookups.$Origin
		if ($Route -ceq 'fail') { return @{ Ok = $false; Routes = @() } }
		if ($Route -ceq 'env') { return @{ Ok = $true; Routes = @(@{ Kind = 'proxy'; Endpoint = 'http://user.corp:8080/'; Source = 'environment' }) } }
		if ($Route -ceq 'direct') { return @{ Ok = $true; Routes = @(@{ Kind = 'direct'; Endpoint = ''; Source = 'pac' }) } }
		return @{ Ok = $true; Routes = @(@{ Kind = 'proxy'; Endpoint = $Route; Source = 'pac' }, @{ Kind = 'direct'; Endpoint = ''; Source = 'pac' }) }
	}.GetNewClosure()
	$Read = { param($Name) if ($Name -ceq 'NO_PROXY') { return $Bypass } return '' }.GetNewClosure()
	$Answer = Get-ErgoptiOwnedProxyEnvironment -Origins @($Case.origins) -Resolve $Resolve -ReadEnvironment $Read
	if ($Answer.Ok) { [void]$Answers.Add(@{ mode = $Answer.Mode; environment = $Answer.Environment }) }
	else { [void]$Answers.Add(@{ reason = $Answer.Reason }) }
}
ConvertTo-Json -InputObject @($Answers) -Depth 4 -Compress
`;
const REGISTRY = 'https://registry.example';
const BLOBS = 'https://blobs.example';
const DAEMON_CASES = [
	{
		name: 'every origin direct exports nothing',
		origins: [REGISTRY, BLOBS],
		lookups: { [REGISTRY]: 'direct', [BLOBS]: 'direct' },
		expect: { mode: 'direct', environment: {} }
	},
	{
		name: 'a PAC relay is exported, only its first selection',
		origins: [REGISTRY, BLOBS],
		lookups: { [REGISTRY]: 'http://relay.corp:3128/', [BLOBS]: 'http://relay.corp:3128/' },
		expect: { mode: 'relay', environment: { HTTPS_PROXY: 'http://relay.corp:3128' } }
	},
	{
		name: 'an origin sent direct joins the user bypass',
		origins: [REGISTRY, BLOBS],
		no_proxy: 'intranet.corp',
		lookups: { [REGISTRY]: 'http://relay.corp:3128/', [BLOBS]: 'direct' },
		expect: {
			mode: 'relay',
			environment: {
				HTTPS_PROXY: 'http://relay.corp:3128',
				NO_PROXY: 'intranet.corp,blobs.example'
			}
		}
	},
	{
		name: 'an exported relay is inherited, nothing overridden',
		origins: [REGISTRY, BLOBS],
		lookups: { [REGISTRY]: 'env', [BLOBS]: 'env' },
		expect: { mode: 'inherit', environment: {} }
	},
	{
		name: 'two relays are refused',
		origins: [REGISTRY, BLOBS],
		lookups: { [REGISTRY]: 'http://a.corp:3128/', [BLOBS]: 'http://b.corp:3128/' },
		expect: { reason: 'route-plan-conflict' }
	},
	{
		name: 'a refused lookup refuses the environment',
		origins: [REGISTRY, BLOBS],
		lookups: { [REGISTRY]: 'http://relay.corp:3128/', [BLOBS]: 'fail' },
		expect: { reason: 'route-lookup-refused' }
	}
];

// The relay probe against a fake relay in its own process: the probe blocks
// this one. Each tunnel target picks the answer.
const RELAY = `
const net = require('node:net');
const answers = {
	'open.example:443': 'HTTP/1.1 200 Connection established\\r\\n\\r\\n',
	'ntlm.example:443': 'HTTP/1.1 407 Proxy Authentication Required\\r\\nProxy-Authenticate: NTLM\\r\\nProxy-Authenticate: Negotiate\\r\\nContent-Length: 0\\r\\n\\r\\n',
	'kerberos.example:443': 'HTTP/1.1 407 Proxy Authentication Required\\r\\nproxy-authenticate: negotiate\\r\\n\\r\\n',
	'basic.example:443': 'HTTP/1.1 407 Proxy Authentication Required\\r\\nProxy-Authenticate: Basic realm=\\"corp\\"\\r\\n\\r\\n',
	'deny.example:443': 'HTTP/1.1 403 Forbidden\\r\\n\\r\\n'
};
const server = net.createServer((socket) => {
	let head = '';
	socket.on('data', (chunk) => {
		head += chunk;
		const match = /^CONNECT (\\S+) HTTP/.exec(head);
		if (match && head.includes('\\r\\n\\r\\n')) socket.end(answers[match[1]] || 'HTTP/1.1 502 Bad Gateway\\r\\n\\r\\n');
	});
	socket.on('error', () => {});
});
server.listen(0, '127.0.0.1', () => console.log(server.address().port));
`;
const PROBE = `
$ErrorActionPreference = 'Stop'
. $env:ERGOPTI_ROUTE_PLAN_MODULE
$Relay = 'http://127.0.0.1:' + $env:ERGOPTI_FAKE_RELAY_PORT
$Answers = [ordered]@{}
foreach ($Name in @('open', 'ntlm', 'kerberos', 'basic', 'deny')) {
	$Answers[$Name] = Test-ErgoptiRelayTunnel -Relay $Relay -Target ($Name + '.example:443') -TimeoutMs 5000
}
$Answers['unreachable'] = Test-ErgoptiRelayTunnel -Relay 'http://127.0.0.1:1' -Target 'open.example:443' -TimeoutMs 2000
$Answers | ConvertTo-Json -Compress
`;

// The relay's answers and command line, against the corpus the Go relay and the
// Lua policy answer.
const RELAY_CONTRACT = path.join(
	ROOT,
	'static/ergopti_plus/_shared/modules/network/proxy_auth_relay.json'
);
const RELAY_VECTORS = path.join(
	ROOT,
	'static/ergopti_plus/_shared/tests/corpus/network/proxy_auth_relay_probe_vectors.json'
);
const RELAY_POLICY = `
$ErrorActionPreference = 'Stop'
. $env:ERGOPTI_ROUTE_PLAN_MODULE
$Contract = Get-Content -LiteralPath $env:ERGOPTI_RELAY_CONTRACT -Raw -Encoding UTF8 | ConvertFrom-Json
$Corpus = Get-Content -LiteralPath $env:ERGOPTI_RELAY_VECTORS -Raw -Encoding UTF8 | ConvertFrom-Json
$Answers = New-Object System.Collections.ArrayList
foreach ($Case in $Corpus.vectors) {
	$Answer = Read-ErgoptiRelayProbe ([int]$Case.exit_code) ([string]$Case.stdout) $Contract
	[void]$Answers.Add(@{ id = $Case.id; status = $Answer['Status']; scheme = $Answer['Scheme']; reason = $Answer['Reason'] })
}
@{ answers = @($Answers);
	upstream = @((New-ErgoptiRelayUpstream 'http://Proxy.Corp:3128/'), (New-ErgoptiRelayUpstream 'http://user:pw@proxy:3128'),
		(New-ErgoptiRelayUpstream 'socks5://proxy:1080'), (New-ErgoptiRelayUpstream 'http://proxy:99999'));
	probe = (New-ErgoptiRelayProbeArguments -Upstream 'http://proxy.corp:3128' -Authority 'registry.ollama.ai:443' -DialMs 1 -HandshakeMs 2);
	run = (New-ErgoptiRelayRunPrefix -Upstream 'http://proxy.corp:3128' -Variable 'HTTPS_PROXY' -DialMs 1 -HandshakeMs 2 -IdleMs 3)
} | ConvertTo-Json -Depth 4 -Compress
`;

// The launcher hashes its proxy dependencies in the order it lists them, and
// the AHK bootstrap hashes the same names in its own list: a different order
// or name refuses every launch. The pull's login exit code is mirrored too.
const LLM_DIR = 'static/ergopti_plus/windows/modules/llm';
const launcher = fs.readFileSync(path.join(ROOT, LLM_DIR, 'ollama-runtime-launch.ps1'), 'utf8');
const pull = fs.readFileSync(path.join(ROOT, LLM_DIR, 'ollama-model-pull.ps1'), 'utf8');
const bootstrap = fs.readFileSync(path.join(ROOT, LLM_DIR, 'ollama_managed_bootstrap.ahk'), 'utf8');
const launcherNames = /function Get-OllamaRuntimeVendorNames \{\s*return @\(([^)]*)\)/.exec(
	launcher
);
const bootstrapNames = /global LLM_OLLAMA_RUNTIME_VENDOR_NAMES := \[([^\]]*)\]/.exec(bootstrap);
assert.ok(launcherNames && bootstrapNames, 'both vendor inventories are declared');
const names = (text) => [...text.matchAll(/['"]([a-z_]+\.ps1)['"]/g)].map((match) => match[1]);
assert.deepEqual(names(bootstrapNames[1]), names(launcherNames[1]), 'one vendor inventory order');
assert.ok(names(launcherNames[1]).includes('ergopti_route_plan.ps1'), 'the route plan is captured');
for (const name of names(launcherNames[1]))
	assert.ok(
		fs.existsSync(path.join(ROOT, 'static/ergopti_plus/windows/vendor', name)),
		`${name} ships`
	);
const pullCode = /function Get-OllamaPullProxyLoginExitCode \{ return (\d+) \}/.exec(pull);
const ahkCode = /global LLM_OLLAMA_PULL_PROXY_LOGIN_EXIT := (\d+)/.exec(bootstrap);
assert.ok(pullCode && ahkCode, 'both sides declare the login exit code');
assert.equal(ahkCode[1], pullCode[1], 'one login exit code');

// The AHK owner admits a readiness receipt only with exactly these fields: a
// field the launcher adds alone leaves the daemon never ready, with no error.
const receiptOwner = fs.readFileSync(path.join(ROOT, LLM_DIR, 'ollama_runtime_owner.ahk'), 'utf8');
const launcherReceipt = /\$receipt = \[ordered\]@\{([\s\S]*?)\}\r?\n/.exec(launcher);
const ownerReceipt = /global OLLAMA_RUNTIME_RECEIPT_FIELDS := \[([^\]]*)\]/.exec(receiptOwner);
assert.ok(launcherReceipt && ownerReceipt, 'both sides declare the receipt fields');
const launcherFields = [...launcherReceipt[1].matchAll(/(?:^|[;{\s])([a-z_]+) = /g)].map(
	(match) => match[1]
);
const ownerFields = [...ownerReceipt[1].matchAll(/"([a-z_]+)"/g)].map((match) => match[1]);
assert.ok(launcherFields.length > 0, 'the launcher receipt was read');
assert.deepEqual([...ownerFields].sort(), [...launcherFields].sort(), 'one receipt field list');

async function main() {
	const daemon = runPowerShell(DAEMON, {
		ERGOPTI_DAEMON_CASES: JSON.stringify(
			DAEMON_CASES.map(({ expect, ...input }) => ({ no_proxy: '', ...input }))
		)
	});
	assert.equal(daemon.length, DAEMON_CASES.length, 'every daemon case has an answer');
	DAEMON_CASES.forEach((vector, index) => {
		assert.deepEqual(daemon[index], vector.expect, `daemon: ${vector.name}`);
	});

	const relayPolicy = runPowerShell(RELAY_POLICY, {
		ERGOPTI_RELAY_CONTRACT: RELAY_CONTRACT,
		ERGOPTI_RELAY_VECTORS: RELAY_VECTORS
	});
	const relayVectors = JSON.parse(fs.readFileSync(RELAY_VECTORS, 'utf8')).vectors;
	assert.ok(relayVectors.length > 0, 'the relay corpus was read');
	assert.equal(relayPolicy.answers.length, relayVectors.length, 'every relay vector has an answer');
	relayVectors.forEach((vector, index) => {
		const answer = relayPolicy.answers[index];
		assert.equal(answer.id, vector.id);
		if (vector.reason) {
			assert.equal(answer.status, 'refused', vector.id);
			assert.equal(answer.reason, vector.reason, vector.id);
		} else {
			assert.equal(answer.status, vector.result.status, vector.id);
			assert.equal(answer.scheme ?? undefined, vector.result.scheme, vector.id);
		}
	});
	assert.deepEqual(
		relayPolicy.upstream,
		['http://proxy.corp:3128', '', '', ''],
		'only a plain http relay'
	);
	assert.equal(
		relayPolicy.probe,
		'probe --upstream http://proxy.corp:3128 --authority registry.ollama.ai:443 --dial-timeout-ms 1 --handshake-timeout-ms 2'
	);
	assert.equal(
		relayPolicy.run,
		'run --upstream http://proxy.corp:3128 --variable HTTPS_PROXY --dial-timeout-ms 1 --handshake-timeout-ms 2 --idle-timeout-ms 3 --'
	);

	const relay = spawn(process.execPath, ['-e', RELAY], { stdio: ['ignore', 'pipe', 'inherit'] });
	try {
		const port = await new Promise((resolve, reject) => {
			relay.stdout.once('data', (data) => resolve(String(data).trim()));
			relay.once('exit', (code) => reject(new Error(`the fake relay exited with ${code}`)));
		});
		assert.deepEqual(
			runPowerShell(PROBE, { ERGOPTI_FAKE_RELAY_PORT: port }),
			{
				open: 'open',
				ntlm: 'windows_login',
				kerberos: 'windows_login',
				basic: 'credentials',
				deny: 'refused',
				unreachable: 'unreachable'
			},
			'the probe classifies every relay answer'
		);
	} finally {
		relay.kill();
	}

	console.log(
		`[OK] Windows route plan: ${corpus.plans.length} plan and ${corpus.redirects.targets.length} redirect vectors replayed, ${DAEMON_CASES.length} daemon environments and 6 relay answers checked.`
	);
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
