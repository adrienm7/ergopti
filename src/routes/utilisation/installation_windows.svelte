<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { version } from '$lib/stores_infos.js';
	import { getLatestVersion } from '$lib/js/getVersions.js';
	let versionValue,
		version_mineure_kbdedit_exe,
		version_mineure_kbdedit_kbe,
		version_mineure_ahk,
		version_mineure_plus;
	version.subscribe((value) => {
		versionValue = value;
		version_mineure_kbdedit_exe = getLatestVersion('kbdedit_exe', versionValue);
		version_mineure_kbdedit_kbe = getLatestVersion('kbdedit_kbe', versionValue);
		version_mineure_ahk = getLatestVersion('ahk', versionValue);
		version_mineure_plus = getLatestVersion('plus', versionValue);
	});
</script>

<h2 id="windows"><i class="icon-windows purple"></i> Installation Windows</h2>
<p>
	Les fichiers de cette section ont été réalisés à l’aide de <a
		class="link"
		href="https://www.kbdedit.com/">KbdEdit</a
	>. C’est un logiciel très complet qui permet de modifier des dispositions de clavier sur Windows.
	Il est en mesure de créer des pilotes pour Windows, et depuis peu pour Mac. Seul Linux n’est pas
	supporté.
</p>
<tiny-space></tiny-space>
<div>
	{#if version_mineure_kbdedit_exe !== undefined}
		<a href="/drivers/windows/Ergopti_v{version_mineure_kbdedit_exe}.exe" download>
			<button class="bouton-telechargement"
				><i class="icon-windows"></i> Ergopti_v{version_mineure_kbdedit_exe}.exe</button
			>
		</a>
	{/if}
</div>
<tiny-space></tiny-space>
<div>
	{#if version_mineure_kbdedit_kbe !== undefined}
		<a href="/drivers/windows/Ergopti_v{version_mineure_kbdedit_kbe}.kbe" download>
			<button
				><i class="icon-windows"></i> Fichier source KbdEdit d’Ergopti_v{version_mineure_kbdedit_kbe}</button
			>
		</a>
	{/if}
</div>
<h3 id="ahk">Installation AutoHotkey (méthode alternative)</h3>
<div>
	{#if version_mineure_plus !== undefined}
		<a href="/drivers/autohotkey/ErgoptiPlus_v{version_mineure_plus}.ahk" download>
			<button class="bouton-telechargement"
				><i class="icon-autohotkey" style="vertical-align:-0.08em;"></i>
				ErgoptiPlus_v{version_mineure_plus}.ahk</button
			>
		</a>
	{/if}
</div>
<p>
	Afin que le code source ErgoptiPlus.ahk fonctionne, il faut auparavant installer <a
		class="link"
		href="https://www.autohotkey.com/">AutoHotkey v2</a
	>. Une fois cela fait, il suffit de double-cliquer sur le fichier ErgoptiPlus.ahk pour l’exécuter
	avec AutoHotkey.
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
<tiny-space></tiny-space>
<p>
	Cependant, ce script ne sera actif que lorsque vous l’aurez lancé. Redémarrer l’ordinateur va le
	désactiver, il faudra cliquer à nouveau dessus pour le relancer. Pour automatiser le lancement du
	script ErgoptiPlus au démarrage, il est possible de suivre les étapes suivantes :
</p>
<ol>
	<li>
		Presser simultanément la touche Windows et la touche R. Ce raccourci <kbd>Win</kbd> +
		<kbd>R</kbd> permet d'ouvrir la fenêtre « Exécuter » de Windows ;
	</li>
	<li>Saisir <kbd>shell:startup</kbd> et valider en cliquant sur le bouton « OK » ;</li>
	<li>
		Le dossier qui vient de s'ouvrir correspond au dossier de démarrage. Tout élément dedans est
		exécuté au démarrage de Windows. Créer un raccourci dans ce dossier pointant vers l'emplacement
		où vous allez sauvegarder votre fichier <em>ErgoptiPlus.ahk</em>. Vous pouvez par exemple le
		mettre dans votre dossier Documents.
	</li>
</ol>

<h3>Résolution de problèmes connus</h3>
<p>Certains problèmes ont été rapportés avec le pilote d’Ergopti dans quelques logiciels :</p>
<ul>
	<li>
		Microsoft Excel : Taper un <kbd>+</kbd> avec <kbd>AltGr</kbd> + <kbd>P</kbd> cause des problèmes
		d’édition de la cellule : tout ce qui est tapé avant disparaît et le
		<kbd-output>+</kbd-output> apparaît. Ce problème est résolu en utilisant le script ErgoptiPlus.ahk
		pour émuler la disposition.
	</li>
	<li>
		Un utilisateur de la version AutoHotkey avait des problèmes avec les remplacements de texte,
		notamment pour l’autocorrection. Après de nombreuses recherches, il s’est avéré que la cause
		était le logiciel de contrôle des LEDs de sa tour de pc, qui interférait avec AutoHotkey. Pour
		résoudre ce genre de problèmes, il faut donc dans un premier temps fermer toutes ses
		applications sauf AutoHotkey pour vérifier si le problème persiste. S’il persiste, c’est
		peut-être un problème affectant tous les utilisateurs de la version AutoHotkey et vous êtes
		invité à le signaler sur le GitHub ou le Discord. Le script AutoHotkey étant cependant utilisé
		intensivement par plusieurs utilisateurs, la plupart des problèmes sont déjà résolus et il est
		plus probable qu’il provienne d’un conflit avec une application. Cela peut être notamment si
		vous utilisez un autre logiciel de remappage de clavier, ou un logiciel qui intercepte les
		frappes clavier pour faire des raccourcis (Kanata, PowerToys, Espanso, etc.).
	</li>
</ul>
