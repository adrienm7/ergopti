// tools/test/lib/windows-owned-runtime.cjs

/**
 * ==============================================================================
 * MODULE: Windows Owned Runtime Test Profile
 * DESCRIPTION:
 * Builds a real managed Ollama profile for an end-to-end test and runs the real
 * launcher and pull worker in it: a stub daemon goes through the real archive
 * admission, stage preparation and publication of ollama_managed_files.ps1, then
 * ollama-runtime-launch.ps1 starts it under the shape ShellRunner gives it.
 *
 * FEATURES & RATIONALE:
 * 1. The managed root must be one folder inside a direct child of the user's
 *    LocalApplicationData (Open-OllamaManagedRoot refuses anything else), so
 *    the profile is a private ergopti-relay-e2e-<random> folder there, standing
 *    for the Ergopti root, with the managed root inside it, never the driver's
 *    own runtime folder.
 * 2. Exactly one production file differs: the WinINet reader in a private copy of
 *    the vendor folder answers the fake network's settings, because the real one
 *    reads the user's proxy settings. Everything after it (route lookup, PAC
 *    worker, route plan, tunnel probe, relay decision) is the shipped code.
 * 3. A proxy variable of the calling shell never reaches the launcher: it would
 *    take the "inherit" branch and could leave for a real proxy.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const AppDirs = require('./app-dirs.cjs');
const ROOT = path.resolve(__dirname, '..', '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const VENDOR = path.join(WINDOWS, 'vendor');
const LLM = path.join(WINDOWS, 'modules', 'llm');
const HOST_SCRIPT = path.join(__dirname, 'windows-job-host.ps1');
const POWERSHELL = path.join(
	process.env.SystemRoot || 'C:\\Windows',
	'System32',
	'WindowsPowerShell',
	'v1.0',
	'powershell.exe'
);
const RUNTIME_VENDOR_NAMES = [
	'ergopti_route_plan.ps1',
	'ergopti_network_routes.ps1',
	'ergopti_windows_proxy_config.ps1',
	'ergopti_native_proxy_ex.ps1',
	'ergopti_network_pac.ps1'
];
const PROXY_CONFIG_ANCHOR = 'public static Config Read(int maxBytes)\n    {';
const AMBIENT_PROXY_NAMES = /^(https?_proxy|all_proxy|no_proxy|ollama_host|ollama_models)$/i;
const POLL_MS = 50;

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');
const sha256File = (file) => sha256(fs.readFileSync(file));
const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Runs a Windows PowerShell file and returns its finished process. */
function runPowerShellFile(script, argumentsList, timeout = 60000) {
	return spawnSync(
		POWERSHELL,
		[
			'-NoLogo',
			'-NoProfile',
			'-NonInteractive',
			'-ExecutionPolicy',
			'Bypass',
			'-File',
			script,
			...argumentsList
		],
		{ encoding: 'utf8', windowsHide: true, timeout, env: scrubbedEnvironment() }
	);
}

/**
 * The calling environment without any proxy or Ollama variable. PSModulePath is
 * replaced too: a caller under PowerShell 7 exports its own module folders, and
 * Windows PowerShell then fails to load Microsoft.PowerShell.Security (Get-Acl)
 * from them.
 */
function scrubbedEnvironment(extra = {}) {
	const environment = {};
	for (const [name, value] of Object.entries(process.env))
		if (!AMBIENT_PROXY_NAMES.test(name) && !/^psmodulepath$/i.test(name)) environment[name] = value;
	const PSModulePath = path.join(path.dirname(POWERSHELL), 'Modules');
	return { ...environment, PSModulePath, ...extra };
}

/** The last JSON line a managed file action printed. */
function lastJsonLine(result, action) {
	const lines = String(result.stdout || '')
		.trim()
		.split(/\r?\n/);
	const answer = JSON.parse(lines[lines.length - 1] || 'null');
	if (result.status !== 0 || !answer || answer.ok !== true)
		throw new Error(`Managed ${action} refused: ${result.stdout}\n${result.stderr}`);
	return answer;
}

/** A zip of one directory through the Windows-supplied .NET writer. */
function zipDirectory(directory, archive) {
	const script = `Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory('${directory}', '${archive}')`;
	const done = spawnSync(
		POWERSHELL,
		['-NoLogo', '-NoProfile', '-NonInteractive', '-Command', script],
		{
			encoding: 'utf8',
			windowsHide: true
		}
	);
	if (done.status !== 0) throw new Error(`The stub archive failed: ${done.stderr}`);
}

