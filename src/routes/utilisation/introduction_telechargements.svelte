<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardEmulation from '$lib/keyboard/KeyboardEmulation.svelte';
	import { base } from '$app/paths';

	import magicSampleToml from './magic_sample.toml?raw';
	let remplacements = {};
	let remplacementsSample = {};

	function parseTomlSimple(toml) {
		const result = {};
		for (const line of toml.split('\n')) {
			const match = line.match(/^"([^"]+)"\s*=\s*\{\s*output\s*=\s*"([^"]+)"/);
			if (match) {
				const k = unescapeTomlString(match[1].trim());
				const v = unescapeTomlString(match[2]);
				result[k] = v;
			}
		}
		return result;
	}

	function unescapeTomlString(s) {
		if (!s) return '';
		// replace common TOML/JS escapes
		return s
			.replace(/\\r/g, '\r')
			.replace(/\\n/g, '\n')
			.replace(/\\t/g, '\t')
			.replace(/\\'/g, "'")
			.replace(/\\"/g, '"')
			.replace(/\\\\/g, '\\')
			.replace(/\r|\n/g, ' ')
			.trim();
	}

	remplacementsSample = parseTomlSimple(magicSampleToml);

	if (typeof window !== 'undefined') {
		fetch(base + '/drivers/hotstrings/magic.toml')
			.then((response) => response.text())
			.then((text) => {
				remplacements = parseTomlSimple(text);
			});
	}

	// TOML sections viewer for magickey.toml
	import { onMount } from 'svelte';
	let tomlSections = [];
	let tomlMeta = { sections_order: [], sections: {} };
	let orderedSections = [];
	let selectedSection = '';
	let sectionEntries = [];
	let searchQuery = '';
	let sortKey = 'key';
	let sortDir = 1; // 1 asc, -1 desc

	$: displayedEntries = (() => {
		if (!sectionEntries) return [];
		const q = (searchQuery || '').toLowerCase();
		const filtered = sectionEntries.filter((e) => {
			return (e.key || '').toLowerCase().includes(q) || (e.output || '').toLowerCase().includes(q);
		});
		const sorted = filtered.slice().sort((a, b) => {
			const A = sortKey === 'key' ? a.key || '' : a.output || '';
			const B = sortKey === 'key' ? b.key || '' : b.output || '';
			// Use localeCompare with French locale and base sensitivity to ignore accents
			return A.localeCompare(B, 'fr', { sensitivity: 'base', ignorePunctuation: true }) * sortDir;
		});
		return sorted;
	})();

	$: otherMatches = (() => {
		const q = (searchQuery || '').toLowerCase().trim();
		if (!q) return [];
		const others = [];
		for (const s of orderedSections) {
			if (s.name === selectedSection) continue;
			const matches = (s.entries || [])
				.filter((e) => {
					return (
						(e.key || '').toLowerCase().includes(q) || (e.output || '').toLowerCase().includes(q)
					);
				})
				.slice()
				.sort((a, b) => {
					const A = sortKey === 'key' ? a.key || '' : a.output || '';
					const B = sortKey === 'key' ? b.key || '' : b.output || '';
					return (
						A.localeCompare(B, 'fr', { sensitivity: 'base', ignorePunctuation: true }) * sortDir
					);
				});
			if (matches.length) others.push({ name: s.name, title: s.title, entries: matches });
		}
		return others;
	})();

	function sortBy(k) {
		if (sortKey === k) sortDir = -sortDir;
		else {
			sortKey = k;
			sortDir = 1;
		}
	}

	onMount(async () => {
		try {
			const res = await fetch(base + '/drivers/hotstrings/magickey.toml');
			const text = await res.text();
			const parsed = parseTomlSections(text);
			tomlSections = parsed.sections;
			tomlMeta = parsed.meta;
			// build orderedSections using meta.sections_order (skip "-")
			orderedSections = [];
			const byName = new Map(tomlSections.map((s) => [s.name, s]));
			for (const name of tomlMeta.sections_order || []) {
				if (name === '-') continue;
				const s = byName.get(name);
				if (s)
					orderedSections.push({
						name: s.name,
						title: (tomlMeta.sections && tomlMeta.sections[name]) || s.name,
						entries: s.entries
					});
			}
			// append any sections not listed in order
			for (const s of tomlSections) {
				if (!orderedSections.find((o) => o.name === s.name))
					orderedSections.push({
						name: s.name,
						title: (tomlMeta.sections && tomlMeta.sections[s.name]) || s.name,
						entries: s.entries
					});
			}

			// prepend sample selection as first option
			const sampleEntries = Object.entries(remplacementsSample || {}).map(([k, v]) => ({
				key: k,
				output: v
			}));
			orderedSections.unshift({
				name: '__sample',
				title: 'Sélection des meilleures abréviations',
				entries: sampleEntries
			});

			if (orderedSections.length) {
				selectedSection = orderedSections[0].name;
				sectionEntries = orderedSections[0].entries;
			}
		} catch (e) {
			console.error('Erreur lecture magickey.toml', e);
		}
	});

	function parseTomlSections(text) {
		const sections = [];
		const headerRegex = /^(\[\[([^\]]+)\]\]|\[([^\]]+)\])/gm;
		const indices = [];
		let match;
		while ((match = headerRegex.exec(text)) !== null) {
			indices.push({ index: match.index, raw: match[0], name: (match[2] || match[3]).trim() });
		}
		if (indices.length === 0) return { sections: [], meta: { sections_order: [], sections: {} } };
		for (let i = 0; i < indices.length; i++) {
			const name = indices[i].name;
			const start = indices[i].index + indices[i].raw.length;
			const end = i + 1 < indices.length ? indices[i + 1].index : text.length;
			const content = text.slice(start, end).trim();
			const entries = [];

			const entryRegex = /^\s*["']([^"']+)["']\s*=\s*\{([^}]*)\}/gm;
			let m;
			while ((m = entryRegex.exec(content)) !== null) {
				let key = m[1] || '';
				const obj = m[2] || '';
				const outMatch = /output\s*=\s*"([^\"]*)"/.exec(obj);
				let output = outMatch ? outMatch[1] : '';
				key = unescapeTomlString(key);
				output = unescapeTomlString(output);
				entries.push({ key, output, raw: m[0].trim() });
			}

			const simpleRegex = /^\s*([A-Za-z0-9_\.\-]+)\s*=\s*(.+)$/gm;
			let s;
			while ((s = simpleRegex.exec(content)) !== null) {
				let k = s[1] || '';
				let v = s[2].trim() || '';
				k = unescapeTomlString(k);
				if (!entries.some((e) => e.key === k)) {
					let cleaned = v.replace(/^\s*"|"\s*$/g, '').replace(/^\s*\[|\]\s*$/g, '');
					cleaned = unescapeTomlString(cleaned);
					entries.push({ key: k, output: cleaned, raw: v });
				}
			}

			sections.push({ name, entries });
		}

		// extract meta (_meta and _meta.sections)
		const meta = { sections_order: [], sections: {} };
		const normal = [];
		for (const s of sections) {
			if (s.name === '_meta') {
				// parse lines like sections_order = ["replace", "repeat", "-"]
				for (const e of s.entries) {
					const line = e.raw;
					const m = line.match(/^sections_order\s*=\s*\[(.*)\]$/);
					if (m) {
						const items = m[1]
							.split(',')
							.map((x) => x.trim().replace(/^"|"$/g, ''))
							.filter(Boolean);
						meta.sections_order = items;
					}
				}
			} else if (s.name === '_meta.sections') {
				for (const e of s.entries) {
					meta.sections[e.key] = e.output;
				}
			} else {
				normal.push(s);
			}
		}

		// merge same-name normal sections
		const map = new Map();
		for (const s of normal) {
			if (!map.has(s.name)) map.set(s.name, { name: s.name, entries: [...s.entries] });
			else map.get(s.name).entries.push(...s.entries);
		}
		const merged = Array.from(map.values());

		return { sections: merged, meta };
	}

	function selectSection(name) {
		selectedSection = name;
		const sec =
			orderedSections.find((s) => s.name === name) || tomlSections.find((s) => s.name === name);
		sectionEntries = sec ? sec.entries : [];
	}

	// Variable pour contrôler l'affichage du tableau d’abréviations
	let isCollapsed = true;
	let isSampleCollapsed = true;
