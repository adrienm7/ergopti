<script>
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
</script>

<svelte:head>
	<title>Téléchargements</title>
	<meta name="description" content="Télécharger HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1>Téléchargements</h1>

	<div class="paragraphe">
		<!-- <div class="btn-group">
			<button><a href="/downloads/HyperTexte.exe">HyperTexte.exe</a></button>
			<button><a href="/downloads/HyperTexte.kbe">HyperTexte.kbe</a></button>
		</div> -->

		<h2>Fichiers</h2>
		<h3>Installation de la disposition</h3>
		<div>
			<a href="/files/KbdEditInstallerhypertexte_v030.exe"><button>HyperTexte.v1.0.3.exe</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/files/HyperTexte v0.30.kbe"><button>Fichier source de HyperTexte.v1.0.3</button></a>
		</div>
		<mini-espace />
		<div>
			<a aria-disabled="true"><button>HyperTextePlus.exe — Pas encore disponible</button></a>
		</div>

		<h3>Pour les comparateurs de disposition</h3>
		<div>
			<a href="/files/hypertexte.v1.0.3.fr.iso.txt"><button>hypertexte.v1.0.3.fr.iso</button></a>
		</div>
		<mini-espace />
		<div>
			<a href="/files/hypertexte.v1.0.3.fr.ergodox.txt"
				><button>hypertexte.v1.0.3.fr.ergodox</button></a
			>
		</div>
	</div>

	<h2>Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <Nom_Plus />
	</p>
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p>

	<h2>S’entraîner virtuellement</h2>
	<div class="paragraphe">[Clavier virtuel ici qui remplace ce qu’on tape en azerty]</div>
</div>
