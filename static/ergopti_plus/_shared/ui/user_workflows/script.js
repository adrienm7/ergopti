// _shared/ui/user_workflows/script.js

/**
 * ==============================================================================
 * MODULE: User Workflows Editor
 * DESCRIPTION:
 * The « Workflows personnalisés… » window: lists the user's workflows and edits
 * one at a time (name, steps, nested « if » and « repeat » blocks, embedded
 * images), duplicates, deletes, imports and exports them, and test-runs the
 * selected one through the driver's runner with the running step highlighted.
 *
 * FEATURES & RATIONALE:
 * 1. One model: every field, bound and refusal comes from steps.json through
 *    workflow_model.js, the check the drivers replay, so the window never
 *    saves a file a driver would refuse.
 * 2. Keyboard first: every step moves with its Up and Down buttons; drag and
 *    drop is an extra for the pointer, never the only way.
 * 3. A shell step of an imported workflow is refused at run time until the
 *    user approves it here; the approval goes to the host, which stores it
 *    outside the workflow file.
 * 4. Host protocol (bridge hsWorkflows): the page posts ready, save, test_run,
 *    stop, approve_shell, export, import, pick_image and close; the host calls
 *    initData, onSaved, onImported, onImagePicked, onRunStep and onRunEnd.
 *    The host reads a picked image: WKWebView offers no file input.
 * ==============================================================================
 */

const _post = makeHostBridge('hsWorkflows');
const Model = window.ErgoptiWorkflowModel;

// ========================================
// ========================================
// ======= 1/ State and strings ===========
// ========================================
// ========================================

let _strings = {};
let _catalogue = null;
let _vocabulary = null;
let _timings = null;
let _actions = [];
let _approved = {};
let _doc = { schema_version: 1, workflows: [] };
let _selected = -1;
let _running = false;
let _dragged = null;

/**
 * Returns the translated string for key, or key itself as fallback.
 * @param {string} key
 * @returns {string}
 */
function _t(key) {
	return _strings[key] || key;
}

/**
 * Replaces {1}, {2}… in one pass.
 * @param {string} text
 * @param {Array<string>} values
 * @returns {string}
 */
function _fill(text, values) {
	return text.replace(/\{(\d+)\}/g, (all, n) =>
		values[n - 1] === undefined ? all : String(values[n - 1])
	);
}

/** Applies the static strings of the page. */
function applyDomStrings() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		const key = el.getAttribute('data-i18n');
		if (_strings[key] === undefined) return;
		if (el.tagName === 'TITLE') document.title = _strings[key];
		else el.textContent = _strings[key];
	});
	document.querySelectorAll('[data-i18n-aria-label]').forEach(function (el) {
		el.setAttribute('aria-label', _t(el.getAttribute('data-i18n-aria-label')));
	});
}

/**
 * Shows a status line, read by screen readers.
 * @param {string} text
 * @param {boolean} isError
 */
function showStatus(text, isError) {
	const status = document.getElementById('status');
	status.textContent = text;
	status.classList.toggle('error', isError === true);
}

/** @returns {object|null} The selected workflow. */
function current() {
	return _selected >= 0 ? _doc.workflows[_selected] : null;
}

/**
 * A fresh workflow id, unique in the document.
 * @returns {string}
 */
function newId() {
	const used = new Set(_doc.workflows.map((w) => w.id));
	let id;
	do {
		id = 'wf_' + Math.random().toString(36).slice(2, 10);
	} while (used.has(id));
	return id;
}

// ========================================
// ========================================
// ======= 2/ Step model ==================
// ========================================
// ========================================

/**
 * A new step of a kind, with each required field at a valid starting value.
 * @param {string} kind
 * @returns {object}
 */
function newStep(kind) {
	const step = { kind: kind };
	const fields = _catalogue.kinds[kind].fields;
	for (const [name, spec] of Object.entries(fields)) {
		if (!spec.required) continue;
		step[name] = defaultValue(spec, name);
	}
	return step;
}

/**
 * @param {object} spec A field declaration of steps.json.
 * @param {string} name
 * @returns {*} A starting value the user then edits.
 */
