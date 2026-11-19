// tools/test/test-site-video-captions.cjs

/**
 * ==============================================================================
 * MODULE: Site Video Captions Gate
 * DESCRIPTION:
 * A video on the site carries captions and a transcript (WCAG 1.2.1, 1.2.2,
 * 1.2.3; TODO « Full accessibility », « Images and media »). A silent demo
 * still needs a transcript that says what is typed and shown; WCAG accepts a
 * descriptive one.
 *
 * WHAT IS CHECKED, in the markup of every Svelte file under src/ and in
 * src/app.html:
 * 1. Each <video> holds a <track kind="captions" srclang="…" default> whose
 *    src is a static file (asset('…') or a literal path) that exists under
 *    static/ and starts with the WEBVTT signature.
 * 2. Each <video> and each embedded player (an <iframe> of a video host) is
 *    tied to a transcript: aria-describedby naming an id of the same file,
 *    or a link in the same file marked data-transcript-for with its id.
 * 3. The checker itself refuses a video without a track, with a missing
 *    captions file or without a transcript, and accepts a complete one.
 *
 * The site had no video on 2026-11-19 (its demos are animated text in the
 * page, their words in the DOM): the gate guards the next one.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SRC = path.join(ROOT, 'src');
const STATIC = path.join(ROOT, 'static');
// Hosts whose <iframe> is a video player.
const VIDEO_HOSTS = /(youtube(-nocookie)?\.com|youtu\.be|vimeo\.com|dailymotion\.com|peertube)/i;

/** Every Svelte file under src/, and the page shell. */
function sourceFiles() {
	const files = [path.join(SRC, 'app.html')];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.svelte')) files.push(full);
		}
	};
	walk(SRC);
	return files;
}

/** The value of one attribute in a start tag, quoted or as a {…} expression. */
function attribute(tag, name) {
	const match = new RegExp(
		'\\s' + name + '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\'|\\{([^}]*)\\})',
		'i'
	).exec(tag);
	if (!match) return null;
	return match[1] ?? match[2] ?? match[3];
}

/**
 * The static file a track's src names: asset('path'), resolve-free, or a
 * literal path from the site root.
 * @returns {string|null} The path under static/, or null when it cannot be read statically.
 */
