<script>
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import { onMount } from 'svelte';
	import data from '$lib/data/hypertexte.json';

	let emplacementClavier;
	let plus = 'non';

	// Maj automatique de la couche
	export let shift = false;
	export let altgr = false;
	export let control = false;
	export let a_grave = false;
	let couche = 'Primary';
	$: if (altgr && shift) {
		couche = 'ShiftAltGr';
		restart();
	} else if (altgr && !shift) {
		couche = 'AltGr';
		restart();
	} else if (!altgr && shift) {
		couche = 'Shift';
		restart();
	} else if (a_grave) {
		couche = 'À';
		restart();
	} else {
		couche = 'Primary';
		restart();
	}
	// Pour maj le clavier
	let unique = {}; // every {} is unique, {} === {} evaluates to false
	function restart() {
		unique = {};
	}

	function activationModificateur(event) {
		if (event.code === 'AltRight') {
			altgr = true;
			return true;
		}
		if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			shift = true;
			return true;
		}
		if (event.code === 'ControlLeft' || event.code === 'ControlRight') {
			control = true;
			return true;
		}
		return false;
	}

	function emulationClavier(event) {
		// Activation des éventuelles touches modificatrices
		if (activationModificateur(event)) {
			return; // Si c'est une touche modificatrice, on quitte la fonction
		}

		// Ne pas intercepter les raccourcis avec Ctrl
		if (control & !altgr) {
			// Attention, quand AltGr est activé, Ctrl l’est aussi, d’où le &
			return true;
		}

		// Si touche normale
		let keyPressed = event.code;
		let res = data['iso'].find((el) => el['code'] == keyPressed); // La touche de notre layout correspondant au keycode tapé
		if (res !== undefined) {
			event.preventDefault(); // La touche selon le pilote de l’ordinateur n’est pas tapée
			let toucheClavier = data.touches.find((el) => el['touche'] == res['touche']);
			presserToucheClavier(toucheClavier['touche']); // Presser la touche sur le clavier visuel
			if (keyPressed === 'CapsLock' || keyPressed === 'Backspace') {
				envoiTouche_ReplacerCurseur('Backspace');
			} else if (
				keyPressed === 'Enter' ||
				keyPressed === 'AltRight' ||
				(toucheClavier['touche'] === 'magique' && plus === 'non')
			) {
				envoiTouche_ReplacerCurseur('Enter');
			} else if (a_grave) {
				let touche;
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					// On supprime le à avant de taper le raccourci de la couche À
					var textarea = document.getElementById('input-text');
					textarea.value = textarea.value.slice(0, -1);
					touche = toucheClavier['À'];
				}
				a_grave = false;
				envoiTouche_ReplacerCurseur(touche);
			} else {
				envoiTouche(event, toucheClavier);
			}
		}
	}

	function envoiTouche(event, toucheClavier) {
		let touche = '';
		let couche;
		if (event.shiftKey && altgr) {
			couche = 'ShiftAltGr';
		} else if (!event.shiftKey && altgr) {
			couche = 'AltGr';
		} else if (event.shiftKey && !altgr) {
			couche = 'Shift';
		} else {
			couche = 'Primary';
		}
		if (plus === 'oui') {
			if (toucheClavier[couche + '+'] !== undefined) {
				touche = toucheClavier[couche + '+'];
			} else {
				touche = toucheClavier[couche];
			}
		} else {
			touche = toucheClavier[couche];
		}

		// Corrections localisées
		if (plus === 'oui') {
			if (toucheClavier['touche'] === 'q') {
				touche = 'qu';
			}
		}
		touche = touche.replace(/<span class='espace-insecable'><\/span>/g, ' ');
		envoiTouche_ReplacerCurseur(touche);
	}

	function envoiTouche_ReplacerCurseur(touche) {
		// Récupérer la textarea et le contenu à insérer
		var textarea = document.getElementById('input-text');

		// Récupérer la position du curseur dans la textarea
		var positionCurseur = textarea.selectionStart;

		// Récupérer le texte avant et après la position du curseur
		var texteAvantCurseur = textarea.value.substring(0, positionCurseur);
		var texteApresCurseur = textarea.value.substring(positionCurseur);

		if (touche === 'à') {
			a_grave = true;
		}

		// Concaténer les trois parties pour obtenir le contenu HTML mis à jour
		let nouvellePositionCurseur;
		if (touche === 'Backspace') {
			textarea.value = texteAvantCurseur.substring(0, positionCurseur - 1) + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur - 1;
		} else if (touche === 'Enter') {
			textarea.value = texteAvantCurseur + '\n' + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur + 1;
		} else if (touche === '★') {
			let toucheRepetee = texteAvantCurseur.slice(-1);
			textarea.value = texteAvantCurseur + toucheRepetee + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur + 1;
		} else {
			textarea.value = texteAvantCurseur + touche + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur + touche.length;
		}
		textarea.setSelectionRange(nouvellePositionCurseur, nouvellePositionCurseur);
	}

	function presserToucheClavier(touche) {
		emplacementClavier = document.getElementById('clavier-emulation');

		// Nettoyage des touches actives
		const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
		[].forEach.call(touchesActives, function (el) {
			el.classList.remove('touche-active');
		});

		emplacementClavier
			.querySelector("bloc-touche[data-touche='" + touche + "']")
			.classList.add('touche-active');
	}

	function relacherModificateurs(event) {
		if (event.code === 'AltRight') {
			altgr = false;
		} else if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			shift = false;
		} else if (event.code === 'ControlLeft' || event.code === 'ControlRight') {
			control = false;
		}
	}

	let champTexte = '';
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
		<petit-espace />

		<h3>Pour les comparateurs de disposition</h3>
		<mini-espace />
		<div>
			<span>Version ISO : </span><a href="/files/hypertexte.v1.0.3.fr.iso.txt"
				><button>hypertexte.v1.0.3.fr.iso</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version Ergodox : </span><a href="/files/hypertexte.v1.0.3.fr.ergodox.txt"
				><button>hypertexte.v1.0.3.fr.ergodox</button></a
			>
		</div>
	</div>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <Nom_Plus />
	</p>
	<petit-espace />
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Tester la disposition en ligne</h2>

	{#key unique}
		<EnsembleClavier
			emplacement={'clavier-emulation'}
			type={'iso'}
			{couche}
			couleur={'non'}
			{plus}
			controles={'non'}
		/>
	{/key}

	<mini-espace />
	<div style="margin: 0 auto; width: 100%;">
		<textarea
			id="input-text"
			bind:value={champTexte}
			on:keydown={emulationClavier}
			on:keyup={relacherModificateurs}
		/>
	</div>
	<p id="output-text" />
</div>

<style>
	#input-text {
		display: block;
		margin: 0 auto;
		width: 70%;
		height: 150px;
		padding: 12px;
		border-radius: 7px;
		background-color: white;
		color: black;
	}
	h3 {
		display: inline-block;
		position: relative;
		color: white;
		font-weight: normal;
	}

	h3::after {
		display: block;
		position: absolute;
		height: 4px;
		width: 100%;
		content: '';
		background: white;
		border-radius: 10px;
		margin-top: 2px;
	}
</style>