function defaultValue(spec, name) {
	switch (spec.type) {
		case 'integer':
			return Math.max(spec.min, name === 'count' ? 1 : spec.min);
		case 'enum':
			return spec.values[0];
		case 'shortcut':
			return 'ctrl+a';
		case 'variable':
			return 'text';
		case 'action':
			return _actions.length > 0 ? _actions[0].id : 'select_all';
		case 'steps':
			return [];
		case 'target':
			return { type: 'text', text: '' };
		case 'condition':
			return { type: 'app_front', app: '' };
		default:
			return '';
	}
}

/**
 * The element id of a step from its dotted path (1-based, as the runner
 * reports it: 3, 3.then.2, 4.1).
 * @param {string} path
 * @returns {string}
 */
function stepElementId(path) {
	return 'step-' + String(path).replace(/\./g, '-');
}

// ========================================
// ========================================
// ======= 3/ Rendering ===================
// ========================================
// ========================================

/** Draws the list of workflows. */
function renderList() {
	const list = document.getElementById('workflow-list');
	list.replaceChildren();
	document.getElementById('list-empty').hidden = _doc.workflows.length > 0;
	_doc.workflows.forEach(function (workflow, index) {
		const item = document.createElement('li');
		const button = document.createElement('button');
		button.type = 'button';
		button.className = 'workflow-item';
		button.textContent = workflow.name;
		button.setAttribute('aria-current', index === _selected ? 'true' : 'false');
		button.addEventListener('click', function () {
			select(index);
		});
		item.appendChild(button);
		list.appendChild(item);
	});
	const has = current() !== null;
	document.getElementById('btn-duplicate').disabled = !has;
	document.getElementById('btn-delete').disabled = !has;
	document.getElementById('btn-export').disabled = _doc.workflows.length === 0;
	document.getElementById('btn-run').disabled = !has || _running;
	document.getElementById('btn-stop').disabled = !_running;
}

/**
 * Selects a workflow and draws its editor.
 * @param {number} index
 */
function select(index) {
	_selected = index;
	renderList();
	renderEditor();
}

/** Draws the editor of the selected workflow. */
function renderEditor() {
	const editor = document.getElementById('editor');
	const workflow = current();
	editor.hidden = workflow === null;
	if (!workflow) return;
	document.getElementById('input-name').value = workflow.name;
	const hasShell = containsShell(workflow.steps);
	document.getElementById('import-banner').hidden = !(
		workflow.origin === 'import' &&
		hasShell &&
		_approved[workflow.id] !== true
	);
	const steps = document.getElementById('steps');
	steps.replaceChildren();
	renderSteps(steps, workflow.steps, '');
	steps.appendChild(addStepRow(workflow.steps, ''));
	renderImages(workflow);
}

/**
 * @param {Array<object>} steps
 * @returns {boolean} Whether a shell step is in the list or a nested one.
 */
function containsShell(steps) {
	return (steps || []).some(
		(s) =>
			s.kind === 'shell' ||
			containsShell(s.then) ||
			containsShell(s.else) ||
			(s.kind === 'repeat' && containsShell(s.steps))
	);
}

/**
 * Draws a list of steps into an <ol>.
 * @param {HTMLElement} container
 * @param {Array<object>} steps The list (edited in place).
 * @param {string} prefix Dotted path prefix of the list.
 */
function renderSteps(container, steps, prefix) {
	const template = document.getElementById('step-template');
	steps.forEach(function (step, index) {
		const path = prefix + (index + 1);
		const node = template.content.firstElementChild.cloneNode(true);
		node.id = stepElementId(path);
		node.querySelectorAll('[data-i18n]').forEach((el) => (el.textContent = _t(el.dataset.i18n)));
		node.querySelector('.step-title').textContent =
			path + ' · ' + _t('workflows.step.' + step.kind);
		const up = node.querySelector('.btn-up');
		const down = node.querySelector('.btn-down');
		up.disabled = index === 0;
		down.disabled = index === steps.length - 1;
		up.addEventListener('click', () => moveStep(steps, index, index - 1, path));
		down.addEventListener('click', () => moveStep(steps, index, index + 1, path));
		node.querySelector('.btn-remove').addEventListener('click', function () {
			steps.splice(index, 1);
			renderEditor();
		});
		bindDrag(node, steps, index);
		renderFields(node.querySelector('.step-fields'), step, path);
		container.appendChild(node);
	});
}