</script>

<div class="main">
	<h1 data-aos="zoom-in">Utiliser <Ergopti></Ergopti></h1>
	<hr class="margin-h1" />
</div>

<div style="overflow-x: hidden;">
	<h2 class="first-h2">Essayer la disposition en ligne</h2>
</div>
<KeyboardEmulation />

<div class="main">
	<!-- Viewer for magickey.toml sections -->
	{#if orderedSections.length}
		<section style="margin-top:1rem;">
			<h3>Remplacements de texte <ErgoptiPlus></ErgoptiPlus></h3>
			<div
				style="display:flex; gap:0.5rem; align-items:center; flex-wrap:wrap; margin-top:0.25rem;"
			>
				<select
					bind:value={selectedSection}
					onchange={() => selectSection(selectedSection)}
					style="min-width:220px;"
				>
					{#each orderedSections as s}
						<option value={s.name}>{s.title}</option>
					{/each}
				</select>
				<input
					placeholder="Rechercher..."
					bind:value={searchQuery}
					style="flex:1; min-width:160px; padding:0.35rem; color:#000; background: rgba(255,255,255,0.8); border:1px solid #ccc; border-radius:3px;"
				/>
			</div>
			{#if displayedEntries.length}
				<div style="max-height:20rem; overflow:auto; margin-top:0.5rem;">
					<table style="width:100%; border-collapse:collapse; table-layout:fixed;">
						<thead>
							<tr>
								<th
									style="text-align:center; padding:8px; border-bottom:1px solid #ddd; cursor:pointer;"
									onclick={() => sortBy('key')}
									>Abréviation {sortKey === 'key' ? (sortDir === 1 ? '▲' : '▼') : ''}</th
								>
								<th
									style="text-align:center; padding:8px; border-bottom:1px solid #ddd; cursor:pointer;"
									onclick={() => sortBy('output')}
									>Remplacement {sortKey === 'output' ? (sortDir === 1 ? '▲' : '▼') : ''}</th
								>
							</tr>
						</thead>
						<tbody>
							{#each displayedEntries as e}
								<tr>
									<td style="padding:6px; border-bottom:1px solid #eee; word-break:break-word;"
										>{e.key}</td
									>
									<td style="padding:6px; border-bottom:1px solid #eee; word-break:break-word;"
										>{e.output}</td
									>
								</tr>
							{/each}
						</tbody>
					</table>
				</div>
			{:else}
				<p style="margin-top:0.5rem;">Aucun élément correspondant.</p>
			{/if}

			{#if otherMatches.length}
				<div style="margin-top:1rem;">
					{#each otherMatches as m}
						<div style="margin-top:0.6rem;">
							<h4 style="margin:0 0 0.25rem 0; font-size:0.95rem;">
								Dans {m.title} <span style="color:#666; font-size:0.9rem;">(autre section)</span>
							</h4>
							<table
								style="width:100%; border-collapse:collapse; table-layout:fixed; font-size:0.95rem;"
							>
								<thead>
									<tr>
										<th style="text-align:center; padding:6px; border-bottom:1px solid #ddd;"
											>Abréviation</th
										>
										<th style="text-align:center; padding:6px; border-bottom:1px solid #ddd;"
											>Remplacement</th
										>
									</tr>
								</thead>
								<tbody>
									{#each m.entries as e}
										<tr>
											<td style="padding:6px; border-bottom:1px solid #eee;">{e.key}</td>
											<td style="padding:6px; border-bottom:1px solid #eee;">{e.output}</td>
										</tr>
									{/each}
								</tbody>
							</table>
						</div>
					{/each}
				</div>
			{/if}
		</section>
	{:else}
		<p style="margin-top:1rem;">Chargement de magickey.toml…</p>
	{/if}
</div>

<style>
	table {
		border-collapse: collapse;
		width: 100%;
	}

	th,
	td {
		border: 1px solid #ddd;
		padding: 8px;
		text-align: left;
	}

	th {
		background-color: #f4f4f4;
	}

	thead {
		color: black;
	}
</style>
