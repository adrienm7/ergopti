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
	let variante_ergopti;
</script>

<h2>Installation</h2>
<div class="encadre">
	<span style="font-weight:bold">Note :</span> Les fichiers d’installation n’existent au complet qu’à
	partir de la 1.1, c’est pourquoi le sélecteur de version n’a pour le moment aucun impact sur cette
	page mis à part sur l’émulation du clavier.
</div>

<h3 id="kbdedit">Installation KbdEdit (méthode préférée)</h3>
<p>
	<a href="https://www.kbdedit.com/">KbdEdit</a> est un logiciel payant sur Windows, mais très
	complet et permettant de créer des dispositions de clavier. Il est en mesure de créer des pilotes
	pour Windows, et depuis peu pour Mac. Seul Linux n’est pas supporté. Dans le cas de Linux, vous
	pouvez utiliser <a href="#kalamine">la génération par Kalamine</a>.
</p>
<p>
	<strong
		>Si vous êtes sur Windows ou Mac, il est fortement conseillé d’utiliser cette installation
		plutôt que celle de Kalamine</strong
	>. En effet, vous serez alors certain d’avoir toutes les fonctionnalités (touches mortes,
	raccourcis clavier, etc.). La version Kalamine est une version allégée, car Kalamine n’a pas
	encore toutes les fonctionnalités de KbdEdit.
</p>

<h4>Windows</h4>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/Ergopti_v{version}.{version_mineure_kbdedit}.exe" download
		><button class="bouton-telechargement"
			>☛ Ergopti_v{version}.{version_mineure_kbdedit}.exe</button
		></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/Ergopti_v{version}.{version_mineure_kbdedit}.kbe" download
		><button>Fichier source KbdEdit de Ergopti_v{version}.{version_mineure_kbdedit}</button></a
	>
</div>
<petit-espace />
<div>
	<a href="/pilotes/plus/ErgoptiPlus_v{version}.{version_mineure_ahk}.ahk" download
		><button class="bouton-telechargement"
			>☛ ErgoptiPlus_v{version}.{version_mineure_ahk}.ahk</button
		></a
	>
</div>
<p>
	Afin que le code source ErgoptiPlus.ahk fonctionne, il faut auparavant installer
	<a href="https://www.autohotkey.com/">AutoHotkey v2</a>. Une fois cela fait, il suffit de
	double-cliquer sur le fichier ErgoptiPlus.ahk pour l’exécuter avec AutoHotkey.
</p>
<p>
	Ce fichier se modifie avec un éditeur de texte afin que vous puissiez l’adapter selon vos envies,
	notamment pour en désactiver des fonctionnalités ou en ajouter. N’oubliez pas de le relancer pour
	appliquer vos modifications. Le raccourci <kbd>AltGr</kbd> + <kbd>BackSpace</kbd> a été implémenté
	afin de relancer facilement le script après une modification.
</p>
<div class="encadre">
	Il est possible d’utiliser Ergopti sans même installer de pilote. Pour cela, il suffit de passer à
	1 la variable de la ligne 8 du fichier ErgoptiPlus.ahk. Idéalement, il vaut mieux utiliser le vrai
	pilote, notamment pour que le clavier soit Ergopti même sur l’écran de démarrage pour taper son
	mot de passe de session. Toutefois, la version sans pilote peut être utile <strong
		>pour tester Ergopti sans l’installer, ou sur des ordinateurs professionnels où l’on n’a pas les
		droits d’administrateur</strong
	>.
</div>
<p>
	Cependant, ce script ne sera actif que lorsque vous l’aurez lancé. Redémarrer l’ordinateur va le
	désactiver, il faudra cliquer à nouveau dessus pour le relancer. Pour automatiser le lancement du
	script ErgoptiPlus au démarrage, il est possible de suivre les étapes suivantes :
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
		où vous allez sauvegarder votre fichier <em>ErgoptiPlus.ahk</em>. Vous pouvez par exemple le
		mettre dans votre dossier Documents.
	</li>
</ul>
<h4>macOS</h4>
<mini-espace />
<div>
	<a href="/pilotes/kbdedit/Ergopti_v{version}.{version_mineure_kbdedit}.keylayout" download
		><button class="bouton-telechargement"
			>☛ Ergopti_v{version}.{version_mineure_kbdedit}.keylayout</button
		></a
	>
</div>

<petit-espace />

<h3 id="kalamine">Installation Kalamine</h3>
<select bind:value={variante_ergopti} style="height: 2rem">
	<option value="ergopti" selected>Standard</option>
	<option value="ergo_1dk">1DFH</option>
</select>
<p>
	<a href="https://github.com/OneDeadKey/kalamine">Kalamine</a> permet de générer des fichiers
	d’installation pour plusieurs systèmes d’exploitation. Cependant, les fichiers plus bas n’ont pas
	encore été testés. De plus, certaines fonctionnalités vont manquer, comme la modification de la
	couche <kbd>Ctrl</kbd> pour avoir les raccourcis
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>X</kbd-sortie>,
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>C</kbd-sortie>, <kbd-sortie>Ctrl</kbd-sortie> + <kbd-sortie>V</kbd-sortie> et
	<kbd-sortie>Ctrl</kbd-sortie>
	+ <kbd-sortie>Z</kbd-sortie> sur la main gauche.
</p>
<p>
	Si vous êtes sur Windows ou macOS, il est fortement recommandé d’utiliser plutôt <a
		href="#kbdedit">les fichiers générés par KbdEdit</a
	> et non ceux pour Windows générés par Kalamine. Si vous les utilisez quand même, rappelez-vous de
	leurs limites.
</p>
<p>
	Les instructions d’installation se trouvent ici : <a
		href="https://github.com/OneDeadKey/kalamine?tab=readme-ov-file#using-distributable-layouts"
		>https://github.com/OneDeadKey/kalamine?tab=readme-ov-file#using-distributable-layouts</a
	>
</p>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.toml" download
		><button>{variante_ergopti}.toml</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.svg" download
		><button>{variante_ergopti}.svg</button></a
	>
</div>
<div>
	<h4>Windows</h4>
	<a href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.ahk" download
		><button class="bouton-telechargement">{variante_ergopti} Kalamine AHK (user)</button></a
	>
</div>
<mini-espace />
<div>
	<a href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.klc" download
		><button class="bouton-telechargement">{variante_ergopti} Kalamine KLC (admin)</button></a
	>
</div>
<h4>MacOS</h4>
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.keylayout"
		download><button class="bouton-telechargement">{variante_ergopti} Kalamine Keylayout</button></a
	>
</div>
<h4>Linux</h4>
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.xkb_keymap"
		download
		><button class="bouton-telechargement">{variante_ergopti} Kalamine Xkb_keymap (user)</button></a
	>
</div>
<mini-espace />
<div>
	<a
		href="/pilotes/kalamine/{version}.{version_mineure_kalamine}/{variante_ergopti}.xkb_symbols"
		download
		><button class="bouton-telechargement">{variante_ergopti} Kalamine Xkb_symbols (root)</button
		></a
	>
</div>
<petit-espace />