/**
 * Moves a step within its list and keeps the keyboard focus on it.
 * @param {Array<object>} steps
 * @param {number} from
 * @param {number} to
 * @param {string} path Dotted path of the moved step before the move.
 */
function moveStep(steps, from, to, path) {
	if (to < 0 || to >= steps.length) return;
	const [step] = steps.splice(from, 1);
	steps.splice(to, 0, step);
	renderEditor();
	const moved = path.replace(/\d+$/, String(to + 1));
	const target = document.getElementById(stepElementId(moved));
	const button = target && target.querySelector(to < from ? '.btn-up' : '.btn-down');
	if (button && !button.disabled) button.focus();
	else if (target) target.querySelector('button').focus();
	showStatus(_fill(_t('workflows.editor.moved'), [moved]), false);
}

/**
 * Lets a step be dragged within its own list.
 * @param {HTMLElement} node
 * @param {Array<object>} steps
 * @param {number} index
 */
function bindDrag(node, steps, index) {
	node.addEventListener('dragstart', function (event) {
		_dragged = { steps: steps, index: index };
		event.dataTransfer.effectAllowed = 'move';
		event.stopPropagation();
	});
	node.addEventListener('dragover', function (event) {
		if (_dragged && _dragged.steps === steps) event.preventDefault();
	});
	node.addEventListener('drop', function (event) {
		if (!_dragged || _dragged.steps !== steps) return;
		event.preventDefault();
		event.stopPropagation();
		const [step] = steps.splice(_dragged.index, 1);
		steps.splice(index, 0, step);
		_dragged = null;
		renderEditor();
	});
}

/**
 * The « add a step » row of a list.
 * @param {Array<object>} steps
 * @param {string} prefix
 * @returns {HTMLElement}
 */
function addStepRow(steps, prefix) {
	const row = document.createElement('li');
	row.className = 'add-step';
	const id = 'add-' + (prefix || 'root').replace(/\./g, '-');
	const label = document.createElement('label');
	label.htmlFor = id;
	label.textContent = _t('workflows.editor.add_step');
	const choose = document.createElement('select');
	choose.id = id;
	for (const kind of Object.keys(_catalogue.kinds)) {
		const option = document.createElement('option');
		option.value = kind;
		option.textContent = _t('workflows.step.' + kind);
		choose.appendChild(option);
	}
	const add = document.createElement('button');
	add.type = 'button';
	add.textContent = _t('workflows.editor.add');
	add.addEventListener('click', function () {
		steps.push(newStep(choose.value));
		renderEditor();
		const added = document.getElementById(stepElementId(prefix + steps.length));
		if (added) added.querySelector('button').focus();
	});
	row.append(label, choose, add);
	return row;
}

/**
 * Draws the fields of a step.
 * @param {HTMLElement} container
 * @param {object} step Edited in place.
 * @param {string} path
 */
function renderFields(container, step, path) {
	const fields = _catalogue.kinds[step.kind].fields;
	for (const [name, spec] of Object.entries(fields)) {
		container.appendChild(fieldControl(step, name, spec, path));
	}
}

/**
 * One labelled control for a field.
 * @param {object} owner The object holding the field (a step, a target, a condition).
 * @param {string} name
 * @param {object} spec
 * @param {string} path
 * @returns {HTMLElement}
 */