function staticPathOf(src) {
	if (src === null) return null;
	const asset = /^\s*asset\(\s*['"`]([^'"`]+)['"`]\s*\)\s*$/.exec(src);
	if (asset) return asset[1];
	if (/^\/[^{}]+$/.test(src)) return src.slice(1);
	return null;
}

/**
 * The problems of one source file's videos and players.
 * @param {string} source - The file's text.
 * @param {function(string): (string|null)} readStatic - The text of a file under static/, or null.
 * @returns {{videos: number, problems: string[]}}
 */
function checkSource(source, readStatic) {
	const problems = [];
	const markup = source.replace(
		/<script[\s\S]*?<\/script>|<style[\s\S]*?<\/style>|<!--[\s\S]*?-->/g,
		''
	);
	const ids = new Set(Array.from(markup.matchAll(/\sid\s*=\s*["']([^"']+)["']/g), (m) => m[1]));
	const transcriptLinks = new Set(
		Array.from(markup.matchAll(/\sdata-transcript-for\s*=\s*["']([^"']+)["']/g), (m) => m[1])
	);
	const hasTranscript = (tag) => {
		const described = attribute(tag, 'aria-describedby');
		if (described && described.split(/\s+/).every((id) => ids.has(id))) return true;
		const id = attribute(tag, 'id');
		return Boolean(id && transcriptLinks.has(id));
	};
	let videos = 0;
	for (const match of markup.matchAll(/<video\b([^>]*)>([\s\S]*?)<\/video>/gi)) {
		videos++;
		const tag = '<video' + match[1] + '>';
		const name = attribute(tag, 'id') || attribute(tag, 'src') || 'video #' + videos;
		const captions = Array.from(match[2].matchAll(/<track\b[^>]*>/gi), (m) => m[0]).filter(
			(track) => (attribute(track, 'kind') || '').toLowerCase() === 'captions'
		);
		if (!captions.length) problems.push(name + ': no <track kind="captions">');
		for (const track of captions) {
			if (!attribute(track, 'srclang')) problems.push(name + ': captions track without srclang');
			if (!/\sdefault(\s|=|\/?>)/i.test(track))
				problems.push(name + ': captions track not default');
			const file = staticPathOf(attribute(track, 'src'));
			if (file === null) {
				problems.push(name + ': captions src is not a static path');
				continue;
			}
			const text = readStatic(file);
			if (text === null) problems.push(name + ': captions file missing, static/' + file);
			else if (!/^\uFEFF?WEBVTT/.test(text))
				problems.push(name + ': captions file is not WebVTT, static/' + file);
		}
		if (!hasTranscript(tag))
			problems.push(name + ': no transcript (aria-describedby or data-transcript-for)');
	}
	for (const match of markup.matchAll(/<iframe\b[^>]*>/gi)) {
		const src = attribute(match[0], 'src') || '';
		if (!VIDEO_HOSTS.test(src)) continue;
		videos++;
		if (!hasTranscript(match[0])) problems.push(src + ': embedded player without a transcript');
	}
	return { videos, problems };
}

/** The checker refuses each missing part and accepts a complete video. */
function checkSelf() {
	const files = { 'media/demo.vtt': 'WEBVTT\n\n00:00.000 --> 00:02.000\nOn tape « sx ».\n' };
	const readStatic = (file) => (file in files ? files[file] : null);
	const complete = [
		'<video id="demo" src="/media/demo.mp4" aria-describedby="demo-transcript" controls>',
		'<track kind="captions" srclang="fr" label="Français" src={asset(\'media/demo.vtt\')} default />',
		'</video>',
		'<div id="demo-transcript">On tape « sx », qui devient « sk ».</div>'
	].join('\n');
	assert.deepEqual(checkSource(complete, readStatic), { videos: 1, problems: [] });
	const cases = {
		'no <track kind="captions">': complete.replace(/<track[^>]*>/, ''),
		'captions file missing': complete.replace('media/demo.vtt', 'media/absent.vtt'),
		'not default': complete.replace(' default', ''),
		'no transcript': complete.replace(' aria-describedby="demo-transcript"', ''),
		'embedded player without a transcript':
			'<iframe src="https://www.youtube.com/embed/x"></iframe>'
	};
	for (const [problem, source] of Object.entries(cases)) {
		const result = checkSource(source, readStatic);
		assert.ok(
			result.problems.some((line) => line.includes(problem)),
			'The checker reports « ' + problem + ' », got ' + JSON.stringify(result.problems)
		);
	}
	const linked = complete
		.replace(' aria-describedby="demo-transcript"', '')
		.replace(
			'<div id="demo-transcript">',
			'<a data-transcript-for="demo" href="/t">Transcription</a><div>'
		);
	assert.deepEqual(checkSource(linked, readStatic).problems, [], 'A transcript link is enough');
}

function main() {
	checkSelf();
	const readStatic = (file) => {
		const full = path.join(STATIC, file);
		return fs.existsSync(full) ? fs.readFileSync(full, 'utf8') : null;
	};
	let videos = 0;
	const problems = [];
	for (const file of sourceFiles()) {
		const result = checkSource(fs.readFileSync(file, 'utf8'), readStatic);
		videos += result.videos;
		for (const problem of result.problems)
			problems.push(path.relative(ROOT, file).split(path.sep).join('/') + ': ' + problem);
	}
	assert.deepEqual(problems, [], 'Every site video has captions and a transcript');
	console.log('test-site-video-captions: OK (' + videos + ' video(s) and player(s) on the site)');
}

module.exports = { checkSource, staticPathOf };
if (require.main === module) main();
