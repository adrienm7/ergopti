<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';

	import { derniere_version } from '$lib/stores_infos.js';
	import ComparateursDispositions from './comparateurs_dispositions.svelte';
	import Installation from './installation.svelte';
	let version;
	derniere_version.subscribe((value) => {
		version = value;
	});
</script>

<svelte:head>
	<title>Utiliser HyperTexte</title>
	<meta name="description" content="Fichiers pour utiliser HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Utiliser HyperTexte</h1>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Tester la disposition en ligne</h2>
	<EmulationClavier />
	<Installation></Installation>
	<ComparateursDispositions></ComparateursDispositions>

	<!-- <h2 data-aos="zoom-out" data-aos-mirror="true">Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <NomPlus />
	</p>
	<petit-espace />
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p> -->
</div>
