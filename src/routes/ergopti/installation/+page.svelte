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
		<b style="font-weight:bold;">Note :</b> Après toute installation ou réinstallation, il est
		important de <strong>toujours penser à redémarrer son ordinateur</strong>. Cela permet d’être
		certain que la nouvelle version soit prise en compte et évite bien des problèmes.
	</p>
	<p>
		Pour tout problème, vous pouvez être aidé sur le <a
			href={discordLink}
			target="_blank"
			class="text-white"
			><strong>Serveur Discord</strong> <i class="icon-discord" aria-hidden="true"></i></a
		>.
	</p>
	<tiny-space></tiny-space>
	<nav
		style="display: flex; gap: 1rem; justify-content:center; font-size:1.5rem"
		aria-label="Installation par système"
	>
		<!-- Links styled as buttons: a button inside a link is two focus stops
		     for one action (WCAG 4.1.2). -->
		<a href="#windows" class="alt-button anchor-button"
			><i class="icon-windows" style="vertical-align:0" aria-hidden="true"></i> Windows</a
		>
		<a href="#macos" class="alt-button anchor-button"
			><i class="icon-appleinc" style="vertical-align:-0.05em" aria-hidden="true"></i> macOS</a
		>
		<a href="#linux" class="alt-button anchor-button"
			><i class="icon-linux" aria-hidden="true"></i> Linux</a
		>
	</nav>
	<div style="height:1rem"></div>
	<div style="display: flex; gap: 1rem; justify-content:center;">
		<a class="button-link" href={asset('documents/printable_layout_v2.2.pdf')} download>
			Layout à imprimer
		</a>
		<a class="button-link" href={asset('documents/printable_layout_v2.2_full.pdf')} download>
			Layout à imprimer complet
		</a>
	</div>
	<InstallationWindows />
	<InstallationMac />
	<InstallationLinux />
</PageWrapper>

<style>
	.anchor-button {
		display: inline-block;
		text-decoration: none;
	}
</style>
