import { Clavier } from '$lib/clavier/Clavier.js';
import remplacements from '$lib/clavier/remplacementsMagique.json';
import data from '$lib/hypertexte_v1.1.2.json'
export class EmulationClavier extends Clavier {
	constructor(id) {
		super(id);
		this.shift = false;
		this.alt = false;
		this.altgr = false;
		this.control = false;
		this.circonflexe = false;
		this.trema = false;
		this.e = false;
		this.i = false;
		this.R = false;
		this.a_grave = false;
		this.virgule = false;
		this.couche = 'Primary'; // Couche par défaut
		// La portée de this est modifiée dans le textinput sinon et this.data est undefined
		this.emulationClavier = this.emulationClavier.bind(this);
		this.relacherModificateurs = this.relacherModificateurs.bind(this);
		this.data = data;
	}

	activationModificateur(event) {
		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			this.altgr = true;
			return true;
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(event.code === 'ControlRight' && this.infos_clavier['plus'] === 'oui')
		) {
			this.shift = true;
			return true;
		} else if (event.code === 'AltLeft') {
			this.alt = true;
			return true;
		} else if (
			event.code === 'ControlLeft' ||
			(event.code === 'ControlRight' && this.infos_clavier['plus'] === 'non')
		) {
			this.control = true;
			return true;
		}
		return false;
	}

	relacherModificateurs(event) {
		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			this.altgr = false;
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(event.code === 'ControlRight' && this.infos_clavier['plus'] === 'oui')
		) {
			this.shift = false;
		} else if (event.code === 'AltLeft') {
			this.alt = false;
		} else if (
			event.code === 'ControlLeft' ||
			(event.code === 'ControlRight' && this.infos_clavier['plus'] === 'non')
		) {
			this.control = false;
		}
		this.setCouche();
		this.majClavier();
	}

	setCouche() {
		// Déterminer la valeur de `couche`
		if (this.altgr && this.shift) {
			this.couche = 'ShiftAltGr';
		} else if (this.altgr) {
			this.couche = 'AltGr';
		} else if (this.shift) {
			this.couche = 'Shift';
		} else if (this.control) {
			this.couche = 'Ctrl';
		} else if (this.circonflexe) {
			this.couche = '^';
		} else if (this.trema) {
			this.couche = 'trema';
		} else if (this.e) {
			this.couche = 'e';
		} else if (this.i) {
			this.couche = 'i';
		} else if (this.R) {
			this.couche = 'R';
		} else if (this.a_grave) {
			this.couche = 'À';
		} else if (this.virgule) {
			this.couche = ',';
		} else {
			this.couche = 'Primary';
		}

		// Mettre à jour le store
		this.data_clavier.update((currentData) => {
			currentData['couche'] = this.couche;
			return currentData;
		});
		this.majClavier();
	}

	emulationClavier(event) {
		let modificateurActive = this.activationModificateur(event); // Activation des éventuelles touches modificatrices
		this.setCouche();
		if (this.alt && this.infos_clavier['plus'] === 'oui') {
			this.envoiTouche_ReplacerCurseur('Enter');
			this.alt = false;
			return true;
		}
		if (modificateurActive) {
			return true;
		}

		// Ne pas intercepter les raccourcis avec Ctrl
		if (this.control & !this.altgr) {
			// Attention, quand this.altgr est activé, Ctrl l’est aussi, d’où le &
			return true;
		}

		// Si touche normale
		let keyPressed = event.code;
		let res = this.data[this.infos_clavier.type].find((el) => el['code'] == keyPressed); // La touche de notre layout correspondant au keycode tapé
		if (res !== undefined) {
			event.preventDefault(); // La touche selon le pilote de l’ordinateur n’est pas tapée
			let toucheClavier = this.data.touches.find((el) => el['touche'] == res['touche']);
			this.presserToucheClavier(toucheClavier['touche']); // Presser la touche sur le clavier visuel
			let touche;
			if (
				this.altgr &&
				this.shift &&
				keyPressed === 'CapsLock' &&
				this.infos_clavier['plus'] === 'oui'
			) {
				this.envoiTouche_ReplacerCurseur('Ctrl-Delete');
				return true;
			} else if (
				this.control &&
				(keyPressed === 'Backspace' ||
					(keyPressed === 'CapsLock' && this.infos_clavier['plus'] === 'oui'))
			) {
				this.envoiTouche_ReplacerCurseur('Ctrl-Backspace');
				return true;
			} else if (
				keyPressed === 'Delete' ||
				(this.shift && keyPressed === 'CapsLock' && this.infos_clavier['plus'] === 'oui')
			) {
				this.envoiTouche_ReplacerCurseur('Delete');
				return true;
			} else if (
				keyPressed === 'Backspace' ||
				(keyPressed === 'CapsLock' && this.infos_clavier['plus'] === 'oui')
			) {
				this.envoiTouche_ReplacerCurseur('Backspace');
				return true;
			} else if (keyPressed === 'Enter') {
				this.envoiTouche_ReplacerCurseur('Enter');
			} else if (this.e) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					touche = toucheClavier['e'];
				}
				this.e = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.circonflexe) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					touche = toucheClavier['^'];
				}
				this.circonflexe = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.trema) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					touche = toucheClavier['trema'];
				}
				this.trema = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.i) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					touche = toucheClavier['i'];
				}
				this.i = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.R) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					touche = toucheClavier['R'];
				}
				this.R = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.a_grave) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					// On supprime le à avant de taper le raccourci de la couche À
					this.textarea.value = this.textarea.value.slice(0, -1);
					touche = toucheClavier['À'];
				}
				this.a_grave = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else if (this.virgule) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					// On supprime le , avant de taper le raccourci de la couche Virgule
					this.textarea.value = this.textarea.value.slice(0, -1);
					touche = toucheClavier[','];
				}
				this.virgule = false;
				this.envoiTouche_ReplacerCurseur(touche);
			} else {
				this.envoiTouche(event, toucheClavier);
			}
		}
	}

	envoiTouche(event, toucheClavier) {
		/* Ctrl + touche renvoie Ctrl + émulation de touche */
		/* Ne fonctionne pas actuellement */
		// if (this.control & !this.altgr) {
		// 	// Attention, quand this.altgr est activé, Ctrl l’est aussi, d’où le &
		// 	console.log(toucheClavier.touche);
		// 	// Crée un nouvel événement clavier pour "Ctrl + lettre".
		// 	const ctrlEvent = new KeyboardEvent('keydown', {
		// 		key: toucheClavier.touche,
		// 		ctrlKey: true, // Spécifie que la touche Ctrl est enfoncée
		// 		bubbles: true,
		// 		cancelable: true
		// 	});
		// 	// Envoie l'événement au même input
		// 	this.textarea.dispatchEvent(ctrlEvent);
		// 	return true;
		// }

		let touche = '';
		if (this.infos_clavier['plus'] === 'oui') {
			if (toucheClavier[this.couche + '+'] !== undefined) {
				touche = toucheClavier[this.couche + '+'];
			} else {
				touche = toucheClavier[this.couche];
			}
		} else {
			touche = toucheClavier[this.couche];
		}

		touche = touche.replace(/<espace-insecable><\/espace-insecable>/g, ' ');
		touche = touche.replace(/Alt<br><span class='tap'>Alt ↹<\/span>/g, '');
		this.envoiTouche_ReplacerCurseur(touche);
	}

	envoiTouche_ReplacerCurseur(touche) {
		// Récupérer la position du curseur dans la this.textarea
		var positionCurseur = this.textarea.selectionStart;

		// Récupérer le texte avant et après la position du curseur
		var texteAvantCurseur = this.textarea.value.substring(0, positionCurseur);
		var texteApresCurseur = this.textarea.value.substring(positionCurseur);

		if (touche === '◌̂') {
			this.circonflexe = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === '◌̈') {
			this.trema = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === 'ᵉ') {
			this.e = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === 'ᵢ') {
			this.i = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === 'ℝ') {
			this.R = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === 'à') {
			this.a_grave = true;
		}
		if (touche === ',') {
			this.virgule = true;
		}

		// Concaténer les trois parties pour obtenir le contenu HTML mis à jour
		let nouvellePositionCurseur;
		if (touche === 'Backspace') {
			this.textarea.value = texteAvantCurseur.substring(0, positionCurseur - 1) + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur - 1;
		} else if (touche === 'Ctrl-Backspace') {
			let texteAvantSuppression = texteAvantCurseur;
			let texteApresSuppression = texteAvantCurseur.replace(/\s*\S*$/, '');
			this.textarea.value = texteApresSuppression + texteApresCurseur;
			let caracteresSupprimes = texteAvantSuppression.length - texteApresSuppression.length;
			nouvellePositionCurseur = positionCurseur - caracteresSupprimes;
		} else if (touche === 'Ctrl-Delete') {
			let texteAvantSuppression = texteApresCurseur;
			let texteApresSuppression = texteApresCurseur.replace(/^\S+\s*/, '');
			this.textarea.value = texteAvantCurseur + texteApresSuppression;
			let caracteresSupprimes = texteAvantSuppression.length - texteApresSuppression.length;
			nouvellePositionCurseur = positionCurseur;
		} else if (touche === 'Delete') {
			console.log('Delete');
			this.textarea.value =
				texteAvantCurseur + texteApresCurseur.substring(1, texteApresCurseur.length);
			nouvellePositionCurseur = positionCurseur;
		} else if (touche === 'Enter') {
			this.textarea.value = texteAvantCurseur + '\n' + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur + 1;
		} else if (touche === 'Tab') {
			this.textarea.value = texteAvantCurseur + '\t' + texteApresCurseur;
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

				this.textarea.value =
					texteAvantCurseur.split(' ').slice(0, -1).join(' ') +
					' ' +
					remplacement +
					texteApresCurseur;
				nouvellePositionCurseur = positionCurseur + remplacement.length;
			} else {
				let toucheRepetee = texteAvantCurseur.slice(-1);
				this.textarea.value = texteAvantCurseur + toucheRepetee + texteApresCurseur;
				nouvellePositionCurseur = positionCurseur + 1;
			}
		} else {
			this.textarea.value = texteAvantCurseur + touche + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur + touche.length;
		}

		/* Évite le SFB NNU par exemple qui est N★U normalement, mais se fait N★Ê */
		/* Sauf pour le R, car "arrêt" existe en français */
		this.textarea.value = this.textarea.value.replace(/([^\Wr]){2}ê/g, '$1$1u');

		/* Apostrophe droite en typographique */
		this.textarea.value = this.textarea.value.replace(/([cdjlmnst])'/gi, '$1’');

		/* Correction de SFBs avec la touche È */
		this.textarea.value = this.textarea.value
			.replace(/èo/g, 'oe')
			.replace(/èe/g, 'eo')
			.replace(/è./g, 'u.')
			.replace(/è,/g, 'u,');

		/* Nouveaux roulements */
		this.textarea.value = this.textarea.value
			.replace(/yè/g, 'éi')
			.replace(/èy/g, 'ié')
			.replace(/gx/g, 'gt')
			.replace(/hc/g, 'wh');
		this.textarea.value = this.textarea.value.replace(/êé/g, 'aî');
		({ nouveauTexte: this.textarea.value, nouvellePositionCurseur } = remplacerEtAjuster(
			this.textarea.value,
			/éê/g,
			'â',
			nouvellePositionCurseur
		));
		({ nouveauTexte: this.textarea.value, nouvellePositionCurseur } = remplacerEtAjuster(
			this.textarea.value,
			/p'/g,
			'qu’',
			nouvellePositionCurseur
		));

		this.textarea.setSelectionRange(nouvellePositionCurseur, nouvellePositionCurseur);
	}

	presserToucheClavier(touche) {
		// Nettoyage des touches actives
		let emplacement = document.getElementById('clavier_' + this.id);
		const touchesActives = emplacement.querySelectorAll('.touche-active');
		[].forEach.call(touchesActives, function (el) {
			if (el.dataset.type !== 'special') {
				el.classList.remove('touche-active');
			}
		});
		emplacement
			.querySelector("bloc-touche[data-touche='" + touche + "']")
			.classList.add('touche-active');
	}
}

function remplacerEtAjuster(texte, regex, remplacement, positionCurseur) {
	// Compte les occurrences dev par exemple, "p'", car on remplaçe deux lettres par trois, il faut donc changer la position du curseur
	let count = (texte.match(regex) || []).length;
	return {
		nouveauTexte: texte.replace(regex, remplacement),
		nouvellePositionCurseur: positionCurseur + count * (remplacement.length - regex.source.length)
	};
}
