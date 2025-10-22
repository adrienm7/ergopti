<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';

	import InstallationWindows from './installation_windows.svelte';
	import InstallationMac from './installation_mac.svelte';
	import InstallationLinux from './installation_linux.svelte';

	import { version } from '$lib/stores_infos.js';

	let versionValue;

	// Abonnement à la valeur du store
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<svelte:head>
	<title>Utiliser Ergopti</title>
	<meta name="description" content="Fichiers pour utiliser Ergopti" />
</svelte:head>

<p>
	<span style="font-weight:bold;">Note :</span> Après toute installation ou réinstallation, il est
	important de <strong>toujours penser à redémarrer son ordinateur</strong>. Cela permet d’être
	certain que la nouvelle version soit prise en compte et évite bien des problèmes.
</p>
<tiny-space></tiny-space>
<div style="display: flex; gap: 1rem; justify-content:center; font-size:1.5rem">
	<a href="#windows">
		<button class="bouton-telechargement"
			><i class="icon-windows" style="vertical-align:0"></i> Windows</button
		>
	</a>
	<a href="#macos">
		<button class="bouton-telechargement"
			><i class="icon-appleinc" style="vertical-align:-0.05em"></i>
			macOS</button
		>
	</a>
	<a href="#linux">
		<button class="bouton-telechargement"><i class="icon-linux"></i> Linux</button>
	</a>
</div>
<div style="height:1rem"></div>
<div style="display: flex; gap: 1rem; justify-content:center;">
	<a href="/documents/printable_layout_v2.2.pdf" download>
		<button class="bouton-telechargement">Layout à imprimer</button>
	</a>
	<a href="/documents/printable_layout_v2.2_full.pdf" download>
		<button class="bouton-telechargement">Layout à imprimer complet</button>
	</a>
</div>
<InstallationWindows />
<InstallationMac />
<InstallationLinux />
