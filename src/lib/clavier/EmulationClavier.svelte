<script>
	let clavier = 'emulation';
	let textarea;
	let emplacementClavier;
	import { onMount } from 'svelte';
	onMount(() => {
		textarea = document.getElementById('input-text');
		// A mettre en fonction de la variable clavier et non en dur
		emplacementClavier = document.getElementById('clavier_' + clavier);
	});

	import BlocClavier from '$lib/clavier/BlocClavier.svelte';
	import ControlesClavier from '$lib/clavier/controles/ControlesClavier.svelte';
	import data from '$lib/clavier/data/hypertexte_v1.0.19.json';
	import { majClavier } from '$lib/clavier/FonctionsClavier.js';

	import * as data_clavier from '$lib/clavier/stores.js';

	let claviersStores = {};
	for (const clavier in Object.keys(data_clavier)) {
		claviersStores[clavier] = data_clavier[clavier];
	}
	let infos_clavier;
	data_clavier[clavier].subscribe((value) => {
		infos_clavier = value;
	});

	// Maj automatique de la couche
	export let shift = false;
	export let altgr = false;
	export let control = false;
	export let a_grave = false;
	let couche = 'Primary';

	$: if (altgr && shift) {
		couche = 'ShiftAltGr';
		data_clavier[clavier].update((currentData) => {
			currentData['couche'] = couche;
			return currentData;
		});
		majClavier(clavier);
	} else if (altgr && !shift) {
		couche = 'AltGr';
		data_clavier[clavier].update((currentData) => {
			currentData['couche'] = couche;
			return currentData;
		});
		majClavier(clavier);
	} else if (!altgr && shift) {
		couche = 'Shift';
		data_clavier[clavier].update((currentData) => {
			currentData['couche'] = couche;
			return currentData;
		});
		majClavier(clavier);
	} else if (a_grave) {
		couche = 'À';
		data_clavier[clavier].update((currentData) => {
			currentData['couche'] = couche;
			return currentData;
		});
		majClavier(clavier);
	} else {
		couche = 'Primary';
		data_clavier[clavier].update((currentData) => {
			currentData['couche'] = couche;
			return currentData;
		});
		// majClavier(clavier); // No fonctionne pas ici, mais pas grave car pas besoin
	}

	function setCouche() {
		if (altgr && shift) {
			couche = 'ShiftAltGr';
			data_clavier[clavier].update((currentData) => {
				currentData['couche'] = couche;
				return currentData;
			});
		} else if (altgr && !shift) {
			couche = 'AltGr';
			data_clavier[clavier].update((currentData) => {
				currentData['couche'] = couche;
				return currentData;
			});
		} else if (!altgr && shift) {
			couche = 'Shift';
			data_clavier[clavier].update((currentData) => {
				currentData['couche'] = couche;
				return currentData;
			});
		} else if (a_grave) {
			couche = 'À';
			data_clavier[clavier].update((currentData) => {
				currentData['couche'] = couche;
				return currentData;
			});
		} else {
			couche = 'Primary';
			data_clavier[clavier].update((currentData) => {
				currentData['couche'] = couche;
				return currentData;
			});
		}
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
				(toucheClavier['touche'] === 'magique' && infos_clavier['plus'] === 'non')
			) {
				envoiTouche_ReplacerCurseur('Enter');
			} else if (a_grave) {
				let touche;
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					// On supprime le à avant de taper le raccourci de la couche À
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
		if (infos_clavier['plus'] === 'oui') {
			if (toucheClavier[couche + '+'] !== undefined) {
				touche = toucheClavier[couche + '+'];
			} else {
				touche = toucheClavier[couche];
			}
		} else {
			touche = toucheClavier[couche];
		}

		// Corrections localisées
		if (infos_clavier['plus'] === 'oui') {
			if (toucheClavier['touche'] === 'q') {
				touche = 'qu';
			}
		}
		touche = touche.replace(/<span class='espace-insecable'><\/span>/g, ' ');
		envoiTouche_ReplacerCurseur(touche);
	}

	function envoiTouche_ReplacerCurseur(touche) {
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
		// Nettoyage des touches actives
		const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
		[].forEach.call(touchesActives, function (el) {
			if (el.dataset.type != 'special') {
				el.classList.remove('touche-active');
			}
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
		setCouche();
		majClavier(clavier);
	}

	let champTexte = '';
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
</script>

<!-- <ControlesClavier clavier="emulation" /> -->
<mini-espace />
<BlocClavier clavier="emulation" />

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
		border-radius: 5px;
		border: none;
		resize: none;
		background-color: rgba(0, 0, 0, 0.4);
		color: rgba(255, 255, 255, 0.9);
	}

	#input-text:focus-visible {
		background-color: white;
		color: black;
		outline: none;
	}
</style>
