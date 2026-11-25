// _shared/ui/workflow_model.js

/**
 * ==============================================================================
 * MODULE: User Workflow Model (canonical check)
 * DESCRIPTION:
 * Checks a user workflow file against _shared/shortcuts/data/workflows/steps.json,
 * the single declaration of every step kind, condition, target and bound. The
 * shared Lua validator (_shared/shortcuts/engine/workflows/model.lua, macOS
 * and Linux) and the AutoHotkey port replay
 * _shared/tests/corpus/workflows/validation_vectors.json with the same
 * catalogue, so the editor, the drivers and an imported file accept and refuse
 * the same workflows, for the same reason, at the same JSON Pointer.
 *
 * FEATURES & RATIONALE:
 * 1. Closed key sets: an unknown key is refused, never dropped, so a file
 *    written by a newer editor never runs half-read.
 * 2. One deterministic order: keys and fields are visited sorted, so the
 *    first refusal is the same in JavaScript, Lua and AutoHotkey, whose map
 *    iteration orders differ.
 * 3. The key-combination grammar is the send_shortcut rule of send_keys.json
 *    (send_input_vectors.json), ported here, not a second vocabulary.
 * 4. Pure: no DOM, no host, no I/O. The page loads it as a classic script
 *    (window.ErgoptiWorkflowModel); Node tests run it in a vm context.
 * ==============================================================================
 */

