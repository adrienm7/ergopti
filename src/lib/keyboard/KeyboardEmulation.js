import { Keyboard } from '$lib/keyboard/Keyboard.js';
import remplacements from '$lib/keyboard/magicReplacements.json';

export class KeyboardEmulation extends Keyboard {
	constructor(id) {
		super(id);
		this.layer = 'Primary'; // Default layer

		this.shift = false;
		this.alt = false;
		this.altgr = false;
		this.control = false;
		this.circonflexe = false;
		this.trema = false;
		this.exposant = false;
		this.indice = false;
		this.R = false;
		this.a_grave = false;
		this.comma = false;

		// The scope of "this" is changed in the text input otherwise, and this.layoutData becomes undefined. This prevents this problem
		this.emulateKey = this.emulateKey.bind(this);
		this.releaseModifieurs = this.releaseModifieurs.bind(this);
	}

	emulateKey(event) {
		const modifieursActive = this.determineActiveModifieurs(event); // Activate potential modifieurs
		this.layerUpdate();
		if (modifieursActive) {
			// If a modifieur has been pressed, no key to send so we exit the function
			return;
		}

		// Do not intercept shortcuts with Ctrl
		if (this.control && !this.altgr) {
			// Note: when this.altgr is active, Ctrl is also active, hence the "&& !this.altgr"
			return;
		}
		/* Ctrl + touche renvoie Ctrl + émulation de touche */
		/* Ne fonctionne pas actuellement */
		// if (this.control & !this.altgr) {
		// 	// Attention, quand this.altgr est activé, Ctrl l’est aussi, d’où le &
		// 	console.log(keyContent.touche);
		// 	// Crée un nouvel événement clavier pour "Ctrl + lettre".
		// 	const ctrlEvent = new KeyboardEvent('keydown', {
		// 		key: keyContent.touche,
		// 		ctrlKey: true, // Spécifie que la touche Ctrl est enfoncée
		// 		bubbles: true,
		// 		cancelable: true
		// 	});
		// 	// Envoie l'événement au même input
		// 	this.textarea.dispatchEvent(ctrlEvent);
		// 	return true;
		// }

		// If a key other than a modifier has been pressed
		const keyCodePressed = event.code;
		const keyIdentifier = this.layoutData[this.keyboardInformation.type].find(
			(el) => el['code'] === keyCodePressed
		);
		this.pressKey(keyIdentifier['key']); // Press the key location on the visual keyboard layout

		if (keyIdentifier !== undefined) {
			event.preventDefault(); // Don’t send the key defined in the computer keyboard layout
			const keyContent = this.layoutData['keys'].find((el) => el['key'] === keyIdentifier['key']);
			this.determineKeyToSend(keyContent);
		}
	}

