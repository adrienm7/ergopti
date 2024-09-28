<script>
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<svelte:head>
	<title>Téléchargements</title>
	<meta name="description" content="Télécharger HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Téléchargements</h1>

	<div class="paragraphe">
		<!-- <div class="btn-group">
			<button><a href="/downloads/HyperTexte.exe">HyperTexte.exe</a></button>
			<button><a href="/downloads/HyperTexte.kbe">HyperTexte.kbe</a></button>
		</div> -->

		<h2 data-aos="zoom-out" data-aos-mirror="true">Fichiers</h2>

		<h3>Pour installer la disposition</h3>
		<mini-espace />
		<div>
			<a href="/files/HyperTexte v{versionValue}.exe"
				><button class="bouton-telechargement">☛ HyperTexte {versionValue}.exe</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/files/HyperTexte v{versionValue}.kbe"
				><button>Fichier source de HyperTexte {versionValue}</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a aria-disabled="true"
				><button class="bouton-telechargement">☛ HyperTextePlus.exe — Pas encore disponible</button
				></a
			>
		</div>
		<petit-espace />

		<h3>Pour les comparateurs de disposition</h3>
		<mini-espace />
		<p>
			Pour notamment l’utiliser sur le site <a href="https://klanext.keyboard-design.com/"
				>https://klanext.keyboard-design.com/</a
			> et ses dérivés.
		</p>
		<mini-espace />
		<div>
			<span>Version ISO : </span><a href="/files/hypertexte.v{versionValue}.fr.iso.txt"
				><button>hypertexte.v{versionValue}.fr.iso</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version ISO+ : </span><a href="/files/hypertexte.v{versionValue}.fr.iso+.txt"
				><button>hypertexte.v{versionValue}.fr.iso+</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version Ergodox : </span><a href="/files/hypertexte.v{versionValue}.fr.ergodox.txt"
				><button>hypertexte.v{versionValue}.fr.ergodox</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version pour le site ErgoL : </span><a href="/files/hypertexte.v{versionValue}.json"
				><button>hypertexte.v{versionValue}</button></a
			>
		</div>
	</div>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <NomPlus />
	</p>
	<petit-espace />
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Tester la disposition en ligne</h2>

	<EmulationClavier />
</div>

<style>
	.bouton-telechargement {
		padding: 10px;
		background-color: rgba(0, 0, 0, 0.8);
		color: white;
		border: 1px solid rgba(255, 255, 255, 0.6);
		border-radius: 3px;
	}
</style>
