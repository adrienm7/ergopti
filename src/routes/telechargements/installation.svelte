<script>
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';

	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
	let versionValue,
		version_mineure_kbdedit_exe,
		version_mineure_kbdedit_kbe,
		version_mineure_kbdedit_mac,
		version_mineure_ahk,
		version_mineure_plus,
		version_mineure_kalamine_1dk,
		version_mineure_kalamine_standard;
	version.subscribe((value) => {
		versionValue = value;
		version_mineure_kbdedit_exe = getLatestVersion('kbdedit_exe', versionValue);
		version_mineure_kbdedit_kbe = getLatestVersion('kbdedit_kbe', versionValue);
		version_mineure_kbdedit_mac = getLatestVersion('kbdedit_mac', versionValue);
		version_mineure_ahk = getLatestVersion('ahk', versionValue);
		version_mineure_plus = getLatestVersion('plus', versionValue);
		version_mineure_kalamine_1dk = getLatestVersion('kalamine_1dk', versionValue);
		version_mineure_kalamine_standard = getLatestVersion('kalamine_standard', versionValue);
	});

	let nom_variante_kalamine;
	let version_mineure_kalamine;
	// Déclaration réactive pour exécuter le code à chaque changement de `variante_kalamine`
	$: {
		if (variante_kalamine === 'standard') {
			version_mineure_kalamine = version_mineure_kalamine_standard;
			nom_variante_kalamine = 'ergopti';
		} else {
			variante_kalamine = '1dk';
			version_mineure_kalamine = version_mineure_kalamine_1dk;
			nom_variante_kalamine = 'ergo_1dk';
		}
	}
	let variante_kalamine = 'standard';
</script>

<h2>Installation</h2>
<div class="encadre text-center">
	<span style="font-weight:bold;">Note :</span> Les fichiers d’installation n’existent au complet qu’à
	partir de la 1.1.
</div>

<h3 id="kbdedit">Installation KbdEdit (méthode préférée)</h3>
<p>
	Les fichiers de cette section ont été réalisées à l’aide de <a href="https://www.kbdedit.com/"
		>KbdEdit</a
	>. C’est un logiciel très complet qui permet de modifier des dispositions de clavier sur Windows.
	Il est en mesure de créer des pilotes pour Windows, et depuis peu pour Mac. Seul Linux n’est pas
	supporté.
</p>
<!-- <p>
    Dans le cas de Linux, il est possible d’utiliser la
	<a href="#kalamine">génération par Kalamine</a>.
	<strong
		>Si vous êtes sur Windows ou Mac, il est fortement conseillé d’utiliser cette installation
		plutôt que celle de Kalamine</strong
	>. En effet, vous serez alors certain d’avoir toutes les fonctionnalités (touches mortes,
	raccourcis clavier, etc.). La version Kalamine est une version allégée, car Kalamine n’a pas
	encore toutes les fonctionnalités de KbdEdit.
</p> -->