/** The vendor copy whose only change is that the proxy settings come from the test. */
function prepareVendor(directory) {
	fs.mkdirSync(directory, { recursive: true });
	for (const name of [
		...RUNTIME_VENDOR_NAMES,
		'ergopti_network_pac.exe',
		'ergopti_network_pac.json'
	])
		fs.copyFileSync(path.join(VENDOR, name), path.join(directory, name));
	const reader = path.join(directory, 'ergopti_windows_proxy_config.ps1');
	const source = fs.readFileSync(reader, 'utf8').replace(/\r\n/g, '\n');
	if (source.split(PROXY_CONFIG_ANCHOR).length !== 2)
		throw new Error('The WinINet reader changed shape: update the test double.');
	const double = source.replace(
		PROXY_CONFIG_ANCHOR,
		`${PROXY_CONFIG_ANCHOR}
        Config forced=new Config(); forced.Ok=true;
        forced.Proxy=Environment.GetEnvironmentVariable("ERGOPTI_E2E_WININET_PROXY")??"";
        forced.PacUrl=Environment.GetEnvironmentVariable("ERGOPTI_E2E_WININET_PAC")??"";
        if(maxBytes>0) return forced;`
	);
	fs.writeFileSync(reader, double);
	let inventory = '';
	for (const name of RUNTIME_VENDOR_NAMES)
		inventory += `${name}\n${sha256File(path.join(directory, name))}\n`;
	return sha256(Buffer.from(inventory, 'utf8'));
}

/**
 * Creates the profile: root, published stub version and private vendor copy.
 * @param {object} options
 * @param {string} [options.stubExecutable] The built stub daemon.
 * @param {string} [options.releaseDirectory] A real release folder, published in its
 *     place through the same admission.
 * @returns {object} The profile, with launch(), pull() and dispose().
 */