function fieldControl(owner, name, spec, path) {
	const id = 'f-' + path.replace(/\./g, '-') + '-' + name;
	if (spec.type === 'steps') {
		const box = document.createElement('fieldset');
		box.className = 'nested';
		const legend = document.createElement('legend');
		legend.textContent = _t('workflows.field.' + name);
		const list = document.createElement('ol');
		list.className = 'steps';
		if (owner[name] === undefined) owner[name] = [];
		const prefix = path + '.' + (name === 'steps' ? '' : name + '.');
		renderSteps(list, owner[name], prefix);
		list.appendChild(addStepRow(owner[name], prefix));
		box.append(legend, list);
		return box;
	}
	if (spec.type === 'target' || spec.type === 'condition')
		return typedControl(owner, name, spec, path);
	const row = document.createElement('p');
	row.className = 'field';
	const label = document.createElement('label');
	label.htmlFor = id;
	label.textContent =
		_t('workflows.field.' + name) + (spec.required ? '' : ' ' + _t('workflows.editor.optional'));
	let control;
	if (spec.type === 'enum' || spec.type === 'action' || spec.type === 'image') {
		control = document.createElement('select');
		const choices =
			spec.type === 'enum'
				? spec.values.map((v) => ({ value: v, label: _t('workflows.value.' + v) }))
				: spec.type === 'action'
					? _actions.map((a) => ({ value: a.id, label: a.label }))
					: Object.keys(current().images || {}).map((v) => ({ value: v, label: v }));
		if (!spec.required) choices.unshift({ value: '', label: _t('workflows.editor.none') });
		for (const choice of choices) {
			const option = document.createElement('option');
			option.value = choice.value;
			option.textContent = choice.label;
			control.appendChild(option);
		}
		control.value = owner[name] === undefined ? '' : owner[name];
	} else if (spec.type === 'text' && spec.multiline) {
		control = document.createElement('textarea');
		control.rows = 2;
		control.value = owner[name] || '';
	} else {
		control = document.createElement('input');
		control.type = spec.type === 'integer' ? 'number' : 'text';
		if (spec.type === 'integer') {
			control.min = String(spec.min);
			control.max = String(spec.max_limit ? bound(spec.max_limit) : spec.max);
			control.step = '1';
		}
		control.value = owner[name] === undefined ? '' : String(owner[name]);
	}
	control.id = id;
	control.addEventListener('change', function () {
		const raw = control.value;
		if (raw === '' && !spec.required) delete owner[name];
		else if (spec.type === 'integer') owner[name] = Number(raw);
		else owner[name] = raw;
	});
	row.append(label, control);
	if (spec.type === 'text' && spec.placeholders) {
		const hint = document.createElement('small');
		hint.textContent = _t('workflows.editor.placeholder_hint');
		row.appendChild(hint);
	}
	return row;
}

/**
 * @param {string} name A limits or timings key.
 * @returns {number}
 */
function bound(name) {
	return _catalogue.limits[name] !== undefined ? _catalogue.limits[name] : _timings[name];
}

/**
 * The control of a target or a condition: its type, then its own fields.
 * @param {object} owner
 * @param {string} name
 * @param {object} spec
 * @param {string} path
 * @returns {HTMLElement}
 */
function typedControl(owner, name, spec, path) {
	const table = spec.type === 'target' ? _catalogue.targets : _catalogue.conditions;
	const value = owner[name];
	const box = document.createElement('fieldset');
	box.className = 'nested';
	const legend = document.createElement('legend');
	legend.textContent = _t('workflows.field.' + name);
	const id = 'f-' + path.replace(/\./g, '-') + '-' + name + '-type';
	const row = document.createElement('p');
	row.className = 'field';
	const label = document.createElement('label');
	label.htmlFor = id;
	label.textContent = _t('workflows.field.type');
	const choose = document.createElement('select');
	choose.id = id;
	for (const type of Object.keys(table)) {
		const option = document.createElement('option');
		option.value = type;
		option.textContent = _t('workflows.value.' + type);
		choose.appendChild(option);
	}
	choose.value = value.type;
	choose.addEventListener('change', function () {
		const fresh = { type: choose.value };
		const fields = table[choose.value].fields || table[choose.value];
		for (const [field, fieldSpec] of Object.entries(fields)) {
			if (fieldSpec.required) fresh[field] = defaultValue(fieldSpec, field);
		}
		owner[name] = fresh;
		renderEditor();
	});
	row.append(label, choose);
	box.append(legend, row);
	const fields = table[value.type].fields || table[value.type];
	for (const [field, fieldSpec] of Object.entries(fields)) {
		box.appendChild(fieldControl(value, field, fieldSpec, path + '-' + name));
	}
	return box;
}

/**
 * Draws the embedded images with a remove button each.
 * @param {object} workflow
 */
