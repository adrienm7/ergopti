<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';
	import remplacements from '$lib/clavier/remplacementsMagique.json';

	// Variable pour contrôler l'affichage du tableau d’abréviations
	let isCollapsed = true;
</script>

<div class="main">
	<h1 data-aos="zoom-in">Utiliser HyperTexte</h1>

	<h2>Tester la disposition en ligne</h2>
	<EmulationClavier />
	<mini-espace />
	{#if isCollapsed}
		<button on:click={() => (isCollapsed = !isCollapsed)}>
			Afficher les abréviations implémentées
		</button>
	{/if}
	{#if !isCollapsed}
		<button on:click={() => (isCollapsed = !isCollapsed)}>
			Masquer les abréviations implémentées
		</button>
		<mini-espace />
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
</div>

<style>
	table {
		width: 100%;
		border-collapse: collapse;
	}

	th,
	td {
		padding: 8px;
		border: 1px solid #ddd;
		text-align: left;
	}

	th {
		background-color: #f4f4f4;
	}

	thead {
		color: black;
	}
</style>
