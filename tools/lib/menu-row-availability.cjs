// tools/lib/menu-row-availability.cjs

/**
 * Canonical availability declarations shared by the menu compiler and I2.
 * HIDE describes a presentation that does not apply on the omitted platforms;
 * GREY describes a presentation not yet ported, with its translated reason.
 * Only the caller's actual [menu.*] row receives this classification. Feature
 * and section restrictions continue to describe product capabilities.
 */
'use strict';

const PLATFORMS = ['ahk', 'hs', 'linux'];
// Source row types described by the compiler's generated-manifest header.
const ROW_TYPES = new Set([
	'toggle',
	'feature',
	'action',
	'dynamic',
	'group',
	'include',
	'label',
	'section_header',
	'---',
	'list',
	'letter_picker',
	'choice',
	'command',
	'check'
]);

/** Refuses a declaration the renderers cannot honour. */
function classifyMenuRow(row, where) {
	if (!row || typeof row !== 'object' || Array.isArray(row))
		throw new Error(`${where}: a menu row must be a table`);
	const labelled = typeof row.i18n === 'string' && row.i18n !== '';
	if (row.unavailable !== undefined) {
		if (row.unavailable !== 'hide' && row.unavailable !== 'grey')
			throw new Error(`${where}: unavailable must be "hide" or "grey"`);
		const restricted =
			Array.isArray(row.platforms) &&
			row.platforms.length > 0 &&
			row.platforms.length < PLATFORMS.length &&
			new Set(row.platforms).size === row.platforms.length &&
			Array.from(row.platforms).every((platform) => PLATFORMS.includes(platform));
		if (!restricted)
			throw new Error(`${where}: unavailable needs platforms that leave some platform out`);
		if (!ROW_TYPES.has(row.type))
			throw new Error(`${where}: unavailable needs a known menu row type`);
		if (row.unavailable === 'hide' && row.reason_key !== undefined)
			throw new Error(`${where}: a hidden row carries no reason_key`);
		if (row.unavailable === 'grey') {
			if (typeof row.reason_key !== 'string' || row.reason_key === '')
				throw new Error(`${where}: a greyed row needs its reason_key`);
			if (!labelled) throw new Error(`${where}: a greyed row needs an i18n label`);
		}
		if (
			['command', 'check', 'group'].includes(row.type) &&
			(typeof row.id !== 'string' || row.id === '' || !labelled)
		)
			throw new Error(`${where}: unavailable needs a labelled ${row.type} identity`);
	}
	if (row.disabled_reason_key !== undefined) {
		if (typeof row.disabled_reason_key !== 'string' || row.disabled_reason_key === '')
			throw new Error(`${where}: disabled_reason_key must name a locale key`);
		if (row.type !== 'command')
			throw new Error(`${where}: disabled_reason_key is read on command rows only`);
		if (!Array.isArray(row.disabled_when) || row.disabled_when.length === 0)
			throw new Error(`${where}: disabled_reason_key needs the disabled_when that greys the row`);
		if (!labelled) throw new Error(`${where}: a greyed row needs an i18n label`);
	}
	return row.unavailable === 'hide'
		? 'not-applicable'
		: row.unavailable === 'grey'
			? 'not-ported'
			: 'unclassified';
}

/** Validates actual canonical menu tables without projecting or writing them. */
function validateMenuAvailability(menu) {
	for (const [key, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (!row || typeof row !== 'object') continue;
			const where = `menu.${key} row "${row.id || row.path || row.i18n || row.type}"`;
			classifyMenuRow(row, where);
		}
	}
}