function renderImages(workflow) {
	const list = document.getElementById('images');
	list.replaceChildren();
	for (const name of Object.keys(workflow.images || {})) {
		const item = document.createElement('li');
		const image = document.createElement('img');
		image.src = 'data:image/png;base64,' + workflow.images[name];
		image.alt = _fill(_t('workflows.editor.image_alt'), [name]);
		const caption = document.createElement('code');
		caption.textContent = name;
		const remove = document.createElement('button');
		remove.type = 'button';
		remove.textContent = _t('workflows.editor.remove_image');
		remove.addEventListener('click', function () {
			delete workflow.images[name];
			renderEditor();
		});
		item.append(image, caption, remove);
		list.appendChild(item);
	}
}

// ========================================
// ========================================
// ======= 4/ Actions =====================
// ========================================
// ========================================

/**
 * Checks the whole document with the shared model and names the first
 * refusal, so nothing is saved that a driver would refuse.
 * @returns {boolean}
 */
function checkDocument() {
	const result = Model.validateFile(_doc, _catalogue, {
		vocabulary: _vocabulary,
		timings: _timings
	});
	if (result.ok) return true;
	showStatus(
		_fill(_t('workflows.editor.invalid'), [_t('workflows.refusal.' + result.reason), result.path]),
		true
	);
	return false;
}

/** Saves the document through the host. */
function save() {
	if (!checkDocument()) return;
	_post({ action: 'save', doc: _doc });
}

/** Wires every button of the page. */
function bindButtons() {
	document.getElementById('btn-new').addEventListener('click', function () {
		_doc.workflows.push({
			id: newId(),
			name: _fill(_t('workflows.editor.new_name'), [_doc.workflows.length + 1]),
			origin: 'local',
			steps: []
		});
		select(_doc.workflows.length - 1);
		document.getElementById('input-name').focus();
	});
	document.getElementById('btn-duplicate').addEventListener('click', function () {
		const copy = JSON.parse(JSON.stringify(current()));
		copy.id = newId();
		copy.name = _fill(_t('workflows.editor.copy_name'), [copy.name]);
		copy.origin = 'local';
		_doc.workflows.push(copy);
		select(_doc.workflows.length - 1);
	});
	// Two presses delete: the first asks, in the button itself (a WebView may
	// show no native confirm dialog), any other action cancels the request.
	const deleteButton = document.getElementById('btn-delete');
	deleteButton.addEventListener('click', function () {
		const workflow = current();
		if (!workflow) return;
		if (deleteButton.dataset.armed !== 'true') {
			deleteButton.dataset.armed = 'true';
			deleteButton.textContent = _fill(_t('workflows.editor.confirm_delete'), [workflow.name]);
			return;
		}
		deleteButton.dataset.armed = 'false';
		deleteButton.textContent = _t('workflows.editor.delete');
		_doc.workflows.splice(_selected, 1);
		select(Math.min(_selected, _doc.workflows.length - 1));
		showStatus(_fill(_t('workflows.editor.deleted'), [workflow.name]), false);
	});
	deleteButton.addEventListener('blur', function () {
		deleteButton.dataset.armed = 'false';
		deleteButton.textContent = _t('workflows.editor.delete');
	});
	document.getElementById('input-name').addEventListener('input', function (event) {
		current().name = event.target.value;
		renderList();
	});
	document.getElementById('btn-save').addEventListener('click', save);
	document.getElementById('btn-close').addEventListener('click', () => _post({ action: 'close' }));
	document.getElementById('btn-run').addEventListener('click', function () {
		if (!checkDocument()) return;
		_running = true;
		renderList();
		showStatus(_t('workflows.editor.running'), false);
		_post({ action: 'test_run', doc: _doc, id: current().id });
	});
	document.getElementById('btn-stop').addEventListener('click', () => _post({ action: 'stop' }));
	document.getElementById('btn-approve').addEventListener('click', function () {
		if (!checkDocument()) return;
		_post({ action: 'approve_shell', doc: _doc, id: current().id });
	});
	document.getElementById('btn-export').addEventListener('click', function () {
		if (!checkDocument()) return;
		const workflow = current();
		_post({
			action: 'export',
			doc: {
				schema_version: _catalogue.schema_version,
				workflows: workflow ? [workflow] : _doc.workflows
			}
		});
	});
	document
		.getElementById('btn-import')
		.addEventListener('click', () => _post({ action: 'import' }));
	document.getElementById('btn-add-image').addEventListener('click', function () {
		if (current()) _post({ action: 'pick_image' });
	});
	document.addEventListener('keydown', function (event) {
		if (event.key === 'Escape' && _running) _post({ action: 'stop' });
	});
}

