<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import KeyboardEmulation from '$lib/keyboard/KeyboardEmulation.svelte';
	import remplacements from '$lib/keyboard/data/magicReplacements.json';

	// Variable pour contrôler l'affichage du tableau d’abréviations
	let isCollapsed = true;
</script>

<section class="main">
	<h1 data-aos="zoom-in">Utiliser <Ergopti></Ergopti></h1>
	<hr class="margin-h1" />

	<h2>Tester la disposition en ligne</h2>
	<KeyboardEmulation />
	<tiny-space></tiny-space>
	{#if isCollapsed}
		<button on:click={() => (isCollapsed = !isCollapsed)}>
			Afficher les abréviations implémentées sur cette démo
		</button>
	{/if}
	{#if !isCollapsed}
		<button on:click={() => (isCollapsed = !isCollapsed)}>
			Masquer les abréviations implémentées sur cette démo
		</button>
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
						<td>{key}★</td>
						<td>{value}</td>
					</tr>
				{/each}
			</tbody>
		</table>
	{/if}
</section>

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
