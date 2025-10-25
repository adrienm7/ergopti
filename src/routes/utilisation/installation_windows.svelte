<script>
	import Ergopti from '$lib/components/Ergopti.svelte';
	import ErgoptiPlus from '$lib/components/ErgoptiPlus.svelte';
	import SFB from '$lib/components/SFB.svelte';
	import { version, discordLink } from '$lib/stores_infos.js';
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

<h2 id="windows">
	<i class="icon-windows purple" style="vertical-align:-0.05em"></i> Installation Windows
</h2>
<p>
	Le pilote ci-dessous a été réalisé à l’aide de <a class="link" href="https://www.kbdedit.com/"
		>KbdEdit</a
	>. C’est un logiciel très complet qui permet de modifier des dispositions de clavier sur Windows.
	Il est en mesure de créer des pilotes pour Windows, et depuis peu pour Mac. Seul Linux n’est pas
	supporté.
</p>

{#if version_mineure_kbdedit_exe !== undefined}
	<div class="download-buttons">
		<a href="/drivers/windows/Ergopti_v{version_mineure_kbdedit_exe}.exe" download>
			<button
				><i class="icon-windows" style="vertical-align:-0.05em"></i>
				Installateur KbdEdit d’Ergopti v{version_mineure_kbdedit_exe}</button
			>
		</a>
		<tiny-space></tiny-space>
		<a href="/drivers/windows/Ergopti_v{version_mineure_kbdedit_kbe}.kbe" download>
			<button class="alt-button"
				><i class="icon-windows" style="vertical-align:-0.05em"></i> Fichier source KbdEdit
				d’Ergopti v{version_mineure_kbdedit_kbe}</button
			>
		</a>
	</div>
{/if}

<small-space></small-space>

<p>
	Il suffit d’exécuter le fichier <code>Ergopti_v{version_mineure_kbdedit_exe}.exe</code> et de cliquer
	sur le bouton d’installation pour installer le pilote sur Windows. Ensuite, il est conseillé de redémarrer
	l’ordinateur pour être sûr que le pilote soit bien pris en compte.
</p>
<enhanced:img
	class="no-upscale"
	style="width: min(400px, 100%)!important;"
	src="$lib/images/windows_installation_1.jpg"
	alt="Screenshot d’installation du pilote KbdEdit"
/>

<div style="margin-top:15px"></div>

<p>
	Après l’installation, se rendre dans <code>Paramètres</code> >
	<code>Heure et langue</code> > <code>Langue et région</code> et cliquer sur le <code>…</code> de
	la langue installée (ici <code>Français (France)</code>) :
</p>
<enhanced:img
	src="$lib/images/windows_installation_2.jpg"
	alt="Screenshot 1/2 des paramètres Windows 11 pour changer sa disposition de clavier"
/>

<div style="margin-top:15px"></div>
<p>
	Cliquer ensuite sur <code>Ajouter un clavier</code> et sélectionner la version qui vient d’être ajoutée
	par l’installateur de KbdEdit :
</p>
<enhanced:img
	src="$lib/images/windows_installation_3.jpg"
	alt="Screenshot 2/2 des paramètres Windows 11 pour changer sa disposition de clavier"
/>
<p>
	Il est conseillé de supprimer tous les claviers de cette liste avant d’ajouter celui d’<Ergopti
	></Ergopti> et ensuite éventuellement rajouter vos autres claviers comme AZERTY. Cela permettra de
	l’avoir comme clavier par défaut, étant en première position de la liste.
</p>

<div style="margin-top:15px"></div>

<p>La disposition sera ensuite disponible dans le menu linguistique de la barre des tâches :</p>
<enhanced:img
	class="no-upscale"
	style="width: min(400px, 100%)!important;"
	src="$lib/images/windows_installation_4.jpg"
	alt="Screenshot du menu menu linguistique de la barre des tâches"
/>

<h3 id="ahk">Pilote AutoHotkey (sans droits d’administrateur)</h3>
<p>
	Le pilote Windows créé par KbdEdit nécessite des droits d’administrateur pour être installé. Il ne
	peut donc pas être utilisé dans certaines situations, notamment en contexte professionnel. <strong
		>La version AutoHotkey a exactement les mêmes fonctionnalités que la version KbdEdit, mais ne
		nécessite pas d’installation avec des droits d’administrateur.</strong
	> En réalité, elle est même beaucoup plus puissante, car elle permet d’avoir des fonctionnalités avancées
	comme les remplacements de texte ou les macros.
</p>
<p>
	Il est cependant toujours conseillé d’installer et utiliser le pilote KbdEdit si possible. En
	effet, cela garantit que la disposition clavier sera <Ergopti></Ergopti> dès le démarrage et sur l’écran
	de connexion. Au contraire, la version AutoHotkey, bien qu’elle soit fonctionnelle dans tous les programmes,
	ne fonctionnera pas sur l’écran de connexion, car le script ne sera pas encore chargé.
</p>
<p class="encadre">
	En résumé, le mieux est d’utiliser les deux versions en parallèle : le pilote KbdEdit pour avoir
	<Ergopti></Ergopti> partout, et le script AutoHotkey pour bénéficier des fonctionnalités avancées.
	Ce script corrige d’ailleurs quelques limitations du pilote KbdEdit, cf. la section
	<a class="link" href="#windows-solutions">Résolution de problèmes connus</a>.
</p>

<small-space></small-space>

{#if version_mineure_plus !== undefined}
	<div class="download-buttons">
		<a href="/drivers/autohotkey/ErgoptiPlus_v{version_mineure_plus}.ahk" download>
			<button
				><i class="icon-autohotkey" style="vertical-align:-0.08em;"></i>
				ErgoptiPlus v{version_mineure_plus}.ahk</button
			>
		</a>
		<a href="/drivers/autohotkey/compiled/ErgoptiPlus_v{version_mineure_plus}.exe" download>
			<button class="alt-button"
				><i class="icon-autohotkey" style="vertical-align:-0.08em;"></i>
				ErgoptiPlus v{version_mineure_plus} compilé</button
			>
		</a>
	</div>
{/if}
<p>
	Il est également conseillé (mais c’est optionnel) de télécharger les 2 fichiers suivants : <a
		class="link"
		href="/drivers/autohotkey/ErgoptiPlus_Icon.ico"
		download>ErgoptiPlus_Icon.ico</a
	>
	ainsi que
	<a class="link" href="/drivers/autohotkey/ErgoptiPlus_Icon_Disabled.ico" download
		>ErgoptiPlus_Icon_Disabled.ico</a
	>. Ils sont à placer dans le même dossier que celui du script <em>.ahk</em> et permettent d’en modifier
	l’icône dans la barre des tâches.
</p>

<tiny-space></tiny-space>

<p>
	Afin que le code source <em>ErgoptiPlus.ahk</em> fonctionne, il faut auparavant installer
	<a class="link" href="https://www.autohotkey.com/">AutoHotkey v2</a>. L’installation pour
	l’utilisateur actuel ne nécessite pas de droits d’administrateur. Une fois cela fait, il suffit de
	double-cliquer sur le fichier <em>.ahk</em> pour l’exécuter avec AutoHotkey.
</p>
<p>
	En réalité, il est même possible de ne rien installer du tout en se contentant de télécharger le
	binaire d’AutoHotkey. Ensuite, il suffit de faire un clic droit sur le fichier <em>.ahk</em> puis
	<code>ouvrir avec</code> et sélectionner ce binaire. Cette solution peut être utile si même l’installation
	d’AutoHotkey n’est pas permise sur votre système.
</p>
<p>
	Une dernière option est d’utiliser le code AutoHotkey compilé en un <em>.exe</em>. Cela évite même
	de devoir installer AutoHotkey, car le code nécessaire au fonctionnement du script est directement
	inclus dans le <em>.exe</em>. Toutefois, idéalement il vaut mieux installer AutoHotkey et utiliser
	le code source, car cela permet d’inspecter le contenu du script afin de comprendre comment il
	fonctionne, voire le modifier pour l’adapter à votre utilisation. Le fichier <em>.ahk</em> se
	modifie avec un simple éditeur de texte (clic droit,
	<code>ouvrir avec</code>) afin que vous puissiez l’adapter selon vos envies, notamment pour en
	désactiver des fonctionnalités ou en ajouter. N’oubliez pas de le relancer pour appliquer vos
	modifications.
</p>
<p>
	Le raccourci
	<kbd>AltGr</kbd>
	+ <kbd>BackSpace</kbd> a été implémenté afin de relancer facilement le script après une
	modification. De plus, le raccourci <kbd>AltGr</kbd>
	+ <kbd>Entrée</kbd> permet de mettre le script en pause, ou de le réactiver s’il est déjà en
	pause. C’est très utile pour désactiver momentanément le script, par exemple si un collègue veut
	taper sur votre ordinateur et que votre clavier est encore en émulation <Ergopti></Ergopti>.
</p>

<h4>Automatisation du lancement du script</h4>
<p>
	Il est important de noter que le script AutoHotkey ne sera actif que tant qu’il est en cours
	d’exécution en arrière-plan. Redémarrer l’ordinateur va le désactiver, il faudra cliquer à nouveau
	dessus pour le relancer. Pour automatiser le lancement automatique du script <em>.ahk</em> (ou sa
	version compilée en <em>.exe</em>) au démarrage, et donc ne plus avoir besoin d’y penser, il est
	possible de suivre les étapes suivantes :
</p>
<ol>
	<li>
		Presser simultanément la touche Windows et la touche R. Ce raccourci <kbd>Win</kbd> +
		<kbd>R</kbd> permet d'ouvrir la fenêtre « Exécuter » de Windows ;
	</li>
	<li>Saisir <code>shell:startup</code> et valider en cliquant sur le bouton « OK » ;</li>
	<li>
		Le dossier qui vient de s'ouvrir correspond au dossier de démarrage. Tout élément dedans est
		exécuté au démarrage de Windows. Créer un raccourci dans ce dossier pointant vers l'emplacement
		où vous allez sauvegarder votre fichier <em>ErgoptiPlus.ahk</em>. Vous pouvez par exemple le
		mettre dans votre dossier Documents.
	</li>
</ol>

<h3 id="windows-solutions">Résolution de problèmes connus</h3>
<p>
	Certains problèmes ont été rapportés avec le pilote Windows d’<Ergopti></Ergopti> dans quelques logiciels :
</p>
<ul>
	<li>
		<b>Microsoft Excel :</b> Taper un <kbd-output>+</kbd-output> avec <kbd>AltGr</kbd> +
		<kbd>P</kbd>
		cause des problèmes d’édition de la cellule : tout ce qui est tapé avant disparaît et est remplacé
		par un
		<kbd-output>+</kbd-output>.<br />➜ Ce problème se résout en utilisant le script
		<em>ErgoptiPlus.ahk</em>
		pour émuler la disposition et garantir que ce soit bien un symbole <kbd-output>+</kbd-output> qui
		soit envoyé et non un raccourci interne d’Excel qui interfère.
	</li>
	<li>
		Un utilisateur de la version AutoHotkey avait des problèmes avec les remplacements de texte,
		notamment pour l’autocorrection. Après de nombreuses recherches, il s’est avéré que la cause
		était le logiciel de contrôle des LEDs de sa tour de pc, qui interférait avec AutoHotkey.<br />
		➜ Pour résoudre ce genre de problèmes, il faut donc dans un premier temps fermer toutes ses applications
		sauf AutoHotkey pour vérifier si le problème persiste. S’il persiste, c’est peut-être un problème
		affectant tous les utilisateurs de la version AutoHotkey et vous êtes invité à le signaler sur
		<a class="link" href="https://github.com/adrienm7/ergopti" target="_blank"
			>le repo GitHub <i class="icon-github"></i></a
		>
		ou sur
		<a class="link" href={discordLink} target="_blank">le Discord <i class="icon-discord"></i></a>.
		Le script AutoHotkey étant cependant utilisé intensivement par plusieurs utilisateurs, la
		plupart des problèmes sont déjà résolus et il est plus probable qu’il provienne d’un conflit
		avec une application. Cela peut notamment se produire si vous utilisez un autre logiciel de
		remappage de clavier, ou un logiciel qui intercepte les frappes clavier pour faire des
		raccourcis (Kanata, PowerToys, Espanso, logiciel Nvidia, de gaming, etc.).
	</li>
</ul>
