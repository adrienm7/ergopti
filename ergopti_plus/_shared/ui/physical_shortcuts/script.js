// _shared/ui/physical_shortcuts/script.js

/**
 * The native session retains source ownership and action parameters. This page
 * selects registry positions manually; browser key events are never capture proof.
 */
const post = makeHostBridge('physical_shortcuts_bridge');
let strings = {};
let entries = [];
let previous = null;
let token = null;
let selection = 0;
let pending = false;
let writable = true;
let captureAvailable = false;
const modifierNames = ['ctrl', 'alt', 'shift', 'super'];
const node = (id) => document.getElementById(id);

function status(key) {
	node('status').textContent = strings[key] || '';
}

function busy(value) {
	pending = value;
	node('capture').disabled = value || !writable || !captureAvailable;
	for (const id of ['add', 'choose', 'cancel', 'position']) node(id).disabled = value || !writable;
	for (const input of node('modifiers').querySelectorAll('input'))
		input.disabled = value || !writable;
	node('save').disabled = value || !writable || token === null;
	for (const button of node('entries').querySelectorAll('button'))
		button.disabled = value || !writable;
}

function changed() {
	post({ action: 'cancel_position' });
	selection += 1;
	token = null;
	node('selected-action').textContent = '';
	node('save').disabled = true;
}

function edit(record) {
	if (pending || !writable) return;
	previous = record ? record.slot : null;
	changed();
	node('editor').hidden = false;
	node('position').value = record
		? record.code
		: Array.from(node('position').options).find((option) => !option.disabled)?.value || '';
	for (const name of modifierNames) node('mod-' + name).checked = record?.mods[name] === true;
	status('');
	node('position').focus();
}

function render() {
	node('entries').replaceChildren();
	node('empty').hidden = entries.length !== 0 || !writable;
	for (const record of entries) {
		const row = document.createElement('div');
		row.className = 'entry';
		const label = document.createElement('span');
		label.textContent =
			modifierNames
				.filter((name) => record.mods[name])
				.concat(record.code)
				.join(' + ') +
			' → ' +
			record.label;
		const modify = document.createElement('button');
		modify.type = 'button';
		modify.textContent = strings.edit;
		modify.addEventListener('click', () => edit(record));
		const remove = document.createElement('button');
		remove.type = 'button';
		remove.textContent = strings.remove;
		remove.addEventListener('click', () => {
			if (pending || !writable) return;
			busy(true);
			post({ action: 'remove', slot: record.slot });
		});
		row.append(label, modify, remove);
		node('entries').appendChild(row);
	}
}

// Called only by the actual page owner after canonical/native capture.
function init(data) {
	strings = data.strings;
	entries = data.entries;
	for (const id of [
		'title',
		'manual-hint',
		'capture',
		'capture-reason',
		'empty',
		'add',
		'position-label',
		'modifier-label',
		'choose',
		'save',
		'cancel',
		'close'
	]) {
		node(id).textContent = strings[id];
	}
	document.title = strings.title;
	node('position').replaceChildren();
	for (const position of data.positions) {
		const option = document.createElement('option');
		option.value = position.code;
		option.textContent = position.code;
		option.disabled = position.available !== true;
		if (position.reason) option.textContent += ' — ' + position.reason;
		node('position').appendChild(option);
	}
	node('modifiers')
		.querySelectorAll('label')
		.forEach((label) => label.remove());
	for (const name of modifierNames) {
		const label = document.createElement('label');
		const input = document.createElement('input');
		input.id = 'mod-' + name;
		input.type = 'checkbox';
		input.addEventListener('change', changed);
		label.append(input, document.createTextNode(name));
		node('modifiers').appendChild(label);
	}
	writable = data.readonly !== true;
	captureAvailable = data.capture === true;
	node('capture').disabled = !captureAvailable || !writable;
	node('capture-reason').hidden = data.capture === true;
	render();
	busy(false);
	status(data.reason || '');
}

// Echoed request identity keeps a late picker result out of a changed draft.
function selected(data) {
	if (data.request_id !== selection || node('editor').hidden || !writable) return;
	token = data.token;
	node('selected-action').textContent = data.label;
	busy(false);
}

// Only the still-owned native request fills the manual draft; page keys cannot mint it.
function captured(data) {
	if (data.request_id !== selection || node('editor').hidden || !writable) return;
	node('position').value = data.code;
	for (const name of modifierNames) node('mod-' + name).checked = data.mods[name] === true;
	token = null;
	node('selected-action').textContent = '';
	busy(false);
}

// Failed publication preserves fields and draft; durable success is never false.
function result(data) {
	if (data.committed !== true) {
		busy(false);
		status(data.reason || 'save_failed');
		return;
	}
	changed();
	node('editor').hidden = true;
	if (data.refreshed !== true) {
		writable = false;
		busy(false);
		status('saved_reopen');
		return;
	}
	entries = data.entries;
	render();
	busy(false);
	status('saved');
}

function refused(reason) {
	busy(false);
	status(reason || 'save_failed');
}

document.addEventListener('DOMContentLoaded', () => {
	node('add').addEventListener('click', () => edit(null));
	node('capture').addEventListener('click', () => {
		if (pending || !writable) return;
		if (node('editor').hidden) edit(null);
		else changed();
		post({ action: 'capture_position', request: { request_id: selection } });
	});
	node('position').addEventListener('change', changed);
	node('cancel').addEventListener('click', () => {
		changed();
		node('editor').hidden = true;
		busy(false);
	});
	node('choose').addEventListener('click', () => {
		if (pending || !writable) return;
		if (!node('position').value || node('position').selectedOptions[0]?.disabled) {
			status('unavailable');
			return;
		}
		changed();
		const mods = {};
		for (const name of modifierNames) mods[name] = node('mod-' + name).checked;
		post({
			action: 'choose',
			request: {
				code: node('position').value,
				mods,
				previous_slot: previous,
				request_id: selection
			}
		});
	});
	node('editor').addEventListener('submit', (event) => {
		event.preventDefault();
		if (pending || !writable || token === null) return;
		busy(true);
		post({ action: 'save', token });
	});
	node('close').addEventListener('click', () => post({ action: 'close' }));
	post({ action: 'ready' });
});
