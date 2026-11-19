// tools/test/lib/table-walk-speed.cjs

/**
 * ==============================================================================
 * MODULE: Table Walk Speed Reference
 * DESCRIPTION:
 * Times the layout analysers against a reference run in the same process
 * instead of against a fixed number of milliseconds. A millisecond budget
 * follows the machine: it failed under load and passed a regression on a fast
 * runner. The reference is the least any analyser must do on a prepared
 * n-gram table: read each layout's characters once and visit every bigram and
 * trigram of the table once per layout. The machine slows both alike, so
 * their ratio is the analyser's own cost in table walks.
 *
 * FEATURES & RATIONALE:
 * 1. The reference and the subject alternate on small chunks of the layouts:
 *    a burst of load hits both, never one alone.
 * 2. Each chunk counts its fastest round on each side: one round's time
 *    follows the load and the JIT warming up, the fastest the code's own
 *    work. Short chunks are rarely all preempted, so the sum of their
 *    fastest times varies far less than the fastest of whole runs.
 * 3. At least two rounds run, so neither side is judged on its cold run; the
 *    rounds stop as soon as the ratio is within the bound, as the retries of
 *    the former budgets did.
 * ==============================================================================
 */

'use strict';

// Rounds before a ratio counts: the first round of each side warms the JIT.
const MIN_ROUNDS = 2;

/**
 * The reference walk of a prepared table: the table's tokens get integer ids
 * once, then each run gives every layout's characters a key and visits each
 * bigram and trigram of the table once per layout.
 * @param {{bi: Array, tri: Array}} prepared - prepareNgrams() output.
 * @returns {(layouts: object[]) => number} Runs the walk on library-shape
 *   layouts; the sum it returns keeps the loops from being optimised away.
 */
function tableWalk(prepared) {
	if (!prepared || prepared.prepared !== true)
		throw new Error('table-walk-speed: the reference walks a prepared table');
	const idOf = new Map();
	const id = (token) => {
		if (!idOf.has(token)) idOf.set(token, idOf.size);
		return idOf.get(token);
	};
	const column = (entries, at) => Int32Array.from(entries, (entry) => id(entry[at]));
	const counts = (entries, at) => Float64Array.from(entries, (entry) => entry[at]);
	const biA = column(prepared.bi, 0);
	const biB = column(prepared.bi, 1);
	const biN = counts(prepared.bi, 2);
	const triA = column(prepared.tri, 0);
	const triC = column(prepared.tri, 2);
	const triN = counts(prepared.tri, 3);
	if (biA.length === 0 || triA.length === 0)
		throw new Error('table-walk-speed: the table has no bigram or no trigram to walk');
	const keyOf = new Int32Array(idOf.size);
	return (layouts) => {
		let sum = 0;
		for (const layout of layouts) {
			keyOf.fill(-1);
			let key = 0;
			for (const cells of Object.values(layout.rows)) {
				key++;
				for (const cell of cells) {
					const token = idOf.get(cell);
					if (token !== undefined && keyOf[token] < 0) keyOf[token] = key;
				}
			}
			for (let i = 0; i < biA.length; i++) if (keyOf[biA[i]] === keyOf[biB[i]]) sum += biN[i];
			for (let i = 0; i < triA.length; i++) if (keyOf[triA[i]] === keyOf[triC[i]]) sum += triN[i];
		}
		return sum;
	};
}

/**
 * Times a subject against a reference on the same items, chunk after chunk
 * and round after round, and gives the ratio of their summed fastest chunks.
 * @param {object} spec
 * @param {object[]} spec.items - The layouts both sides run on.
 * @param {number} spec.chunk - Items per timed chunk.
 * @param {(items: object[]) => void} spec.reference - The reference run.
 * @param {(items: object[]) => void} spec.subject - The run under test.
 * @param {number} spec.bound - The ratio that ends the rounds early.
 * @param {number} spec.maxRounds - The rounds at most.
 * @returns {{ratio: number, referenceMs: number, subjectMs: number, rounds: number}}
 *   referenceMs and subjectMs: the sums of the fastest chunks.
 * @throws {Error} When a count is not positive or there are no items.
 */
function relativeSpeed({ items, chunk, reference, subject, bound, maxRounds }) {
	if (!(items.length > 0) || !(chunk >= 1) || !(bound > 0) || !(maxRounds >= MIN_ROUNDS))
		throw new Error(
			`table-walk-speed: ${items.length} items, chunk ${chunk}, bound ${bound}, rounds ${maxRounds}`
		);
	const chunks = [];
	for (let at = 0; at < items.length; at += chunk) chunks.push(items.slice(at, at + chunk));
	const time = (run, part) => {
		const start = process.hrtime.bigint();
		run(part);
		return Number(process.hrtime.bigint() - start) / 1e6;
	};
	const referenceBest = chunks.map(() => Infinity);
	const subjectBest = chunks.map(() => Infinity);
	const sum = (values) => values.reduce((total, value) => total + value, 0);
	let rounds = 0;
	while (rounds < maxRounds) {
		rounds++;
		chunks.forEach((part, i) => {
			referenceBest[i] = Math.min(referenceBest[i], time(reference, part));
			subjectBest[i] = Math.min(subjectBest[i], time(subject, part));
		});
		if (rounds >= MIN_ROUNDS && sum(subjectBest) / sum(referenceBest) <= bound) break;
	}
	const referenceMs = sum(referenceBest);
	const subjectMs = sum(subjectBest);
	return { ratio: subjectMs / referenceMs, referenceMs, subjectMs, rounds };
}

module.exports = { tableWalk, relativeSpeed };
