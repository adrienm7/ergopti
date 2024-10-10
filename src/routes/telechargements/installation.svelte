<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { derniere_version } from '$lib/stores_infos.js';
	let version;
	derniere_version.subscribe((value) => {
		version = value;
	});
</script>

<h2>Installation</h2>
<div class="encadre">
	<span style="font-weight:bold">Note :</span> Les fichiers d’installation n’existent au complet qu’à
	partir de la 1.1.2, c’est pourquoi le toggle de version n’a aucun impact sur cette page mis à part
	sur l’émulation du clavier.
</div>

<h3>Installer la disposition sur Windows</h3>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/HyperTexte v{version}.exe" download
		><button class="bouton-telechargement">☛ HyperTexte {version}.exe</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/HyperTexte v{version}.kbe" download
		><button>Fichier source Kbdedit de HyperTexte {version}</button></a
	>
</div>
<mini-espace />
<div>
	<a aria-disabled="true" disabled href="" download
		><button class="bouton-telechargement">☛ HyperTextePlus.exe — Pas encore disponible</button></a
	>
</div>
<petit-espace />

<h3>Installer la disposition — Avec Kalamine</h3>
<p>
	Kalamine permet de générer des fichiers d’installation pour plusieurs systèmes d’exploitation.
	Cependant, les fichiers plus bas n’ont pas encore été testés. De plus, certaines fonctionnalités
	vont manquer, comme la modification de la touche Ctrl pour avoir les raccourcis <kbd-sortie
		>Ctrl</kbd-sortie
	>
	+ <kbd-sortie>X</kbd-sortie>,
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>C</kbd-sortie>, <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> et
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>Z</kbd-sortie> sur la main gauche.
</p>
<p>
	Si vous êtes sur Windows, il est fortement recommandé d’utiliser plutôt les fichiers ci-dessus et
	non ceux pour Windows générés par Kalamine. Si vous n’utilisez pas Windows, vous pouvez les
	utiliser, mais en vous rappelant de leurs limites.
</p>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.toml" download><button>hypertexte.toml</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.svg" download><button>hypertexte.svg</button></a>
</div>
<div>
	<h4>Windows</h4>
	<a href="/pilotes/kalamine/{version}/hypertexte.ahk" download
		><button class="bouton-telechargement">HyperTexte Kalamine AHK (user)</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.klc" download
		><button class="bouton-telechargement">HyperTexte Kalamine KLC (admin)</button></a
	>
</div>
<h4>MacOS</h4>
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.keylayout" download
		><button class="bouton-telechargement">HyperTexte Kalamine Keylayout</button></a
	>
</div>
<h4>Linux</h4>
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.xkb_keymap" download
		><button class="bouton-telechargement">HyperTexte Kalamine Xkb_keymap (user)</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}/hypertexte.xkb_symbols" download
		><button class="bouton-telechargement">HyperTexte Kalamine Xkb_symbols (root)</button></a
	>
</div>
<petit-espace />
