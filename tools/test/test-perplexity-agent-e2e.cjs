// tools/test/test-perplexity-agent-e2e.cjs

/**
 * ==============================================================================
 * MODULE: Perplexity Agent API End-To-End
 * DESCRIPTION:
 * Runs the drivers' Agent API code against the local fake of fake-network.cjs,
 * which refuses what the documented API refuses: a chat-completions body, a body
 * without max_output_tokens, a wrong key. No real provider is called: no key
 * exists for one, so the shapes are only as true as the documentation of
 * 2026-11-01 that the fake restates.
 *
 * FEATURES & RATIONALE:
 * 1. Windows: the real http_client and managed worker under AutoHotkey
 *    (tests/live/perplexity_agent_owner.ahk), with the body and the reading of
 *    remote_formats.ahk.
 * 2. macOS and Linux: the shared Lua body and classifier, through a Lua
 *    interpreter when one is on PATH; this test owns their HTTP exchange.
 * 3. It cannot silently skip: a missing interpreter prints a "NOT EXECUTED" row,
 *    and --required, which the Windows CI step passes, fails on AutoHotkey's.
 *
 * USAGE:
 *   node tools/test/test-perplexity-agent-e2e.cjs [--required]
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');
const { startFakeAgentApi } = require('./lib/fake-network.cjs');
const { NOT_EXECUTED_MARKER } = require('./validate-ahk-suite-manifest.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static/ergopti_plus');
const OWNER = path.join(DRIVERS, 'windows/tests/live/perplexity_agent_owner.ahk');
const LUA_CLIENT = path.join(__dirname, 'fixtures/perplexity-agent-client.lua');
const AUTOHOTKEY = process.env.ERGOPTI_AHK_EXE || 'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe';
const LUA_NAMES = ['lua', 'lua5.4', 'luajit'];
const REQUIRED = process.argv.includes('--required');
const OWNER_TIMEOUT_MS = 90000;
const TOKEN = 'fake-agent-key';

let total = 0;
let failed = 0;
let notExecuted = 0;

function report(name, state, detail = '') {
	total++;
	if (state === 'ok') console.log(`ok ${total} - ${name}`);
	else if (state === 'skip') {
		notExecuted++;
		console.log(`ok ${total} - ${name}${NOT_EXECUTED_MARKER}${detail}`);
	} else {
		failed++;
		console.log(`not ok ${total} - ${name} - ${String(detail).split(/\r?\n/).join(' | ')}`);
	}
}

async function check(name, body) {
	try {
		await body();
		report(name, 'ok');
	} catch (error) {
		report(name, 'fail', error.stack || error.message);
	}
}

/** Runs the AutoHotkey owner without blocking the fake's event loop. */
function runOwner(planPath) {
	return new Promise((resolve, reject) => {
		const child = spawn(AUTOHOTKEY, ['/force', '/ErrorStdOut', OWNER, planPath], {
			windowsHide: true
		});
		let output = '';
		child.stdout.on('data', (chunk) => (output += chunk));
		child.stderr.on('data', (chunk) => (output += chunk));
		const timer = setTimeout(() => {
			child.kill();
			reject(new Error(`the owner ran out of time: ${output}`));
		}, OWNER_TIMEOUT_MS);
		child.on('error', reject);
		child.on('close', (code) => {
			clearTimeout(timer);
			resolve({ code, output });
		});
	});
}

/** The first Lua interpreter on PATH, null without one. */
function findLua() {
	for (const name of LUA_NAMES) {
		if (spawnSync(name, ['-v'], { windowsHide: true }).status === 0) return name;
	}
	return null;
}

async function main() {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-perplexity-agent-'));
	const fake = await startFakeAgentApi({ key: TOKEN });
	const lua = findLua();
	try {
		if (!fs.existsSync(AUTOHOTKEY)) {
			report(
				'windows: the real transport carries a prediction and a listing',
				REQUIRED ? 'fail' : 'skip',
				`AutoHotkey is not at ${AUTOHOTKEY}`
			);
		} else {
			await check('windows: the real transport carries a prediction and a listing', async () => {
				const planPath = path.join(work, 'plan.json');
				const resultPath = `${planPath}.result`;
				fs.writeFileSync(
					planPath,
					JSON.stringify({
						shared: path.join(DRIVERS, '_shared'),
						vendor: path.join(DRIVERS, 'windows/vendor'),
						base: fake.baseUrl,
						token: TOKEN,
						text: 'ping "quoted"',
						result: resultPath
					})
				);
				const done = await runOwner(planPath);
				assert.equal(done.code, 0, done.output);
				const result = JSON.parse(fs.readFileSync(resultPath, 'utf8'));
				assert.equal(result.status, 200, JSON.stringify(fake.events));
				assert.equal(result.failed, false);
				assert.equal(result.text, 'OK');
				assert.equal(result.listing_status, 200);
				assert.ok(JSON.parse(result.listing).data.some((row) => row.id === 'perplexity/sonar'));
				const request = fake.events.find((event) => event.type === 'agent');
				assert.equal(request.body.input, 'ping "quoted"');
				assert.equal(request.body.instructions, 'Reply with OK.');
				assert.equal(request.body.max_output_tokens, 16);
				assert.equal(request.body.stream, false);
			});
		}

		if (!lua) {
			report('lua: the shared body and classifier', 'skip', 'no Lua interpreter on PATH');
		} else {
			await check('lua: the shared body and classifier', async () => {
				const run = (...args) => {
					const done = spawnSync(lua, [LUA_CLIENT, DRIVERS, ...args], {
						encoding: 'utf8',
						windowsHide: true
					});
					assert.equal(done.status, 0, done.stderr);
					return done.stdout;
				};
				const response = await fetch(`${fake.baseUrl}/agent`, {
					method: 'POST',
					headers: { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' },
					body: run('body', 'ping')
				});
				const raw = await response.text();
				assert.equal(response.status, 200, raw);
				const answerPath = path.join(work, 'answer.json');
				fs.writeFileSync(answerPath, raw);
				assert.deepEqual(JSON.parse(run('answer', answerPath)), { text: 'OK', total_tokens: 12 });
			});
		}

		await check('the fake refuses what the documented API refuses', async () => {
			const post = (body, token = TOKEN) =>
				fetch(`${fake.baseUrl}/agent`, {
					method: 'POST',
					headers: { Authorization: `Bearer ${token}` },
					body: JSON.stringify(body)
				}).then((response) => response.status);
			assert.equal(
				await post({ model: 'perplexity/sonar', messages: [{ role: 'user', content: 'x' }] }),
				400
			);
			assert.equal(await post({ model: 'perplexity/sonar', input: 'x' }), 400);
			assert.equal(
				await post({ model: 'perplexity/sonar', input: 'x', max_output_tokens: 8 }, 'bad'),
				401
			);
		});
	} finally {
		await fake.close();
		fs.rmSync(work, { recursive: true, force: true });
	}
	console.log(`1..${total}`);
	console.log(
		`# ${total - failed - notExecuted} passed, ${failed} failed, ${notExecuted} not executed`
	);
	process.exitCode = failed ? 1 : 0;
}

main().catch((error) => {
	console.error(error);
	process.exit(1);
});
