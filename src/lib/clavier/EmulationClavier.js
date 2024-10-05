import { Clavier } from '$lib/clavier/Clavier.js';
export class EmulationClavier extends Clavier {
	constructor(id) {
		super(id);
		this.shift = false;
		this.altgr = false;
		this.control = false;
		this.R = false;
		this.a_grave = false;
		this.virgule = false;
		this.couche = 'Primary'; // Couche par défaut
		// La portée de this est modifiée dans le textinput sinon et this.data est undefined
		this.emulationClavier = this.emulationClavier.bind(this);
		this.relacherModificateurs = this.relacherModificateurs.bind(this);
	}

	activationModificateur(event) {
		if (event.code === 'AltRight') {
			this.altgr = true;
			return true;
		}
		if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			this.shift = true;
			return true;
		}
		if (event.code === 'ControlLeft' || event.code === 'ControlRight') {
			this.control = true;
			return true;
		}
		return false;
	}

	setCouche() {
		// Déterminer la valeur de `couche`
		if (this.altgr && this.shift) {
			this.couche = 'ShiftAltGr';
		} else if (this.altgr) {
			this.couche = 'AltGr';
		} else if (this.shift) {
			this.couche = 'Shift';
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
		this.activationModificateur(event); // Activation des éventuelles touches modificatrices
		this.setCouche();

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
			if (keyPressed === 'CapsLock' || keyPressed === 'Backspace') {
				this.envoiTouche_ReplacerCurseur('Backspace');
				return true;
			}
			if (keyPressed === 'Enter') {
				this.envoiTouche_ReplacerCurseur('Enter');
				// } else if (keyPressed === 'AltRight' && this.infos_clavier['plus'] === 'oui') {
				// 	this.envoiTouche_ReplacerCurseur('Tab');
				// } else if (keyPressed === 'ControlRight' && this.infos_clavier['plus'] === 'oui') {
				// 	this.envoiTouche_ReplacerCurseur('a');
			} else if (this.R) {
				if (keyPressed === 'Space') {
					touche = ' ';
				} else {
					// On supprime le R avant de taper le raccourci de la couche R
					this.textarea.value = this.textarea.value.slice(0, -1);
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

		if (touche === 'ℝ') {
			this.R = true;
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
		/* Convertir les touches mortes avec la voyelle suivante */
		this.textarea.value = this.textarea.value
			.replace(/◌̂a/g, 'â')
			.replace(/◌̂e/g, 'ê')
			.replace(/◌̂i/g, 'î')
			.replace(/◌̂o/g, 'ô')
			.replace(/◌̂u/g, 'û')
			.replace(/◌̂A/g, 'Â')
			.replace(/◌̂E/g, 'Ê')
			.replace(/◌̂I/g, 'Î')
			.replace(/◌̂O/g, 'Ô')
			.replace(/◌̂U/g, 'Û');
		this.textarea.value = this.textarea.value
			.replace(/◌̈a/g, 'ä')
			.replace(/◌̈e/g, 'ë')
			.replace(/◌̈i/g, 'ï')
			.replace(/◌̈o/g, 'ö')
			.replace(/◌̈u/g, 'ü')
			.replace(/◌̈A/g, 'Ä')
			.replace(/◌̈E/g, 'Ë')
			.replace(/◌̈I/g, 'Ï')
			.replace(/◌̈O/g, 'Ö')
			.replace(/◌̈U/g, 'Ü');
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

	relacherModificateurs(event) {
		if (event.code === 'AltRight') {
			this.altgr = false;
		} else if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			this.shift = false;
		} else if (event.code === 'ControlLeft' || event.code === 'ControlRight') {
			this.control = false;
		}
		this.setCouche();
		this.majClavier();
	}
}

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