function validateChildTemplates(menu) {
	function inertPresentation(key, rowId, checking = new Set()) {
		const rows = menu[key];
		if (!Array.isArray(rows) || rows.length === 0 || checking.has(key)) return false;
		if (rowId !== undefined && rows.filter((row) => row?.id === rowId).length !== 1) return false;
		checking.add(key);
		for (const row of rows) {
			if (!row || typeof row !== 'object' || Array.isArray(row)) return false;
			let fields;
			if (row.type === 'include') {
				fields = ['type', 'section', 'row_id'];
				if (
					typeof row.section !== 'string' ||
					row.section === '' ||
					(row.row_id !== undefined && (typeof row.row_id !== 'string' || row.row_id === '')) ||
					!inertPresentation(row.section, row.row_id, checking)
				)
					return false;
			} else if (row.type === '---') {
				fields = ['type', 'platforms', 'unavailable'];
				if (row.unavailable !== undefined && row.unavailable !== 'hide') return false;
			} else if (row.type === 'label' || row.type === 'section_header') {
				fields = ['type', 'id', 'i18n', 'platforms', 'unavailable'];
				if (
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					(row.id !== undefined && (typeof row.id !== 'string' || row.id === '')) ||
					(row.type === 'label' && row.id === undefined)
				)
					return false;
				if (row.type === 'section_header') {
					fields.push('reason_key');
					if (row.unavailable !== undefined && !['hide', 'grey'].includes(row.unavailable))
						return false;
					if (row.unavailable === 'grey' && row.reason_key === undefined) return false;
					if (
						row.reason_key !== undefined &&
						(typeof row.reason_key !== 'string' ||
							row.reason_key === '' ||
							row.unavailable === 'hide')
					)
						return false;
				} else if (row.unavailable !== undefined && row.unavailable !== 'hide') return false;
			} else return false;
			if (Object.keys(row).some((field) => !fields.includes(field))) return false;
			if (
				row.platforms !== undefined &&
				(!Array.isArray(row.platforms) ||
					row.platforms.length === 0 ||
					new Set(row.platforms).size !== row.platforms.length ||
					!row.platforms.every((platform) => PLATFORMS.includes(platform)))
			)
				return false;
		}
		checking.delete(key);
		return true;
	}
	for (const [key, rows] of Object.entries(menu)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			const where = `menu.${key} row "${row.id || row.type}"`;
			if (row.on_refusal !== undefined && row.type !== 'include')
				throw new Error(`${where}: on_refusal belongs to an inert presentation include`);
			if (row.type === 'include') {
				if (
					row.on_refusal !== undefined &&
					(row.on_refusal !== 'omit_presentation' || !inertPresentation(row.section, row.row_id))
				)
					throw new Error(`${where}: omission requires an exclusively inert presentation target`);
				if (typeof row.section !== 'string' || !Array.isArray(menu[row.section]))
					throw new Error(`${where}: include needs an existing menu section`);
				if (
					Object.keys(row).some(
						(field) => !['type', 'section', 'row_id', 'present_when', 'on_refusal'].includes(field)
					)
				)
					throw new Error(`${where}: include only composes an existing section`);
				if (
					row.row_id !== undefined &&
					(typeof row.row_id !== 'string' ||
						row.row_id === '' ||
						menu[row.section].filter((item) => item.id === row.row_id).length !== 1)
				)
					throw new Error(`${where}: include row_id needs one exact direct declared identity`);
				if (
					row.present_when !== undefined &&
					(typeof row.present_when !== 'string' || row.present_when === '')
				)
					throw new Error(`${where}: include present_when needs a named boolean getter`);
			}
			if (
				row.type === 'label' &&
				(typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					(row.unavailable !== undefined && row.unavailable !== 'hide') ||
					Object.keys(row).some(
						(field) => !['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(field)
					))
			)
				throw new Error(
					`${where}: inert label needs an identity and caption without behavior metadata`
				);
			if (
				row.type === 'section_header' &&
				((row.id !== undefined && (typeof row.id !== 'string' || row.id === '')) ||
					typeof row.i18n !== 'string' ||
					row.i18n === '' ||
					(row.unavailable !== undefined && !['hide', 'grey'].includes(row.unavailable)) ||
					(row.reason_key !== undefined &&
						(typeof row.reason_key !== 'string' || row.reason_key === '')) ||
					Object.keys(row).some(
						(field) =>
							!['type', 'id', 'i18n', 'platforms', 'unavailable', 'reason_key'].includes(field)
					))
			)
				throw new Error(`${where}: section header needs a caption without behavior metadata`);
			if (
				row.caption_getter !== undefined &&
				(!['command', 'check', 'group'].includes(row.type) ||
					typeof row.caption_getter !== 'string' ||
					row.caption_getter === '' ||
					typeof row.id !== 'string' ||
					row.id === '' ||
					typeof row.i18n !== 'string' ||
					row.i18n === '')
			)
				throw new Error(
					`${where}: caption_getter needs a labelled command, check or group identity`
				);
		}
	}
	const visiting = new Set();
	const visited = new Set();
	function visit(key) {
		if (visiting.has(key)) throw new Error(`menu.${key}: cyclic child-template include`);
		if (visited.has(key)) return;
		visiting.add(key);
		for (const row of menu[key]) if (row.type === 'include') visit(row.section);
		visiting.delete(key);
		visited.add(key);
	}
	for (const [key, rows] of Object.entries(menu)) if (Array.isArray(rows)) visit(key);
}

module.exports = { classifyMenuRow, validateMenuAvailability, validateChildTemplates };
