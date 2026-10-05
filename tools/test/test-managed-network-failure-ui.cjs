// tools/test/test-managed-network-failure-ui.cjs

/**
 * ==============================================================================
 * MODULE: Managed Download Failure Renderer Regression
 * DESCRIPTION:
 * Executes the real renderer with independently authored action receipts and
 * verifies safe text, captured owner epochs, refusals and locale refresh.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const pageRoot = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const source = fs.readFileSync(path.join(pageRoot, 'download_window/network_failure.js'), 'utf8');
const pageScript = fs.readFileSync(path.join(pageRoot, 'download_window/script.js'), 'utf8');
const hostBridge = fs.readFileSync(path.join(pageRoot, 'host_bridge.js'), 'utf8');
const pageHtml = fs.readFileSync(path.join(pageRoot, 'download_window/index.html'), 'utf8');

function fixture(fullPage = false) {
	const elements = new Map();
	const events = new Map();
	const messages = [];
	function element() {
		const handlers = new Map();
		return {
			style: {},
			children: [],
			textContent: '',
			classList: { add() {}, remove() {} },
			appendChild(child) {
				this.children.push(child);
				if (child.id) elements.set(child.id, child);
			},
			replaceChildren(...children) {
				this.children = children;
			},
			addEventListener(event, fn) {
				handlers.set(event, fn);
			},
			click() {
				handlers.get('click')();
			}
		};
	}
	for (const id of [
		'done-msg',
		'ui-controls',
		'btn-retry',
		'title',
		'subtitle',
		'bar-fill',
		'pct',
		'file-count',
		'stats-details',
		'eta-container',
		'stats-fallback',
		'log-area',
		'btn-cancel'
	])
		elements.set(id, element());
	const window = {
		_i18n_strings: {
			'network.failure.unknown': 'The download failed. The cause could not be verified.',
			'network.action.retry': 'Retry',
			'error_dialog.open_log': 'Open diagnostics',
			'download_window.btn_cancel': 'Cancel'
		}
	};
	if (fullPage)
		window.chrome = {
			webview: {
				postMessage(message) {
					messages.push(message === 'ready' ? message : JSON.parse(message));
				}
			}
		};
	const context = vm.createContext({
		console,
		window,
		document: {
			readyState: 'complete',
			body: { classList: { add() {}, remove() {} } },
			getElementById: (id) => elements.get(id),
			createElement: element,
			addEventListener: (event, fn) => events.set(event, fn)
		},
		makeHostBridge: (name) => {
			assert.equal(name, 'dl_bridge');
			return (message) => messages.push(JSON.parse(JSON.stringify(message)));
		}
	});
	if (fullPage) {
		vm.runInContext(hostBridge, context);
		vm.runInContext(pageScript, context);
	}
	vm.runInContext(source, context);
	return { window, elements, events, messages, context };
}

const report = {
	message_key: 'network.failure.unknown',
	actions: [
		{ id: 'retry', label_key: 'network.action.retry' },
		{ id: 'diagnostics', label_key: 'error_dialog.open_log' }
	],
	url: 'https://user:password@example.test/private?token=secret',
	stderr: '<script>secret</script>',
	path: '/private/foreign'
};

{
	const world = fixture();
	assert.equal(world.window.showNetworkFailure(report, 12, 1), true);
	const panel = world.elements.get('managed-network-actions');
	assert.deepEqual(
		panel.children.map((button) => button.textContent),
		['Retry', 'Open diagnostics']
	);
	assert.equal(
		world.elements.get('done-msg').textContent,
		'The download failed. The cause could not be verified.'
	);
	assert.equal(world.elements.get('btn-retry').style.display, 'none');
	panel.children[0].click();
	assert.deepEqual(world.messages, [
		{ action: 'failure_action', id: 'retry', session: 12, epoch: 1 }
	]);
	assert.equal(JSON.stringify(world.messages).includes('secret'), false);
	assert.equal(JSON.stringify(panel.children).includes('/private/foreign'), false);

	const retained = panel.children[1];
	assert.equal(world.window.showNetworkFailure(report, 12, 2), true);
	retained.click();
	assert.deepEqual(
		world.messages[1],
		{ action: 'failure_action', id: 'diagnostics', session: 12, epoch: 1 },
		'A retained button cannot borrow a later failure epoch; native host must reject this stale message.'
	);
	panel.children[1].click();
	assert.deepEqual(world.messages[2], {
		action: 'failure_action',
		id: 'diagnostics',
		session: 12,
		epoch: 2
	});
	world.window.clearNetworkFailure();
	assert.equal(panel.children.length, 0);
}

{
	const world = fixture();
	assert.equal(world.window.showNetworkFailure(report, 4, 3), true);
	world.window._i18n_strings['network.action.retry'] = 'Réessayer';
	world.events.get('i18n:applied')();
	assert.equal(world.elements.get('managed-network-actions').children[0].textContent, 'Réessayer');
}

{
	const world = fixture();
	for (const [session, epoch] of [
		[0, 1],
		[1, 0],
		['1', 1],
		[1, '1'],
		[NaN, 1]
	])
		assert.equal(world.window.showNetworkFailure(report, session, epoch), false);
	assert.equal(
		world.window.showNetworkFailure({ message_key: 'unknown.locale', actions: [] }, 1, 1),
		false
	);
	assert.equal(
		world.window.showNetworkFailure(
			{
				message_key: report.message_key,
				actions: [{ id: '../open', label_key: 'network.action.retry' }]
			},
			1,
			1
		),
		false
	);
	assert.equal(
		world.window.showNetworkFailure(
			{ message_key: report.message_key, actions: [report.actions[0], report.actions[0]] },
			1,
			1
		),
		false
	);
	assert.equal(
		world.elements.has('managed-network-actions'),
		false,
		'Rejected input cannot partially mutate the UI.'
	);
	assert.equal(world.messages.length, 0);
}

{
	assert.ok(
		pageHtml.includes('<script src="network_failure.js"></script>'),
		'The actual page must load the renderer, rather than passing an isolated module test.'
	);
	const world = fixture(true);
	assert.deepEqual(world.messages.splice(0), ['ready']);
	vm.runInContext(
		"setKind('app_update', 'First', '', 11); done(false, 'Original error')",
		world.context
	);
	assert.equal(world.window.showNetworkFailure(report, 11, 3), true);
	const panel = world.elements.get('managed-network-actions');
	panel.children[0].click();
	assert.deepEqual(world.messages.splice(0), [
		{ action: 'failure_action', id: 'retry', session: 11, epoch: 3 }
	]);
	assert.throws(
		() => vm.runInContext("setKind('app_update', 'Invalid', '', 0)", world.context),
		/session/
	);
	assert.equal(
		panel.children.length,
		2,
		'Rejected initialization must preserve the current failure.'
	);
	vm.runInContext("setKind('app_update', 'Second', '', 12)", world.context);
	assert.equal(panel.children.length, 0, 'A successor operation must retire the previous actions.');
	assert.equal(
		world.window.showNetworkFailure(report, 11, 4),
		false,
		'A queued report from the predecessor cannot render over the successor page.'
	);
	vm.runInContext("done(false, 'Second failed')", world.context);
	assert.equal(world.window.showNetworkFailure(report, 12, 5), true);
	vm.runInContext('resetUI()', world.context);
	world.events.get('i18n:applied')();
	assert.equal(
		panel.children.length,
		0,
		'Locale refresh cannot resurrect actions after retry reset.'
	);
	assert.equal(
		world.window.showNetworkFailure(report, 12, 5),
		false,
		'A delayed failure publication cannot resurrect actions during the next attempt.'
	);
	vm.runInContext("done(false, 'Third failed')", world.context);
	assert.equal(
		world.window.showNetworkFailure(report, 12, 5),
		false,
		'The retired failure epoch stays rejected after a later terminal in the same session.'
	);
	assert.equal(world.window.showNetworkFailure(report, 12, 6), true);
	assert.equal(
		world.window.showNetworkFailure(report, 12, 5),
		false,
		'A newer failure must not be replaced by an older publication.'
	);
	vm.runInContext("done(true, 'Installed')", world.context);
	assert.equal(
		world.window.showNetworkFailure(report, 12, 7),
		false,
		'Success must reject delayed failure publication even when its epoch is newer.'
	);
	world.events.get('i18n:applied')();
	assert.equal(panel.children.length, 0, 'Success must retire prior failure actions.');
	assert.equal(world.elements.get('done-msg').textContent, 'Installed');
}

console.log(
	'PASS: managed failure renderer preserves safe text, current sessions and lifecycle retirement.'
);
