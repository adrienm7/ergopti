// Versions managed-network reports remain safe and bind actions to native epochs.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { runPage } = require('./support/changelog-page-dom.cjs');
const strings = JSON.parse(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/data/locales/en.json'),
		'utf8'
	)
);
let controls = 0;
function test(name, body) {
	body();
	controls += 1;
	process.stdout.write(`PASS ${name}\n`);
}
function fixture() {
	const page = runPage({
		_i18n_strings: strings,
		__ergopti_host: 'linux',
		__installed_version: '1.0.0',
		__subscribed_channel: 'dev'
	});
	page.sandbox.injectReleases(
		[
			{
				tag_name: 'v1.2.3',
				body: 'Notes',
				published_at: '2026-10-04T00:00:00Z',
				html_url: 'https://github.com/adrienm7/ergopti/releases/tag/v1.2.3'
			}
		],
		'dev'
	);
	page.el = (id) => page.document.getElementById(id);
	page.actions = () =>
		page.posted
			.map((message) => message.payload)
			.filter((message) => message && message.action === 'install_failure_action');
	return page;
}
function message(
	operation = 31,
	epoch = 44,
	actions = [{ id: 'retry', label_key: 'network.action.retry' }]
) {
	return {
		tag: 'v1.2.3',
		phase: 'failed',
		reason_key: 'changelog_window.install_error_download',
		backup_path: '/cfg/backup',
		operation,
		failure_epoch: epoch,
		failure_report: {
			cause: 'proxy',
			message_key: 'network.failure.proxy',
			actions,
			receipt: { url: 'https://secret@host', stderr: 'credential', path: '/secret' }
		}
	};
}
test('translated managed failure preserves backup text and omits generic retry', () => {
	const page = fixture();
	page.sandbox.setInstallProgress(message());
	assert.ok(page.el('install-text').textContent.includes(strings['network.failure.proxy']));
	assert.ok(page.el('install-text').textContent.includes('/cfg/backup'));
	assert.equal(page.el('btn-install-retry').style.display, 'none');
	assert.equal(page.el('install-failure-actions').children.length, 1);
	assert.equal(
		page.el('install-failure-actions').children[0].textContent,
		strings['network.action.retry']
	);
	assert.equal(JSON.stringify(page.sandbox._install).includes('credential'), false);
	assert.equal(JSON.stringify(page.sandbox._install).includes('https://secret'), false);
});
test('action posts only exact native operation and failure epoch', () => {
	const page = fixture();
	page.sandbox.setInstallProgress(message());
	page.el('install-failure-actions').children[0].dispatch('click');
	assert.deepEqual(JSON.parse(JSON.stringify(page.actions())), [
		{ action: 'install_failure_action', id: 'retry', operation: 31, epoch: 44 }
	]);
	page.sandbox.retryInstall();
	assert.equal(page.actions().length, 1);
});
test('retained button cannot borrow a new same-tag failure', () => {
	const page = fixture();
	page.sandbox.setInstallProgress(message());
	const old = page.el('install-failure-actions').children[0];
	page.sandbox.setInstallProgress(message(32, 45));
	old.dispatch('click');
	assert.equal(page.actions().length, 0);
	page.el('install-failure-actions').children[0].dispatch('click');
	assert.equal(page.actions()[0].operation, 32);
	assert.equal(page.actions()[0].epoch, 45);
});
test('successful phase retires managed actions and old retained callbacks', () => {
	const page = fixture();
	page.sandbox.setInstallProgress(message());
	const old = page.el('install-failure-actions').children[0];
	page.sandbox.setInstallProgress({ tag: 'v1.2.3', phase: 'installing' });
	assert.equal(page.el('install-failure-actions').children.length, 0);
	old.dispatch('click');
	assert.equal(page.actions().length, 0);
});
test('unavailable actions are absent and unsafe action labels cannot render', () => {
	const page = fixture();
	page.sandbox.setInstallProgress(message(31, 44, []));
	assert.equal(page.el('install-failure-actions').children.length, 0);
	page.sandbox.setInstallProgress(
		message(31, 44, [{ id: 'diagnostics', label_key: 'https://secret' }])
	);
	assert.equal(page.el('install-failure-actions').children.length, 0);
});
test('unavailable or malformed managed report never revives an unbound generic retry', () => {
	const page = fixture();
	page.sandbox.setInstallProgress({
		tag: 'v1.2.3',
		phase: 'failed',
		reason_key: 'changelog_window.install_error_download',
		managed_failure: true
	});
	assert.equal(page.el('btn-install-retry').style.display, 'none');
	assert.equal(page.el('install-failure-actions').children.length, 0);
	page.sandbox.setInstallProgress({ ...message(), operation: 'untrusted' });
	assert.equal(page.el('btn-install-retry').style.display, 'none');
	assert.equal(page.el('install-failure-actions').children.length, 0);
});
test('generic integrity failure retains original translated reason and retry', () => {
	const page = fixture();
	page.sandbox.setInstallProgress({
		tag: 'v1.2.3',
		phase: 'failed',
		reason_key: 'changelog_window.install_error_verify',
		backup_path: '/cfg/backup'
	});
	assert.ok(
		page
			.el('install-text')
			.textContent.includes(
				strings['changelog_window.install_error_verify']
					.split('{tag}')
					.join('v1.2.3')
					.split('{path}')
					.join('/cfg/backup')
			)
	);
	assert.notEqual(page.el('btn-install-retry').style.display, 'none');
	assert.equal(page.el('install-failure-actions').children.length, 0);
});
process.stdout.write(`${controls} managed Versions page controls passed\n`);
