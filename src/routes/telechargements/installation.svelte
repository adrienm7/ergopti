<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import {
		derniere_version,
		version_mineure_kbdedit,
		version_mineure_ahk,
		version_mineure_kalamine
	} from '$lib/stores_infos.js';
	let version = derniere_version;

	let variante_hypertexte = 'hypertxt';
</script>

<h2>Installation</h2>
<div class="encadre">
	<span style="font-weight:bold">Note :</span> Les fichiers d’installation n’existent au complet qu’à
	partir de la 1.1, c’est pourquoi le sélecteur de version n’a pour le moment aucun impact sur cette
	page mis à part sur l’émulation du clavier.
</div>

<h3>Installer la disposition sur Windows</h3>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/HyperTexte v{version}.{version_mineure_kbdedit}.exe" download
		><button class="bouton-telechargement"
			>☛ HyperTexte v{version}.{version_mineure_kbdedit}.exe</button
		></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/HyperTexte v{version}.{version_mineure_kbdedit}.kbe" download
		><button>Fichier source KbdEdit de HyperTexte v{version}.{version_mineure_kbdedit}</button></a
	>
</div>
<petit-espace />
<div>
	<a href="/pilotes/plus/HyperTextePlus_v{version}.{version_mineure_ahk}.ahk" download
		><button class="bouton-telechargement"
			>☛ HyperTextePlus_v{version}.{version_mineure_ahk}.ahk</button
		></a
	>
</div>
<p>
	Afin que le code source HyperTextePlus.ahk fonctionne, il faut auparavant installer
	<a href="https://www.autohotkey.com/">AutoHotkey v2</a>. Une fois cela fait, il suffit de
	double-cliquer sur le fichier HyperTextePlus.ahk pour l’exécuter avec AutoHotkey.
</p>
<p>
	Ce fichier se modifie avec un éditeur de texte afin que vous puissiez l’adapter selon vos envies,
	notamment pour en désactiver des fonctionnalités ou en ajouter. N’oubliez pas de le relancer pour
	appliquer vos modifications. Le raccourci <kbd>AltGr</kbd> + <kbd>BackSpace</kbd> a été implémenté
	afin de relancer facilement le script après une modification.
</p>
<p>
	Cependant, ce script ne sera actif que lorsque vous l’aurez lancé. Redémarrer l’ordinateur va le
	désactiver, il faudra cliquer à nouveau dessus pour le relancer. Pour automatiser le lancement du
	script HyperTextePlus au démarrage, il est possible de suivre les étapes suivantes :
</p>
<ul>
	<li>
		Presser simultanément la touche Windows et la touche R. Ce raccourci <kbd>Win</kbd> +
		<kbd>R</kbd> permet d'ouvrir la fenêtre « Exécuter » de Windows ;
	</li>
	<li>Saisir <em>shell:startup</em> et valider en cliquant sur le bouton « OK » ;</li>
	<li>
		Le dossier qui vient de s'ouvrir correspond au dossier de démarrage. Tout élément dedans est
		exécuté au démarrage de Windows. Créer un raccourci dans ce dossier pointant vers l'emplacement
		où vous allez sauvegarder votre fichier <em>HyperTextePlus.ahk</em>. Vous pouvez par exemple le
		mettre dans votre dossier Documents.
	</li>
</ul>

<petit-espace />

<h3>Installer la disposition — Avec Kalamine</h3>
<select bind:value={variante_hypertexte} style="height: 2rem">
	<option value="hypertxt">Standard</option>
	<option value="hyper1dk">1DFH</option>
</select>
<p>
	<a href="https://github.com/OneDeadKey/kalamine">Kalamine</a> permet de générer des fichiers
	d’installation pour plusieurs systèmes d’exploitation. Cependant, les fichiers plus bas n’ont pas
	encore été testés. De plus, certaines fonctionnalités vont manquer, comme la modification de la
	touche <kbd>Ctrl</kbd> pour avoir les raccourcis
	<kbd-sortie>Ctrl</kbd-sortie>
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
<p>
	Les instructions d’installation se trouvent ici : <a
		href="https://github.com/OneDeadKey/kalamine?tab=readme-ov-file#using-distributable-layouts"
		>https://github.com/OneDeadKey/kalamine?tab=readme-ov-file#using-distributable-layouts</a
	>
</p>
<mini-espace />
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.toml"
		download><button>{variante_hypertexte}.toml</button></a
	>
</div>
<mini-espace />
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.svg"
		download><button>{variante_hypertexte}.svg</button></a
	>
</div>
<div>
	<h4>Windows</h4>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.ahk"
		download
		><button class="bouton-telechargement">{variante_hypertexte} Kalamine AHK (user)</button></a
	>
</div>
<mini-espace />
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.klc"
		download
		><button class="bouton-telechargement">{variante_hypertexte} Kalamine KLC (admin)</button></a
	>
</div>
<h4>MacOS</h4>
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.keylayout"
		download
		><button class="bouton-telechargement">{variante_hypertexte} Kalamine Keylayout</button></a
	>
</div>
<h4>Linux</h4>
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.xkb_keymap"
		download
		><button class="bouton-telechargement">{variante_hypertexte} Kalamine Xkb_keymap (user)</button
		></a
	>
</div>
<mini-espace />
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_hypertexte}.xkb_symbols"
		download
		><button class="bouton-telechargement">{variante_hypertexte} Kalamine Xkb_symbols (root)</button
		></a
	>
</div>
<petit-espace />
