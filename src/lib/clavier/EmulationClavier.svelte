<script>
	import EnsembleClavier from '$lib/clavier/EnsembleClavier.svelte';
	import data from '$lib/clavier/data/hypertexte.json';

	let emplacementClavier;
	const remplacements = {
		a: 'ainsi',
		c: 'c’est',
		ct: 'c’était',
		d: 'donc',
		f: 'faire',
		g: 'j’ai',
		gt: 'j’étais',
		h: 'heure',
		m: 'mais',
		p: 'prendre',
		q: 'question',
		r: 'rien',
		s: 'sous',
		très: 't'
	};
	let plus = 'oui';

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
		// console.log(keyPressed);
		let res = data['iso'].find((el) => el['code'] == keyPressed); // La touche de notre layout correspondant au keycode tapé
		if (res !== undefined) {
			event.preventDefault(); // La touche selon le pilote de l’ordinateur n’est pas tapée
			let toucheClavier = data.touches.find((el) => el['touche'] == res['touche']);
			presserToucheClavier(toucheClavier['touche']); // Presser la touche sur le clavier visuel
			if (keyPressed === 'CapsLock' || keyPressed === 'Backspace') {
				envoiTouche_ReplacerCurseur('Backspace');
				return true;
			}
			if (
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
			let mot = texteAvantCurseur.split(' ').slice(-1).toString();

			if (mot.toLowerCase() in remplacements) {
				let remplacement = remplacements[mot.toLowerCase()];

				let casse = 'minuscules';
				if (mot === mot.toUpperCase() && mot.length > 1) {
					casse = 'majuscules';
				} else if (mot === mot.charAt(0).toUpperCase() + mot.slice(1).toLowerCase()) {
					casse = 'titelcase';
				}

				if (casse === 'minuscules') {
					remplacement = remplacement.toLowerCase();
				} else if (casse === 'titelcase') {
					remplacement = remplacement.charAt(0).toUpperCase() + remplacement.slice(1).toLowerCase();
				} else if (casse === 'majuscules') {
					remplacement = remplacement.toUpperCase();
				}

				textarea.value =
					texteAvantCurseur.split(' ').slice(0, -1).join(' ') +
					' ' +
					remplacement +
					texteApresCurseur;
				nouvellePositionCurseur = positionCurseur + remplacement.length;
			} else {
				let toucheRepetee = texteAvantCurseur.slice(-1);
				textarea.value = texteAvantCurseur + toucheRepetee + texteApresCurseur;
				nouvellePositionCurseur = positionCurseur + 1;
			}
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
		placeholder="Écrivez ici"
		bind:value={champTexte}
		on:keydown={emulationClavier}
		on:keyup={relacherModificateurs}
	/>
</div>

<style>
	#input-text {
		display: block;
		margin: 0 auto;
		width: 100%;
		height: 200px;
		padding: 15px;
		border-radius: 3px;
		border: none;
		resize: none;
		background-color: white;
		color: black;
	}

	#input-text:focus-visible {
		background-color: rgba(0, 0, 0, 0.4);
		color: rgba(255, 255, 255, 0.9);
		outline: none;
	}
</style>