	determineActiveModifieurs(event) {
		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			this.altgr = true;
			return true;
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'oui')
		) {
			this.shift = true;
			return true;
		} else if (event.code === 'AltLeft') {
			this.alt = true;
			return true;
		} else if (
			event.code === 'ControlLeft' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'non')
		) {
			this.control = true;
			return true;
		}
		return false;
	}

	layerUpdate() {
		// Determine the new value of the layer
		if (this.altgr && this.shift) {
			this.layer = 'ShiftAltGr';
		} else if (this.altgr) {
			this.layer = 'AltGr';
		} else if (this.shift) {
			this.layer = 'Shift';
		} else if (this.control) {
			this.layer = 'Ctrl';
		} else if (this.circonflexe) {
			this.layer = 'Circonflexe';
		} else if (this.trema) {
			this.layer = 'Trema';
		} else if (this.exposant) {
			this.layer = 'Exposant';
		} else if (this.indice) {
			this.layer = 'Indice';
		} else if (this.R) {
			this.layer = 'R';
		} else if (this.a_grave) {
			this.layer = 'À';
		} else if (this.comma) {
			this.layer = ',';
		} else {
			this.layer = 'Primary';
		}

		// Update the layer in the store
		this.data_clavier.update((currentData) => {
			currentData['layer'] = this.layer;
			return currentData;
		});
		this.keyboardUpdate();
	}

	pressKey(key) {
		// Clean other pressed keys
		let emplacement = document.getElementById('clavier_' + this.id);
		const pressedKeys = emplacement.querySelectorAll('.pressed-key');
		[].forEach.call(pressedKeys, function (el) {
			if (el.dataset.type !== 'special') {
				el.classList.remove('pressed-key');
			}
		});

		// Press the key
		emplacement.querySelector("keyboard-key[data-key='" + key + "']").classList.add('pressed-key');
	}

	determineKeyToSend(keyContent) {
		const keyPressed = keyContent['key'];

		if (this.alt && this.keyboardInformation['plus'] === 'oui') {
			this.sendKey('BackSpace');
		} else if (
			this.altgr &&
			keyPressed === 'CapsLock' &&
			this.keyboardInformation['plus'] === 'oui'
		) {
			this.sendKey('Ctrl-Delete');
		} else if (
			this.control &&
			(keyPressed === 'BackSpace' ||
				(this.keyboardInformation['plus'] === 'oui' && keyPressed === 'LAlt'))
		) {
			this.sendKey('Ctrl-BackSpace');
		} else if (
			keyPressed === 'Delete' ||
			(this.keyboardInformation['plus'] === 'oui' && this.shift && keyPressed === 'LAlt')
		) {
			this.sendKey('Delete');
		} else if (
			keyPressed === 'BackSpace' ||
			(keyPressed === 'CapsLock' && this.keyboardInformation['plus'] === 'oui')
		) {
			this.sendKey('BackSpace');
		} else if (keyPressed === 'Enter') {
			this.sendKey('Enter');
		} else if (this.exposant) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				touche = keyContent['Exposant'];
			}
			this.exposant = false;
			this.sendKey(touche);
		} else if (this.indice) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				touche = keyContent['Indice'];
			}
			this.indice = false;
			this.sendKey(touche);
		} else if (this.R) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				touche = keyContent['R'];
			}
			this.R = false;
			this.sendKey(touche);
		} else if (this.circonflexe) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				touche = keyContent['^'];
			}
			this.circonflexe = false;
			this.sendKey(touche);
		} else if (this.trema) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				touche = keyContent['Trema'];
			}
			this.trema = false;
			this.sendKey(touche);
		} else if (this.a_grave) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				// On supprime le à avant de taper le raccourci de la layer À
				this.textarea.value = this.textarea.value.slice(0, -1);
				touche = keyContent['À'];
			}
			this.a_grave = false;
			this.sendKey(touche);
		} else if (this.comma) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				// On supprime le , avant de taper le raccourci de la layer Virgule
				this.textarea.value = this.textarea.value.slice(0, -1);
				touche = keyContent[','];
			}
			this.comma = false;
			this.sendKey(touche);
		} else {
			let touche = '';
			if (this.keyboardInformation['plus'] === 'oui') {
				if (keyContent[this.layer + '+'] !== undefined) {
					touche = keyContent[this.layer + '+'];
				} else {
					touche = keyContent[this.layer];
				}
			} else {
				touche = keyContent[this.layer];
			}
			this.sendKey(touche);
		}
	}

	sendKey(touche) {
		touche = touche.replace(/<espace-insecable><\/espace-insecable>/g, ' ');
		touche = touche.replace(/<tap-hold>.*<\/tap-hold>/g, '');
		touche = touche.replace('␣', ' ');

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
			this.exposant = true;
			touche = ''; /* Ne pas afficher la touche morte */
		}
		if (touche === 'ᵢ') {
			this.indice = true;
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
			this.comma = true;
		}

		// Concaténer les trois parties pour obtenir le contenu HTML mis à jour
		let nouvellePositionCurseur;
		if (touche === 'BackSpace') {
			this.textarea.value = texteAvantCurseur.substring(0, positionCurseur - 1) + texteApresCurseur;
			nouvellePositionCurseur = positionCurseur - 1;
		} else if (touche === 'Ctrl-BackSpace') {
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
			let mot = texteAvantCurseur.split(/\s+/).slice(-1)[0];

			if (mot.toLowerCase() in remplacements) {
				let remplacement = remplacements[mot.toLowerCase()];

				if (mot === mot.toUpperCase() && mot.length > 1) {
					remplacement = remplacement.toUpperCase();
				} else if (mot === mot.charAt(0).toUpperCase() + mot.slice(1).toLowerCase()) {
					remplacement = remplacement.charAt(0).toUpperCase() + remplacement.slice(1).toLowerCase();
				} else {
					remplacement = remplacement.toLowerCase();
				}

				let regex = /(\s*)(\S+)$/;
				let match = texteAvantCurseur.match(regex);
				let prefix = match ? match[1] : '';

				this.textarea.value =
					texteAvantCurseur.replace(regex, prefix + remplacement) + texteApresCurseur;
				nouvellePositionCurseur = positionCurseur + remplacement.length;
			} else {
				this.textarea.value = texteAvantCurseur + texteAvantCurseur.slice(-1) + texteApresCurseur;
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
			.replace(/è\./g, 'u.')
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

	releaseModifieurs(event) {
		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			this.altgr = false;
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'oui')
		) {
			this.shift = false;
		} else if (event.code === 'AltLeft') {
			this.alt = false;
		} else if (
			event.code === 'ControlLeft' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'non')
		) {
			this.control = false;
		}
		this.layerUpdate();
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
