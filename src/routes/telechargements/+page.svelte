<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import EmulationClavier from '$lib/clavier/EmulationClavier.svelte';

	import { version } from '$lib/stores_infos.js';
	let versionValue;
	version.subscribe((value) => {
		versionValue = value;
	});
</script>

<svelte:head>
	<title>Utiliser HyperTexte</title>
	<meta name="description" content="Fichiers pour utiliser HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Utiliser HyperTexte</h1>

	<section class="paragraphe">
		<!-- <div class="btn-group">
			<button><a href="/downloads/HyperTexte.exe">HyperTexte.exe</a></button>
			<button><a href="/downloads/HyperTexte.kbe">HyperTexte.kbe</a></button>
		</div> -->
		<h2 data-aos="zoom-out" data-aos-mirror="true">Tester la disposition en ligne</h2>
		<EmulationClavier />

		<h2 data-aos="zoom-out" data-aos-mirror="true">Installation</h2>

		<h3 data-aos="fade-right" data-aos-mirror="true">Installer la disposition sur Windows</h3>
		<mini-espace />
		<div>
			<a href="/pilotes/kbdedit/HyperTexte v{versionValue}.exe" download
				><button class="bouton-telechargement">☛ HyperTexte {versionValue}.exe</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/pilotes/kbdedit/HyperTexte v{versionValue}.kbe" download
				><button>Fichier source de HyperTexte {versionValue}</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a aria-disabled="true" href="" download
				><button class="bouton-telechargement">☛ HyperTextePlus.exe — Pas encore disponible</button
				></a
			>
		</div>
		<petit-espace />

		<h3 data-aos="fade-right" data-aos-mirror="true">Installer la disposition — Avec Kalamine</h3>
		<p>
			Kalamine permet de générer des fichiers d’installation pour plusieurs systèmes d’exploitation.
			Cependant, les fichiers plus bas n’ont pas encore été testés. De plus, certaines
			fonctionnalités vont manquer, comme la modification de la touche Ctrl pour avoir les
			raccourcis <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>X</kbd-sortie>,
			<kbd-sortie>Ctrl</kbd-sortie>
			+ <kbd-sortie>C</kbd-sortie>, <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> et
			<kbd-sortie>Ctrl</kbd-sortie>
			+ <kbd-sortie>Z</kbd-sortie> sur la main gauche.
		</p>
		<p>
			Si vous êtes sur Windows, il est fortement recommandé d’utiliser plutôt les fichiers ci-dessus
			et non ceux pour Windows générés par Kalamine. Si vous n’utilisez pas Windows, vous pouvez les
			utiliser, mais en vous rappelant de leurs limites.
		</p>
		<mini-espace />
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.toml" download
				><button>hypertexte.toml</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.svg" download
				><button>hypertexte.svg</button></a
			>
		</div>
		<div>
			<h4>Windows</h4>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.ahk" download
				><button class="bouton-telechargement">HyperTexte Kalamine AHK (user)</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.klc" download
				><button class="bouton-telechargement">HyperTexte Kalamine KLC (admin)</button></a
			>
		</div>
		<h4>MacOS</h4>
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.keylayout" download
				><button class="bouton-telechargement">HyperTexte Kalamine Keylayout</button></a
			>
		</div>
		<h4>Linux</h4>
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.xkb_keymap" download
				><button class="bouton-telechargement">HyperTexte Kalamine Xkb_keymap (user)</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/pilotes/kalamine/{versionValue}/hypertexte.xkb_symbols" download
				><button class="bouton-telechargement">HyperTexte Kalamine Xkb_symbols (root)</button></a
			>
		</div>
		<petit-espace />

		<h2 data-aos="zoom-out" data-aos-mirror="true">
			Fichiers pour les comparateurs de disposition
		</h2>
		<mini-espace />
		<p>
			Pour notamment l’utiliser sur le site <a href="https://klanext.keyboard-design.com/"
				>https://klanext.keyboard-design.com/</a
			> et ses dérivés.
		</p>
		<mini-espace />
		<div>
			<span>Version ISO : </span><a
				href="/dispositions/iso/hypertexte/hypertexte.v{versionValue}.fr.iso.json"
				download><button>hypertexte.v{versionValue}.fr.iso</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version ISO+ : </span><a
				href="/dispositions/iso/hypertexte.v{versionValue}.fr.iso+.json"
				download><button>hypertexte.v{versionValue}.fr.iso+</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version Ergodox : </span><a
				href="/dispositions/ergodox/hypertexte.v{versionValue}.fr.ergodox.json"
				download><button>hypertexte.v{versionValue}.fr.ergodox</button></a
			>
		</div>
		<petit-espace />
		<div>
			<span>Analyseur Ergo-L — Version à utiliser sur le site : </span><a
				href="/pilotes/kalamine/{versionValue}/hypertexte_K.json"
				download><button>hypertexte_K.json</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Analyseur Ergo-L — Version théorique : </span><a
				href="/pilotes/kalamine/{versionValue}/hypertexte.json"
				download><button>hypertexte.json</button></a
			>
			<p>
				Sur l’analyseur Ergo-L, les touches assignées à chaque doigt diffèrent. La touche <kbd
					>À</kbd
				>
				par exemple est assignée à l’annulaire et non au majeur. Cela entraîne un <SFB />, car la
				touche
				<kbd>J</kbd>
				se retrouve sur le même doigt que la touche <kbd>E</kbd>. Le <kbd>J</kbd> doit normalement
				être sous le <kbd>U</kbd>. D’où la nécessité de la version K, qui corrige ce problème.
			</p>
		</div>
	</section>

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

<style>
	.bouton-telechargement {
		padding: 10px;
		background-color: rgba(0, 0, 0, 0.8);
		color: white;
		border: 1px solid rgba(255, 255, 255, 0.6);
		border-radius: 3px;
	}
</style>
