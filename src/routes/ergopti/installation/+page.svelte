<script>
	import Ergopti from '#lib/components/Ergopti.svelte';
	import ErgoptiPlus from '#lib/components/ErgoptiPlus.svelte';
	import SFB from '#lib/components/SFB.svelte';

	import InstallationWindows from './installation_windows.svelte';
	import InstallationMac from './installation_macos.svelte';
	import InstallationLinux from './installation_linux.svelte';

	import { asset, resolve } from '$app/paths';
	import { discordLink } from '#lib/stores_infos.js';
	import { version } from '#lib/stores_infos.js';
	import PageWrapper from '#lib/components/PageWrapper.svelte';

	let versionValue;

	// Abonnement à la valeur du store
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<svelte:head>
	<title>Installer la Disposition Ergopti</title>
	<meta
		name="description"
		content="Télécharger et installer la Disposition Ergopti sur Windows, macOS et Linux"
	/>
</svelte:head>

<PageWrapper>
	<svelte:fragment slot="introduction">
		<bloc-introduction>
			<h1 data-aos="zoom-in">Installer la Disposition <Ergopti></Ergopti></h1>
			<p class="encart-introduction">
				Téléchargez la Disposition <Ergopti></Ergopti> pour Windows, macOS ou Linux. Pour la tester sans
				rien installer,
				<a href={resolve('/ergopti/utilisation')} class="link">essayez-la en ligne</a>.
			</p>
		</bloc-introduction>
	</svelte:fragment>

	<p>
		<span style="font-weight:bold;">Note :</span> Après toute installation ou réinstallation, il est
		important de <strong>toujours penser à redémarrer son ordinateur</strong>. Cela permet d’être
		certain que la nouvelle version soit prise en compte et évite bien des problèmes.
	</p>
	<p>
		Pour tout problème, vous pouvez être aidé sur le <a
			href={discordLink}
			target="_blank"
			class="text-white"><strong>Serveur Discord</strong> <i class="icon-discord"></i></a
		>.
	</p>
	<tiny-space></tiny-space>
	<div style="display: flex; gap: 1rem; justify-content:center; font-size:1.5rem">
		<a href="#windows">
			<button class="alt-button"
				><i class="icon-windows" style="vertical-align:0"></i> Windows</button
			>
		</a>
		<a href="#macos">
			<button class="alt-button"
				><i class="icon-appleinc" style="vertical-align:-0.05em"></i>
				macOS</button
			>
		</a>
		<a href="#linux">
			<button class="alt-button"><i class="icon-linux"></i> Linux</button>
		</a>
	</div>
	<div style="height:1rem"></div>
	<div style="display: flex; gap: 1rem; justify-content:center;">
		<a href={asset('documents/printable_layout_v2.2.pdf')} download>
			<button>Layout à imprimer</button>
		</a>
		<a href={asset('documents/printable_layout_v2.2_full.pdf')} download>
			<button>Layout à imprimer complet</button>
		</a>
	</div>
	<InstallationWindows />
	<InstallationMac />
	<InstallationLinux />
</PageWrapper>