<h4>Windows</h4>
<mini-espace />
<div>
	{#if version_mineure_kbdedit_exe !== undefined}
		<a href="/pilotes/kbdedit/Ergopti_v{version_mineure_kbdedit_exe}.exe" download>
			<button class="bouton-telechargement">☛ Ergopti_v{version_mineure_kbdedit_exe}.exe</button>
		</a>
	{/if}
</div>
<mini-espace />
<div>
	{#if version_mineure_kbdedit_kbe !== undefined}
		<a href="/pilotes/kbdedit/Ergopti_v{version_mineure_kbdedit_kbe}.kbe" download
			><button>Fichier source KbdEdit de Ergopti_v{version_mineure_kbdedit_kbe}</button></a
		>
	{/if}
</div>

<moyen-espace />
<div>
	{#if version_mineure_plus !== undefined}
		<a href="/pilotes/plus/ErgoptiPlus_v{version_mineure_plus}.ahk" download
			><button class="bouton-telechargement">☛ ErgoptiPlus_v{version_mineure_plus}.ahk</button></a
		>
	{/if}
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

<mini-espace />

<p>
	Cependant, ce script ne sera actif que lorsque vous l’aurez lancé. Redémarrer l’ordinateur va le
	désactiver, il faudra cliquer à nouveau dessus pour le relancer. Pour automatiser le lancement du
	script ErgoptiPlus au démarrage, il est possible de suivre les étapes suivantes :
</p>
<ol>
	<li>
		Presser simultanément la touche Windows et la touche R. Ce raccourci <kbd>Win</kbd> +
		<kbd>R</kbd> permet d'ouvrir la fenêtre « Exécuter » de Windows ;
	</li>
	<li>Saisir <kbd>shell:startup</kbd> et valider en cliquant sur le bouton « OK » ;</li>
	<li>
		Le dossier qui vient de s'ouvrir correspond au dossier de démarrage. Tout élément dedans est
		exécuté au démarrage de Windows. Créer un raccourci dans ce dossier pointant vers l'emplacement
		où vous allez sauvegarder votre fichier <em>ErgoptiPlus.ahk</em>. Vous pouvez par exemple le
		mettre dans votre dossier Documents.
	</li>
</ol>

<mini-espace />

<p>Certains problèmes ont été rapportés avec le pilote d’Ergopti dans quelques logiciels :</p>
<ul>
	<li>
		Microsoft Excel : Taper un <kbd>+</kbd> avec <kbd>AltGr</kbd> + <kbd>P</kbd> cause des problèmes
		d’édition de la cellule : tout ce qui est tapé avant disparaît et le <kbd-sortie>+</kbd-sortie>
		apparaît. Une solution est de faire <kbd>Shift</kbd> + <kbd>=</kbd> (touche tout en haut à
		gauche, sur la rangée des chiffres), car le <kbd>+</kbd> est aussi à cet emplacement.
	</li>
</ul>
<p>
	Ces problèmes peuvent être résolus avec le script ErgoptiPlus.ahk. Il est possible de mettre les
	variables de fonctionnalités supplémentaires du début de script à 0 afin de n’avoir que les
	corrections.
</p>

<h4>macOS</h4>
<mini-espace />
<div>
	{#if version_mineure_kbdedit_mac !== undefined}
		<a href="/pilotes/kbdedit/Ergopti_v{version_mineure_kbdedit_mac}.keylayout" download
			><button class="bouton-telechargement"
				>☛ Ergopti_v{version_mineure_kbdedit_mac}.keylayout</button
			></a
		>
	{/if}
</div>

<petit-espace />

<h3 id="ahk">Utilisation sans droits administrateur</h3>
<p>
	Sur Windows, il est possible d’utiliser la disposition sans avoir à installer de pilote, et donc
	sans droits administrateur. Cela est particulièrement utile en contexte professionnel où
	l’installation de programmes est bloquée. Cette méthode utilise AutoHotkey afin d’émuler la
	disposition.
</p>
<div>
	{#if version_mineure_ahk !== undefined}
		<div>
			<a href="/pilotes/ahk/Ergopti_v{version_mineure_ahk}.exe" download
				><button class="bouton-telechargement"
					>☛ Ergopti_v{version_mineure_ahk} sans installation</button
				></a
			>
		</div>
		<mini-espace />
		<p>
			Ce fichier est un exécutable qui permet de lancer Ergopti sans aucune installation. C’est un
			script AutoHotkey compilé, il ne nécessite donc même pas d’installer AutoHotkey. Il suffit de
			le lancer pour que le clavier passe en Ergopti. Une icône bleue en forme d’étoile apparaîtra
			dans la barre des tâches pour indiquer que l’émulation en Ergopti est en cours.
		</p>
		<p>
			Pour information, ce script repose sur le fichier ErgoptiPlus.ahk où les variables de
			fonctionnalités supplémentaires ont été mises à 0.
		</p>
	{/if}
</div>
<!-- 
<h3 id="kalamine">Installation Kalamine</h3>
<select bind:value={variante_kalamine} style="height: 2rem">
	<option value="standard" selected>Standard</option>
	<option value="1dk">1DFH avec la 1DK</option>
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
{#if version_mineure_kalamine !== undefined}
	<mini-espace />
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{nom_variante_kalamine}_v{version_mineure_kalamine}.toml"
			download><button>{nom_variante_kalamine}_{version_mineure_kalamine}.toml</button></a
		>
	</div>
	<mini-espace />
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.svg"
			download><button>{nom_variante_kalamine}_{version_mineure_kalamine}.svg</button></a
		>
	</div>
	<div>
		<h4>Windows</h4>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.ahk"
			download
			><button class="bouton-telechargement"
				>{nom_variante_kalamine} v{version_mineure_kalamine} Kalamine AHK (user)</button
			></a
		>
	</div>
	<mini-espace />
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.klc"
			download
			><button class="bouton-telechargement"
				>{nom_variante_kalamine} v{version_mineure_kalamine} Kalamine KLC (admin)</button
			></a
		>
	</div>
	<h4>MacOS</h4>
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.keylayout"
			download
			><button class="bouton-telechargement"
				>{nom_variante_kalamine} v{version_mineure_kalamine} Kalamine Keylayout</button
			></a
		>
	</div>
	<h4>Linux</h4>
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.xkb_keymap"
			download
			><button class="bouton-telechargement"
				>{nom_variante_kalamine} v{version_mineure_kalamine} Kalamine Xkb_keymap (user)</button
			></a
		>
	</div>
	<mini-espace />
	<div>
		<a
			href="/pilotes/kalamine/{variante_kalamine}/{version_mineure_kalamine}/{nom_variante_kalamine}.xkb_symbols"
			download
			><button class="bouton-telechargement"
				>{nom_variante_kalamine} v{version_mineure_kalamine} Kalamine Xkb_symbols (root)</button
			></a
		>
	</div>
{/if} -->
