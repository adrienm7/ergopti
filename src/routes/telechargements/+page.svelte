<script>
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';

	let version = 'v1.0.5';
	// À passer dans de store
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
			<a href="/files/KbdEditInstallerhypertexte_v035.exe"
				><button>HyperTexte {version}.exe</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/files/HyperTexte v0.35.kbe"
				><button>Fichier source de HyperTexte {version}</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a aria-disabled="true"><button>HyperTextePlus.exe — Pas encore disponible</button></a>
		</div>
		<petit-espace />

		<h3>Pour les comparateurs de disposition</h3>
		<mini-espace />
		<div>
			<span>Version ISO : </span><a href="/files/hypertexte.v1.0.5.fr.iso.txt"
				><button>hypertexte.{version}.fr.iso</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version Ergodox : </span><a href="/files/hypertexte.v1.0.5.fr.ergodox.txt"
				><button>hypertexte.{version}.fr.ergodox</button></a
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
