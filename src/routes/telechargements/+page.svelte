<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';
	import remplacements from '$lib/clavier/remplacementsMagique.json';

	import { derniere_version } from '$lib/stores_infos.js';
	import ComparateursDispositions from './comparateurs_dispositions.svelte';
	import Installation from './installation.svelte';
	let version;
	derniere_version.subscribe((value) => {
		version = value;
	});

	// Variable pour contrôler l'affichage du tableau d’abréviations
	let isCollapsed = true;
</script>

<svelte:head>
	<title>Utiliser HyperTexte</title>
	<meta name="description" content="Fichiers pour utiliser HyperTexte" />
</svelte:head>

<h1 data-aos="zoom-in" data-aos-mirror="true">Utiliser HyperTexte</h1>

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

<Installation></Installation>
<ComparateursDispositions></ComparateursDispositions>

<!-- <h2>Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <NomPlus />
	</p>
	<petit-espace />
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p> -->

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
