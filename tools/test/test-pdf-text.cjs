// tools/test/test-pdf-text.cjs

/**
 * ==============================================================================
 * MODULE: PDF Text Reader Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/pdf_text.js reads a PDF's text in the page so the
 * Comparer can analyse a layout on it. This gate holds it to the real PDFs
 * the repository already ships: two browser prints and a Google Docs export.
 *
 * WHAT IS CHECKED:
 * 1. Chrome's Skia (Layout_Optim7.pdf), Firefox's cairo with the page in a
 *    Form XObject (Keyboard Layout Analyzers.pdf) and Google Docs (one glyph
 *    run per word): words whole, separated by single spaces, lines kept,
 *    accents read, ligatures read as letters.
 * 2. Refusals: a file that is not a PDF (file_unreadable), a locked PDF
 *    (pdf_encrypted) and one without text (pdf_no_text); a simple font
 *    without a character map reads its bytes.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const context = vm.createContext({ Blob, Response, DecompressionStream });
vm.runInContext(
	`${fs.readFileSync(shared('ui', 'layout_analysis', 'pdf_text.js'), 'utf8')}\nthis.PDF = LAYOUT_ANALYSIS_PDF;`,
	context
);
const PDF = context.PDF;
const DOCUMENTS = path.join(REPO_ROOT, 'static', 'documents');

/** The text the reader gives for a file's bytes. */
const read = (bytes) =>
	PDF.read(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.length));
/** The code a read is refused with. */
const refusal = (bytes) =>
	read(bytes).then(
		() => null,
		(error) => error.code
	);

(async () => {
	// 1/ Browser prints and a Google Docs export.
	const skia = await read(fs.readFileSync(path.join(DOCUMENTS, 'archives', 'Layout_Optim7.pdf')));
	for (const line of [
		'Layout Optim7',
		'Exposants en AltGr E, Indices en AltGr I, Tréma en AltGr T.',
		'pour rien au monde je ne voudrais du M et du V dans ces positions. Si je'
	])
		assert.ok(skia.split('\n').includes(line), `Skia: the line « ${line} »`);
	const cairo = await read(
		fs.readFileSync(path.join(REPO_ROOT, 'static', 'benchmarks', 'Keyboard Layout Analyzers.pdf'))
	);
	assert.ok(
		cairo.includes('AdNW Andreas Wettstein 2009 AdNW Command line'),
		'cairo: the text inside its Form XObject'
	);
	const docs = await read(
		fs.readFileSync(path.join(DOCUMENTS, 'documentation', 'Keyboard layouts doc (2nd edition).pdf'))
	);
	assert.ok(
		docs.startsWith(
			'To share this document you can use this shorter link: https://bit.ly/layout-doc-v2'
		),
		`Google Docs: words whole and spaced, got « ${docs.slice(0, 80)} »`
	);
	assert.ok(
		docs.includes('To access this document offline, click on File'),
		'Google Docs: ligatures as letters'
	);
	assert.ok(!/[ﬀ-ﬆ]/.test(docs), 'no ligature character left');

	// 2/ Refusals, and a simple font without a character map.
	assert.equal(await refusal(Buffer.from('hello')), 'file_unreadable');
	const minimal = (extra, content) =>
		Buffer.from(
			[
				'%PDF-1.4',
				'1 0 obj << /Type /Pages /Kids [2 0 R] /Count 1 >> endobj',
				'2 0 obj << /Type /Page /Parent 1 0 R /Contents 3 0 R >> endobj',
				`3 0 obj << /Length ${content.length} >>`,
				'stream',
				content,
				'endstream',
				'endobj',
				// The reader finds the page tree by its type, not through the trailer.
				`trailer << ${extra} >>`,
				'%%EOF'
			].join('\n'),
			'latin1'
		);
	assert.equal(await refusal(minimal('/Encrypt 5 0 R', 'BT (secret) Tj ET')), 'pdf_encrypted');
	assert.equal(await refusal(minimal('', '0 0 10 10 re f')), 'pdf_no_text');
	assert.equal(
		await read(minimal('', 'BT (plain caf\\351) Tj ET')),
		'plain café',
		'a simple font reads its bytes as Windows-1252'
	);

	console.log('[OK] PDF text: Skia, cairo and Google Docs exports read, three refusals');
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