// ========================================
// ========================================
// ======= 5/ Host entry points ===========
// ========================================
// ========================================

/**
 * First data from the host.
 * @param {object} data { strings, catalogue, vocabulary, timings, doc, actions, approved }
 */
window.initData = function (data) {
	_strings = data.strings || {};
	_catalogue = data.catalogue;
	_vocabulary = data.vocabulary;
	_timings = data.timings;
	_actions = data.actions || [];
	_approved = data.approved || {};
	_doc = data.doc || { schema_version: _catalogue.schema_version, workflows: [] };
	applyDomStrings();
	select(_doc.workflows.length > 0 ? 0 : -1);
};

/**
 * The host's answer to save or approve_shell.
 * @param {object} result { ok, reason, path, approved }
 */
window.onSaved = function (result) {
	if (result.approved) _approved = result.approved;
	if (result.ok) showStatus(_t('workflows.editor.saved'), false);
	else
		showStatus(
			_fill(_t('workflows.editor.invalid'), [
				_t('workflows.refusal.' + result.reason),
				result.path || '/'
			]),
			true
		);
	renderEditor();
};

/**
 * The workflows of an imported file, already checked and stamped « import »
 * by the host.
 * @param {object} result { ok, workflows, reason, path }
 */
window.onImported = function (result) {
	if (!result.ok) {
		showStatus(
			_fill(_t('workflows.editor.invalid'), [
				_t('workflows.refusal.' + result.reason),
				result.path || '/'
			]),
			true
		);
		return;
	}
	const used = new Set(_doc.workflows.map((w) => w.id));
	for (const workflow of result.workflows) {
		if (used.has(workflow.id)) workflow.id = newId();
		workflow.origin = 'import';
		used.add(workflow.id);
		_doc.workflows.push(workflow);
	}
	showStatus(_fill(_t('workflows.editor.imported'), [result.workflows.length]), false);
	select(_doc.workflows.length - 1);
};

/**
 * A PNG the host read for the selected workflow (WKWebView has no file input).
 * @param {object} result { ok, name, data, reason }
 */
window.onImagePicked = function (result) {
	const workflow = current();
	if (!workflow) return;
	if (!result.ok) {
		showStatus(
			_fill(_t('workflows.editor.invalid'), [_t('workflows.refusal.' + result.reason), '/']),
			true
		);
		return;
	}
	workflow.images = workflow.images || {};
	let name = (result.name.replace(/[^A-Za-z0-9_]/g, '_') || 'image').slice(0, 24);
	if (!/^[A-Za-z_]/.test(name)) name = 'i_' + name;
	let unique = name;
	for (let n = 2; workflow.images[unique] !== undefined; n++) unique = name.slice(0, 20) + '_' + n;
	workflow.images[unique] = result.data;
	renderEditor();
};

/**
 * Highlights the step the test run is performing.
 * @param {object} step { path }
 */
window.onRunStep = function (step) {
	document.querySelectorAll('.step.running').forEach((el) => el.classList.remove('running'));
	const node = document.getElementById(stepElementId(step.path));
	if (node) {
		node.classList.add('running');
		node.scrollIntoView({ block: 'nearest' });
	}
	showStatus(_fill(_t('workflows.editor.running_step'), [step.path]), false);
};

/**
 * The end of a test run.
 * @param {object} outcome { op, reason, path, kind }
 */
window.onRunEnd = function (outcome) {
	_running = false;
	document.querySelectorAll('.step.running').forEach((el) => el.classList.remove('running'));
	if (outcome.op === 'done') showStatus(_t('workflows.editor.run_done'), false);
	else
		showStatus(
			_fill(_t('workflows.editor.run_failed'), [
				outcome.path || '?',
				_t('workflows.reason.' + outcome.reason)
			]),
			true
		);
	renderList();
};

bindButtons();
_post({ action: 'ready' });
