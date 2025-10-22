<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardEmulation from '$lib/keyboard/KeyboardEmulation.svelte';

	import magicSampleToml from './magic_sample.toml?raw';
	let remplacements = {};
	let remplacementsSample = {};

	function parseTomlSimple(toml) {
		const result = {};
		for (const line of toml.split('\n')) {
			const match = line.match(/^"([^"]+)"\s*=\s*\{\s*output\s*=\s*"([^"]+)"/);
			if (match) {
				result[match[1]] = match[2];
			}
		}
		return result;
	}

	remplacementsSample = parseTomlSimple(magicSampleToml);

	if (typeof window !== 'undefined') {
		fetch('/drivers/hotstrings/magic.toml')
			.then((response) => response.text())
			.then((text) => {
				remplacements = parseTomlSimple(text);
			});
	}

	// Variable pour contrôler l'affichage du tableau d’abréviations
	let isCollapsed = true;
	let isSampleCollapsed = true;
</script>

<div class="main">
	<h1 data-aos="zoom-in">Utiliser <Ergopti></Ergopti></h1>
	<hr class="margin-h1" />
</div>

<h2 class="first-h2">Tester la disposition en ligne</h2>
<KeyboardEmulation />
<div class="main">
	<div style="display: flex; gap: 1em; align-items: center;">
		<button onclick={() => (isSampleCollapsed = !isSampleCollapsed)}>
			{isSampleCollapsed
				? 'Afficher une sélection des meilleures abréviations'
				: 'Masquer la sélection des meilleures abréviations'}
		</button>
		<button onclick={() => (isCollapsed = !isCollapsed)}>
			{isCollapsed
				? 'Afficher l’intégralité des abréviations'
				: 'Masquer l’intégralité des abréviations'}
		</button>
	</div>
	{#if !isSampleCollapsed}
		<tiny-space></tiny-space>
		<table>
			<thead>
				<tr>
					<th>Abréviation (extrait)</th>
					<th>Remplacement</th>
				</tr>
			</thead>
			<tbody>
				{#each Object.entries(remplacementsSample) as [key, value]}
					<tr>
						<td>{key}</td>
						<td>{value}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
	{#if !isCollapsed}
		<tiny-space></tiny-space>
		<table>
			<thead>
				<tr>
					<th>Abréviation</th>
					<th>Remplacement</th>
				</tr>
			</thead>
			<tbody>
				{#each Object.entries(remplacements) as [key, value]}
					<tr>
						<td>{key}</td>
						<td>{value}</td>
					</tr>
				{/each}
			</tbody>
		</table>
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
