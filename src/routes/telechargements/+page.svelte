<script>
	import Nom from '$lib/components/Nom.svelte';
	import NomPlus from '$lib/components/NomPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import ComparateursDispositions from './comparateurs_dispositions.svelte';
	import Installation from './installation.svelte';

	import { version } from '$lib/stores_infos.js';

	let versionValue;

	// Fonction pour comparer deux versions
	function compareVersions(versionA, versionB) {
		const aParts = versionA.split('.').map(Number);
		const bParts = versionB.split('.').map(Number);

		for (let i = 0; i < Math.max(aParts.length, bParts.length); i++) {
			const a = aParts[i] || 0;
			const b = bParts[i] || 0;
			if (a > b) return 1;
			if (a < b) return -1;
		}
		return 0;
	}

	// Abonnement à la valeur du store
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<svelte:head>
	<title>Utiliser Ergopti</title>
	<meta name="description" content="Fichiers pour utiliser Ergopti" />
</svelte:head>

<Installation />
{#if versionValue && compareVersions(versionValue, '1.1.0') >= 0}
	<ComparateursDispositions />
{/if}

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