(function (root) {
	'use strict';

	// ========================================
	// ========================================
	// ======= 1/ Text and shortcut rules =====
	// ========================================
	// ========================================

	const TAB = 9;
	const LINE_FEED = 10;
	const CARRIAGE_RETURN = 13;
	const LAST_CONTROL = 31;
	const DELETE = 127;
	const ACTION_PATTERN = /^[a-z][a-z0-9_]{0,63}$/;
	const BASE64_PATTERN = /^[A-Za-z0-9+/]+={0,2}$/;
	const BASE64_QUANTUM = 4;

	/**
	 * UTF-8 length of a string, or -1 when it holds a lone surrogate.
	 * @param {string} value
	 * @returns {number}
	 */
	function utf8Bytes(value) {
		let bytes = 0;
		for (let i = 0; i < value.length; i++) {
			const code = value.charCodeAt(i);
			if (code >= 0xd800 && code <= 0xdbff) {
				const next = value.charCodeAt(i + 1);
				if (!(next >= 0xdc00 && next <= 0xdfff)) return -1;
				bytes += 4;
				i++;
			} else if (code >= 0xdc00 && code <= 0xdfff) {
				return -1;
			} else if (code < 0x80) bytes += 1;
			else if (code < 0x800) bytes += 2;
			else bytes += 3;
		}
		return bytes;
	}

	/**
	 * Whether a string holds a control character a field refuses.
	 * @param {string} value
	 * @param {boolean} multiline Whether line breaks and tabs are text here.
	 * @returns {boolean}
	 */
	function hasForbiddenControl(value, multiline) {
		for (let i = 0; i < value.length; i++) {
			const code = value.charCodeAt(i);
			if (code === DELETE) return true;
			if (code > LAST_CONTROL) continue;
			if (multiline && (code === TAB || code === LINE_FEED || code === CARRIAGE_RETURN)) continue;
			return true;
		}
		return false;
	}

	/**
	 * Finds a vocabulary entry by id or alias, already lower-cased.
	 * @param {Array<object>} entries
	 * @param {string} name
	 * @returns {object|null}
	 */
	function findEntry(entries, name) {
		for (const entry of entries) {
			if (entry.id === name || (entry.aliases || []).indexOf(name) >= 0) return entry;
		}
		return null;
	}

	/**
	 * Lower-cases ASCII letters only, as the Lua rule does.
	 * @param {string} value
	 * @returns {string}
	 */
	function asciiLower(value) {
		return value.replace(/[A-Z]/g, (c) => c.toLowerCase());
	}

	/**
	 * Parses a key of a shortcut: a named key or one printable character.
	 * @param {string} value
	 * @param {object} vocabulary Decoded send_keys.json.
	 * @returns {string|null} The canonical key, or null.
	 */
	function parseShortcutKey(value, vocabulary) {
		const wanted = value.trim();
		if (wanted === '') return null;
		const entry = findEntry(vocabulary.keys, asciiLower(wanted));
		if (entry) return entry.id;
		const points = Array.from(wanted);
		if (points.length !== 1 || utf8Bytes(wanted) < 0) return null;
		const code = points[0].codePointAt(0);
		if (code <= LAST_CONTROL || code === DELETE) return null;
		return asciiLower(wanted);
	}

	/**
	 * Parses a key combination with the send_shortcut grammar.
	 * @param {*} value
	 * @param {object} vocabulary Decoded send_keys.json.
	 * @returns {string|null} The canonical spelling, or null when refused.
	 */
	function parseShortcut(value, vocabulary) {
		if (typeof value !== 'string') return null;
		const wanted = value.trim();
		if (wanted === '') return null;
		let keyToken;
		let modPart;
		if (wanted.length >= 2 && wanted.endsWith('++')) {
			keyToken = '+';
			modPart = wanted.slice(0, -2);
		} else {
			const at = wanted.lastIndexOf('+');
			if (at < 0) return null;
			modPart = wanted.slice(0, at);
			keyToken = wanted.slice(at + 1);
		}
		const held = {};
		for (const token of modPart.split('+')) {
			const entry = findEntry(vocabulary.modifiers, asciiLower(token.trim()));
			if (!entry || held[entry.id]) return null;
			held[entry.id] = true;
		}
		const key = parseShortcutKey(keyToken, vocabulary);
		if (key === null) return null;
		let prefix = '';
		for (const entry of vocabulary.modifiers) if (held[entry.id]) prefix += entry.id + '+';
		return prefix + key;
	}

	// ========================================
	// ========================================
	// ======= 2/ Checker =====================
	// ========================================
	// ========================================

	/**
	 * Escapes one JSON Pointer segment (RFC 6901).
	 * @param {string|number} segment
	 * @returns {string}
	 */
	function pointerSegment(segment) {
		return String(segment).replace(/~/g, '~0').replace(/\//g, '~1');
	}

	/**
	 * @param {*} value
	 * @returns {boolean} Whether value is a plain JSON object.
	 */
	function isObject(value) {
		return value !== null && typeof value === 'object' && !Array.isArray(value);
	}

	/**
	 * A refusal, thrown inside the walk and returned by the entry points.
	 * @param {string} reason One of steps.json reasons.
	 * @param {string} path JSON Pointer of the refused value.
	 */
	function Refusal(reason, path) {
		this.reason = reason;
		this.path = path;
	}

	/**
	 * Builds the checker of one catalogue and run context.
	 * @param {object} catalogue Decoded steps.json.
	 * @param {object} context { vocabulary: decoded send_keys.json, timings: { wait_max_ms } }.
	 * @returns {object} The walker.
	 */
	function makeChecker(catalogue, context) {
		if (!isObject(catalogue) || !isObject(catalogue.kinds) || !isObject(catalogue.limits)) {
			throw new Error('workflow_model: the catalogue is not the decoded steps.json');
		}
		if (!context || !isObject(context.vocabulary) || !isObject(context.timings)) {
			throw new Error('workflow_model: a check needs the send_keys vocabulary and the timings');
		}
		const limits = catalogue.limits;
		const identifier = new RegExp(catalogue.identifier_pattern);
		const workflowId = new RegExp(catalogue.workflow_id_pattern);
		const reasons = new Set(catalogue.reasons);

		function refuse(reason, path) {
			if (!reasons.has(reason)) throw new Error('workflow_model: undeclared reason ' + reason);
			throw new Refusal(reason, path);
		}

		function bound(name) {
			if (Object.prototype.hasOwnProperty.call(limits, name)) return limits[name];
			if (Object.prototype.hasOwnProperty.call(context.timings, name)) return context.timings[name];
			throw new Error('workflow_model: no bound named ' + name);
		}

		function checkKeys(value, allowed, path) {
			const unknown = Object.keys(value)
				.filter((key) => allowed.indexOf(key) < 0)
				.sort();
			if (unknown.length > 0) refuse('unknown_key', path + '/' + pointerSegment(unknown[0]));
		}

		function checkText(value, spec, path, maximum) {
			if (typeof value !== 'string') refuse('bad_type', path);
			const bytes = utf8Bytes(value);
			if (bytes < 0) refuse('bad_text', path);
			if (bytes > maximum) refuse('too_long', path);
			if (value === '' && !spec.allow_empty) refuse('bad_text', path);
			if (hasForbiddenControl(value, spec.multiline === true)) refuse('bad_text', path);
		}

		function checkFields(value, fields, path, state) {
			for (const name of Object.keys(fields).sort()) {
				const spec = fields[name];
				const fieldPath = path + '/' + pointerSegment(name);
				if (!Object.prototype.hasOwnProperty.call(value, name)) {
					if (spec.required) refuse('missing_field', fieldPath);
					continue;
				}
				checkValue(value[name], spec, fieldPath, state);
			}
		}

		function checkTyped(value, table, path, state) {
			if (!isObject(value)) refuse('not_object', path);
			if (!Object.prototype.hasOwnProperty.call(value, 'type'))
				refuse('missing_field', path + '/type');
			if (typeof value.type !== 'string') refuse('bad_type', path + '/type');
			if (!Object.prototype.hasOwnProperty.call(table, value.type))
				refuse('bad_enum', path + '/type');
			const declared = table[value.type];
			const fields = declared.fields || declared;
			checkKeys(value, ['type'].concat(Object.keys(fields)), path);
			checkFields(value, fields, path, state);
			if (value.type === 'matches') {
				if (value.source === 'variable' && value.variable === undefined) {
					refuse('variable_required', path + '/variable');
				}
				if (value.op !== 'empty' && value.value === undefined)
					refuse('value_required', path + '/value');
			}
		}

		function checkValue(value, spec, path, state) {
			switch (spec.type) {
				case 'text':
					return checkText(value, spec, path, limits.text_bytes);
				case 'shortcut':
					if (typeof value !== 'string') refuse('bad_type', path);
					if (parseShortcut(value, context.vocabulary) === null) refuse('bad_shortcut', path);
					return undefined;
				case 'integer': {
					if (typeof value !== 'number' || !Number.isInteger(value)) refuse('bad_type', path);
					const maximum = spec.max_limit === undefined ? spec.max : bound(spec.max_limit);
					if (value < spec.min || value > maximum) refuse('out_of_range', path);
					return undefined;
				}
				case 'enum':
					if (typeof value !== 'string') refuse('bad_type', path);
					if (spec.values.indexOf(value) < 0) refuse('bad_enum', path);
					return undefined;
				case 'variable':
					if (typeof value !== 'string') refuse('bad_type', path);
					if (!identifier.test(value)) refuse('bad_identifier', path);
					state.variables.add(value);
					if (state.variables.size > limits.variables_max) refuse('too_many_variables', path);
					return undefined;
				case 'action':
					if (typeof value !== 'string') refuse('bad_type', path);
					if (!ACTION_PATTERN.test(value)) refuse('bad_identifier', path);
					return undefined;
				case 'image':
					if (typeof value !== 'string') refuse('bad_type', path);
					if (!identifier.test(value)) refuse('bad_identifier', path);
					if (!Object.prototype.hasOwnProperty.call(state.images, value))
						refuse('unknown_image', path);
					return undefined;
				case 'target':
					return checkTyped(value, catalogue.targets, path, state);
				case 'condition':
					return checkTyped(value, catalogue.conditions, path, state);
				case 'steps':
					return checkSteps(value, path, state.depth + 1, state);
				default:
					throw new Error('workflow_model: no field type ' + spec.type);
			}
		}

		function checkStep(step, path, depth, state) {
			if (!isObject(step)) refuse('not_object', path);
			if (depth > limits.depth_max) refuse('too_deep', path);
			state.count += 1;
			if (state.count > limits.steps_max) refuse('too_many_steps', state.stepsPath);
			if (!Object.prototype.hasOwnProperty.call(step, 'kind'))
				refuse('missing_field', path + '/kind');
			if (typeof step.kind !== 'string') refuse('bad_type', path + '/kind');
			if (!Object.prototype.hasOwnProperty.call(catalogue.kinds, step.kind))
				refuse('unknown_kind', path + '/kind');
			const fields = catalogue.kinds[step.kind].fields;
			checkKeys(step, catalogue.common_step_keys.concat(Object.keys(fields)), path);
			if (step.note !== undefined) checkText(step.note, {}, path + '/note', limits.name_bytes);
			const outer = state.depth;
			state.depth = depth;
			checkFields(step, fields, path, state);
			state.depth = outer;
		}

		function checkSteps(list, path, depth, state) {
			if (!Array.isArray(list)) refuse('bad_type', path);
			list.forEach((step, index) => checkStep(step, path + '/' + index, depth, state));
		}

		function checkImages(images, path) {
			if (!isObject(images)) refuse('not_object', path);
			const names = Object.keys(images).sort();
			if (names.length > limits.images_max) refuse('too_many_images', path);
			for (const name of names) {
				const imagePath = path + '/' + pointerSegment(name);
				const data = images[name];
				if (!identifier.test(name)) refuse('bad_identifier', imagePath);
				if (typeof data !== 'string') refuse('bad_type', imagePath);
				if (data.length > limits.image_base64_bytes) refuse('too_long', imagePath);
				if (
					!BASE64_PATTERN.test(data) ||
					data.length % BASE64_QUANTUM !== 0 ||
					!data.startsWith(catalogue.png_base64_prefix)
				) {
					refuse('bad_image', imagePath);
				}
			}
		}

		function checkWorkflow(workflow, path) {
			if (!isObject(workflow)) refuse('not_object', path);
			checkKeys(workflow, catalogue.workflow_keys, path);
			for (const name of ['id', 'name', 'origin', 'steps']) {
				if (!Object.prototype.hasOwnProperty.call(workflow, name))
					refuse('missing_field', path + '/' + name);
			}
			if (typeof workflow.id !== 'string') refuse('bad_type', path + '/id');
			if (!workflowId.test(workflow.id)) refuse('bad_identifier', path + '/id');
			checkText(workflow.name, {}, path + '/name', limits.name_bytes);
			if (typeof workflow.origin !== 'string') refuse('bad_type', path + '/origin');
			if (catalogue.origins.indexOf(workflow.origin) < 0) refuse('bad_enum', path + '/origin');
			const images = workflow.images === undefined ? {} : workflow.images;
			if (workflow.images !== undefined) checkImages(images, path + '/images');
			const state = {
				count: 0,
				depth: 0,
				images: images,
				variables: new Set(),
				stepsPath: path + '/steps'
			};
			checkSteps(workflow.steps, path + '/steps', 1, state);
		}

		function checkFile(doc) {
			if (!isObject(doc)) refuse('not_object', '');
			checkKeys(doc, ['schema_version', 'workflows'], '');
			if (doc.schema_version !== catalogue.schema_version)
				refuse('schema_version', '/schema_version');
			if (!Object.prototype.hasOwnProperty.call(doc, 'workflows'))
				refuse('missing_field', '/workflows');
			if (!Array.isArray(doc.workflows)) refuse('bad_type', '/workflows');
			if (doc.workflows.length > limits.workflows_max) refuse('too_many_workflows', '/workflows');
			const seen = new Set();
			doc.workflows.forEach((workflow, index) => {
				const path = '/workflows/' + index;
				checkWorkflow(workflow, path);
				if (seen.has(workflow.id)) refuse('duplicate_id', path + '/id');
				seen.add(workflow.id);
			});
		}

		return { checkFile: checkFile, checkWorkflow: checkWorkflow };
	}

	/**
	 * Runs one check and turns a refusal into a result.
	 * @param {Function} body
	 * @returns {{ ok: boolean, reason?: string, path?: string }}
	 */
	function outcome(body) {
		try {
			body();
			return { ok: true };
		} catch (error) {
			if (error instanceof Refusal) return { ok: false, reason: error.reason, path: error.path };
			throw error;
		}
	}

	// ========================================
	// ========================================
	// ======= 3/ Public API ==================
	// ========================================
	// ========================================

	const api = {
		/**
		 * Checks a whole workflow file.
		 * @param {*} doc The decoded file.
		 * @param {object} catalogue Decoded steps.json.
		 * @param {object} context { vocabulary, timings }.
		 * @returns {{ ok: boolean, reason?: string, path?: string }}
		 */
		validateFile: (doc, catalogue, context) =>
			outcome(() => makeChecker(catalogue, context).checkFile(doc)),

		/**
		 * Checks one workflow, its refusal path rooted at the workflow.
		 * @param {*} workflow
		 * @param {object} catalogue Decoded steps.json.
		 * @param {object} context { vocabulary, timings }.
		 * @returns {{ ok: boolean, reason?: string, path?: string }}
		 */
		validateWorkflow: (workflow, catalogue, context) =>
			outcome(() => makeChecker(catalogue, context).checkWorkflow(workflow, '')),

		parseShortcut: parseShortcut,
		utf8Bytes: utf8Bytes
	};

	root.ErgoptiWorkflowModel = api;
})(globalThis);