function createProfile({ stubExecutable, releaseDirectory }) {
	const local = process.env.LOCALAPPDATA;
	const profileHome = path.join(
		local,
		`ergopti-relay-e2e-${crypto.randomBytes(16).toString('hex')}`
	);
	const managedRoot = path.join(
		profileHome,
		AppDirs.data.runtime.windows.managed_ollama_folder_name
	);
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-relay-e2e-'));
	const dispose = () => {
		fs.rmSync(profileHome, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
		fs.rmSync(work, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
	};
	try {
		const release = path.join(work, 'release');
		if (releaseDirectory) fs.cpSync(releaseDirectory, release, { recursive: true });
		else {
			fs.mkdirSync(release);
			fs.copyFileSync(stubExecutable, path.join(release, 'ollama.exe'));
		}
		const archive = path.join(work, 'ollama-windows-amd64.zip');
		zipDirectory(release, archive);
		const catalogue = path.join(work, 'catalogue.json');
		const bytes = fs.readFileSync(archive);
		fs.writeFileSync(
			catalogue,
			JSON.stringify({
				schema_version: 1,
				version: '0.0.0',
				assets: {
					'windows-amd64': {
						filename: 'ollama-windows-amd64.zip',
						sha256: sha256(bytes),
						bytes: bytes.length
					}
				}
			})
		);
		const helper = path.join(LLM, 'ollama_managed_files.ps1');
		const ticket = crypto.randomBytes(16).toString('hex');
		const prepared = lastJsonLine(
			runPowerShellFile(helper, [
				'-Action',
				'prepare',
				'-ManagedRoot',
				managedRoot,
				'-CataloguePath',
				catalogue,
				'-CatalogueSha256',
				sha256File(catalogue),
				'-AssetId',
				'windows-amd64',
				'-ArchivePath',
				archive,
				'-TicketId',
				ticket
			]),
			'prepare'
		);
		const published = lastJsonLine(
			runPowerShellFile(helper, [
				'-Action',
				'publish',
				'-ManagedRoot',
				managedRoot,
				'-TicketId',
				ticket,
				'-StageIdentity',
				prepared.stage_identity,
				'-ManifestSha256',
				prepared.manifest_sha256
			]),
			'publish'
		);
		const vendorDirectory = path.join(work, 'vendor');
		const vendorSha256 = prepareVendor(vendorDirectory);
		return {
			managedRoot,
			work,
			ticket,
			rootIdentity: prepared.root_identity,
			stageIdentity: published.version_identity,
			manifestSha256: prepared.manifest_sha256,
			versionPath: published.version_path,
			vendorDirectory,
			vendorSha256,
			dispose
		};
	} catch (error) {
		dispose();
		throw error;
	}
}

/** Starts one command line under the job host; `netOnly` selects its sign-in identity. */
function startHosted(profile, commandLine, { netOnly = null, environment = {} } = {}) {
	const directory = fs.mkdtempSync(path.join(profile.work, 'host-'));
	const paths = {
		stdout: path.join(directory, 'stdout'),
		stderr: path.join(directory, 'stderr'),
		exit: path.join(directory, 'exit'),
		stop: path.join(directory, 'stop'),
		command: path.join(directory, 'command')
	};
	fs.writeFileSync(paths.command, commandLine);
	const argumentsList = [
		'-NoLogo',
		'-NoProfile',
		'-NonInteractive',
		'-ExecutionPolicy',
		'Bypass',
		'-File',
		HOST_SCRIPT,
		'-CommandFile',
		paths.command,
		'-StdoutPath',
		paths.stdout,
		'-StderrPath',
		paths.stderr,
		'-ExitPath',
		paths.exit,
		'-StopPath',
		paths.stop,
		'-ParentPid',
		String(process.pid)
	];
	const extra = { ...environment };
	if (netOnly) {
		argumentsList.push('-NetOnlyUser', netOnly.user, '-NetOnlyDomain', netOnly.domain);
		extra.ERGOPTI_E2E_NETONLY_PASSWORD = netOnly.password;
	}
	const host = spawn(POWERSHELL, argumentsList, {
		env: scrubbedEnvironment(extra),
		windowsHide: true,
		stdio: 'ignore'
	});
	const finished = new Promise((resolve) => host.on('exit', resolve));
	const read = (file) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '');
	return {
		finished,
		stderr: () => read(paths.stderr),
		stdout: () => read(paths.stdout),
		hostError: () => read(`${paths.exit}.error`),
		exitCode: () => (fs.existsSync(paths.exit) ? Number(read(paths.exit)) : null),
		async stop() {
			fs.writeFileSync(paths.stop, '');
			await finished;
		}
	};
}

/** Picks a free ephemeral loopback port. */
function freePort() {
	return new Promise((resolve, reject) => {
		const server = require('node:net').createServer();
		server.once('error', reject);
		server.listen(0, '127.0.0.1', () => {
			const { port } = server.address();
			server.close(() => resolve(port));
		});
	});
}

/** Quotes one -File argument: the launcher's values never hold a double quote. */
const quote = (value) => `"${value}"`;

/** The arguments ollama_runtime_owner.ahk passes the launcher. */
function launcherArguments(profile, { port, runtimeTicket, relayPath, relaySha256, timings }) {
	const shared = path.join(SHARED, '.');
	const pinned = (name, file) => [`-${name}Path`, file, `-${name}Sha256`, sha256File(file)];
	const row = [
		...pinned('ManagedHelper', path.join(LLM, 'ollama_managed_files.ps1')),
		'-ManagedRoot',
		profile.managedRoot,
		'-RootIdentity',
		profile.rootIdentity,
		'-PublishedPath',
		profile.versionPath,
		'-StageIdentity',
		profile.stageIdentity,
		'-TicketId',
		profile.ticket,
		'-ManifestSha256',
		profile.manifestSha256,
		'-RuntimeTicket',
		runtimeTicket,
		'-Port',
		String(port),
		// A tick safely in the past: the deadline counts from it on this machine's clock.
		'-StartedTick',
		String(Math.floor(os.uptime() * 1000) - 2000),
		'-DeadlineMs',
		String(timings.deadlineMs),
		...pinned(
			'ServeEnvironment',
			path.join(shared, 'ai', 'data', 'managed_ollama_environment.json')
		),
		'-VendorDirectory',
		profile.vendorDirectory,
		'-VendorSha256',
		profile.vendorSha256,
		...pinned('ProxyPolicy', path.join(shared, 'core', 'network', 'data', 'proxy_policy.json')),
		...pinned('UpdaterDefaults', path.join(shared, 'updater', 'data', 'defaults.json')),
		...pinned('RouteOrigins', path.join(shared, 'core', 'network', 'data', 'route_origins.json')),
		...pinned(
			'ProxyRelayContract',
			path.join(shared, 'core', 'network', 'data', 'proxy_auth_relay.json')
		),
		'-ProxyRelayDialMs',
		String(timings.dialMs),
		'-ProxyRelayHandshakeMs',
		String(timings.handshakeMs),
		'-ProxyRelayIdleMs',
		String(timings.idleMs),
		'-ProxyRelayProbeMs',
		String(timings.probeMs),
		'-ProxyListProbeMs',
		String(timings.listProbeMs)
	];
	if (relayPath) row.push('-ProxyRelayPath', relayPath, '-ProxyRelaySha256', relaySha256);
	return row;
}

/** The whole command line of one Windows PowerShell -File run. */
function powerShellCommandLine(script, argumentsList) {
	const values = argumentsList.map((value) => (value.startsWith('-') ? value : quote(value)));
	return `${quote(POWERSHELL)} -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File ${quote(script)} ${values.join(' ')}`;
}

/**
 * Starts the real launcher.
 * @returns {object} The hosted run, plus its port, ticket and receipt path.
 */
async function launch(profile, options) {
	const port = options.port ?? (await freePort());
	const runtimeTicket = crypto.randomBytes(16).toString('hex');
	const script = options.launcher ?? path.join(LLM, 'ollama-runtime-launch.ps1');
	const hosted = startHosted(
		profile,
		powerShellCommandLine(script, launcherArguments(profile, { ...options, port, runtimeTicket })),
		{ netOnly: options.netOnly, environment: options.environment }
	);
	return {
		...hosted,
		port,
		runtimeTicket,
		receiptPath: path.join(profile.managedRoot, `.runtime-${runtimeTicket}.json`)
	};
}

/**
 * Waits for the launcher's receipt, or for the launcher to end without one.
 * @returns {Promise<object|null>} The decoded receipt and its image, null when none came.
 */
async function waitForReceipt(run, timeoutMs) {
	const deadline = Date.now() + timeoutMs;
	let ended = false;
	run.finished.then(() => {
		ended = true;
	});
	while (Date.now() < deadline) {
		if (fs.existsSync(run.receiptPath)) {
			try {
				const image = fs.readFileSync(run.receiptPath);
				const text = image.toString('utf8');
				if (text.endsWith('\n')) return { receipt: JSON.parse(text), image };
			} catch (error) {
				// The launcher readmits its image exclusively for an instant before exposing it.
				if (!['EBUSY', 'EPERM'].includes(error.code) && !(error instanceof SyntaxError))
					throw error;
			}
		}
		if (ended) return null;
		await delay(POLL_MS);
	}
	return null;
}

/** Runs the real pull worker to its end against a ready launcher. */
async function pull(profile, run, ready, model, { netOnly = null, environment = {} } = {}) {
	const shared = path.join(SHARED, '.');
	const pinned = (name, file) => [`-${name}Path`, file, `-${name}Sha256`, sha256File(file)];
	const hosted = startHosted(
		profile,
		powerShellCommandLine(path.join(LLM, 'ollama-model-pull.ps1'), [
			...pinned('ManagedHelper', path.join(LLM, 'ollama_managed_files.ps1')),
			...pinned('RuntimeLauncher', path.join(LLM, 'ollama-runtime-launch.ps1')),
			...pinned(
				'ServeEnvironment',
				path.join(shared, 'ai', 'data', 'managed_ollama_environment.json')
			),
			'-ManagedRoot',
			profile.managedRoot,
			'-RootIdentity',
			profile.rootIdentity,
			'-PublishedPath',
			profile.versionPath,
			'-StageIdentity',
			profile.stageIdentity,
			'-TicketId',
			profile.ticket,
			'-ManifestSha256',
			profile.manifestSha256,
			'-RuntimeTicket',
			run.runtimeTicket,
			'-ReadyFileIdentity',
			ready.receipt.ready_file_identity,
			'-ReadyImageSha256',
			sha256(ready.image),
			'-Port',
			String(run.port),
			'-Model',
			model
		]),
		{ netOnly, environment }
	);
	await hosted.finished;
	return {
		code: hosted.exitCode(),
		stdout: hosted.stdout(),
		stderr: hosted.stderr(),
		hostError: hosted.hostError()
	};
}

module.exports = {
	LLM,
	POWERSHELL,
	ROOT,
	SHARED,
	VENDOR,
	WINDOWS,
	createProfile,
	delay,
	freePort,
	launch,
	launcherArguments,
	pull,
	scrubbedEnvironment,
	sha256,
	sha256File,
	startHosted,
	waitForReceipt
};
