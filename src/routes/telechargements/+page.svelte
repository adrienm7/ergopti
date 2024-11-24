<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import ComparateursDispositions from './comparateurs_dispositions.svelte';
	import Installation from './installation.svelte';
</script>

<svelte:head>
	<title>Utiliser Ergopti</title>
	<meta name="description" content="Fichiers pour utiliser Ergopti" />
</svelte:head>

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
