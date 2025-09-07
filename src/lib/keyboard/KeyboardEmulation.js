import { Keyboard } from '$lib/keyboard/Keyboard.js';
import remplacements from '$lib/keyboard/magicReplacements.json';

export class KeyboardEmulation extends Keyboard {
	constructor(id) {
		super(id);
		this['layer'] = 'Primary'; // Default layer

		this['Shift'] = false;
		this['Alt'] = false;
		this['AltGr'] = false;
		this['Ctrl'] = false;
		this['Circonflexe'] = false;
		this['Trema'] = false;
		this['Exposant'] = false;
		this['Indice'] = false;
		this['R'] = false;
		this['À'] = false;
		this[','] = false;

		// The scope of "this" is changed in the text input otherwise, and this.layoutData becomes undefined. This prevents this problem
		this.emulateKey = this.emulateKey.bind(this);
		this.releaseKey = this.releaseKey.bind(this);
	}

	layerUpdate() {
		// Determine the new value of the layer
		const priorities = [
			{ cond: this['AltGr'] && this['Shift'], value: 'ShiftAltGr' },
			{ cond: this['Circonflexe'] && this['Shift'], value: 'CirconflexeShift' },
			{ cond: this['Trema'] && this['Shift'], value: 'TremaShift' },
			{ cond: this['AltGr'], value: 'AltGr' },
			{ cond: this['Shift'], value: 'Shift' },
			{ cond: this['Ctrl'], value: 'Ctrl' },
			{ cond: this['Circonflexe'], value: 'Circonflexe' },
			{ cond: this['Trema'], value: 'Trema' },
			{ cond: this['Exposant'], value: 'Exposant' },
			{ cond: this['Indice'], value: 'Indice' },
			{ cond: this['R'], value: 'R' },
			{ cond: this['À'], value: 'À' },
			{ cond: this[','], value: ',' }
		];
		const match = priorities.find((p) => p.cond);
		this['layer'] = match ? match.value : 'Primary';

		// Update the layer in the store
		this.data_clavier.update((currentData) => {
			currentData['layer'] = this['layer'];
			return currentData;
		});
		this.keyboardUpdate();
	}

	emulateKey(event) {
		const activeModifier = this.determineActiveModifier(event); // Activate potential modifier
		if (activeModifier) {
			this[activeModifier] = true;
			this.layerUpdate();
			if (this.keyboardInformation['plus'] === 'oui' && activeModifier === 'Alt') {
				this.sendKey('BackSpace');
			}
			// If a modifier has been pressed, no key to send right now, so we exit the function
			// It is only on the next key pressed that isn’t a modifier that will give the result of this key on the new layer
			return;
		}

		// Do not intercept shortcuts with Ctrl
		if (this['Ctrl'] && !this['AltGr']) {
			// Note: when this["AltGr"] is active, Ctrl is also active, hence the "&& !this["AltGr"]"
			return;
		}
		/* Ctrl + touche renvoie Ctrl + émulation de touche */
		/* Ne fonctionne pas actuellement */
		// if (this["Ctrl"] & !this["AltGr"]) {
		// 	// Attention, quand this["AltGr"] est activé, Ctrl l’est aussi, d’où le &
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

			const activeDeadKey = this.determineActiveDeadKey(keyContent); // Activate potential dead key
			if (activeDeadKey) {
				this[activeDeadKey] = true;
				this.layerUpdate();
				return;
			}

			const { keyToSend, charactersToDelete } = this.determineKeyToSend(keyContent);
			this.sendKey(keyToSend, charactersToDelete);
		}
	}

	determineActiveModifier(event) {
		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			return 'AltGr';
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'oui')
		) {
			return 'Shift';
		} else if (event.code === 'AltLeft') {
			return 'Alt';
		} else if (
			event.code === 'ControlLeft' ||
			(event.code === 'ControlRight' && this.keyboardInformation['plus'] === 'non')
		) {
			return 'Ctrl';
		}
		return false;
	}

	determineActiveDeadKey(keyContent) {
		const keyPressed = this.getKeyToSend(keyContent);
		const deadKeys = {
			'◌̂': 'Circonflexe',
			'◌̈': 'Trema',
			ᵉ: 'Exposant',
			ᵢ: 'Indice',
			ℝ: 'R'
		};
		const ActiveDeadKey = deadKeys[keyPressed];
		if (ActiveDeadKey) {
			this[ActiveDeadKey] = true;
			return ActiveDeadKey;
		}
		return false;
	}

	pressKey(key) {
		// Clean other pressed keys
		let emplacement = document.getElementById('clavier_' + this['id']);
		const pressedKeys = emplacement.querySelectorAll('.pressed-key');
		[].forEach.call(pressedKeys, function (el) {
			if (el.dataset.type !== 'special') {
				el.classList.remove('pressed-key');
			}
		});

		// Press the key
		emplacement.querySelector("keyboard-key[data-key='" + key + "']").classList.add('pressed-key');
	}

	getKeyToSend(keyContent) {
		let keyToSend = '';
		if (this.keyboardInformation['plus'] === 'oui') {
			if (keyContent[this['layer'] + '+'] !== undefined) {
				keyToSend = keyContent[this['layer'] + '+'];
			} else {
				keyToSend = keyContent[this['layer']];
			}
		} else {
			keyToSend = keyContent[this['layer']];
		}
		return keyToSend;
	}

	determineKeyToSend(keyContent) {
		const keyPressed = keyContent['key'];
		let keyToSend = this.getKeyToSend(keyContent);
		let charactersToDelete = 0;

		// Vérifier si l’une des touches mortes doit être désactivée
		for (const k of ['Circonflexe', 'Trema', 'Exposant', 'Indice', 'R']) {
			if (this[k]) {
				this[k] = false;
				this.layerUpdate();
				break;
			}
		}

		if (this['layer'] == 'À') {
			charactersToDelete = 1; // Delete the previously typed "à" before sending the result on the layer À
			this['À'] = false;
			this.layerUpdate();
		} else if (this['layer'] == ',') {
			charactersToDelete = 1; // Delete the previously typed "," before sending the result on the layer ,
			this[','] = false;
			this.layerUpdate();
		} else if (keyPressed === 'Enter') {
			keyToSend = 'Enter';
		} else if (keyPressed === 'BackSpace') {
			keyToSend = 'BackSpace';
		} else if (
			this['Ctrl'] &&
			(keyPressed === 'BackSpace' ||
				(this.keyboardInformation['plus'] === 'oui' && keyPressed === 'LAlt'))
		) {
			keyToSend = 'Ctrl-BackSpace';
		} else if (
			keyPressed === 'Delete' ||
			(this.keyboardInformation['plus'] === 'oui' && this['Shift'] && keyPressed === 'LAlt')
		) {
			keyToSend = 'Delete';
		}
		return { keyToSend, charactersToDelete };
	}

	sendKey(touche, charactersToDelete = 0) {
		if (charactersToDelete > 0) {
			this.textarea.value = this.textarea.value.slice(0, -charactersToDelete);
		}
		touche = touche.replace(/<espace-insecable><\/espace-insecable>/g, ' ');
		touche = touche.replace(/<tap-hold>.*<\/tap-hold>/g, '');
		touche = touche.replace('␣', ' ');

		// Récupérer la position du curseur dans la this.textarea
		var positionCurseur = this.textarea.selectionStart;

		// Récupérer le texte avant et après la position du curseur
		var texteAvantCurseur = this.textarea.value.substring(0, positionCurseur);
		var texteApresCurseur = this.textarea.value.substring(positionCurseur);

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

		this.ergoptiPlusFeatures(nouvellePositionCurseur);

		this.textarea.setSelectionRange(nouvellePositionCurseur, nouvellePositionCurseur);
	}

	ergoptiPlusFeatures(nouvellePositionCurseur) {
		function remplacerEtAjuster(texte, regex, remplacement, positionCurseur) {
			// Compte les occurrences dev par exemple, "p'", car on remplaçe deux lettres par trois, il faut donc changer la position du curseur
			let count = (texte.match(regex) || []).length;
			return {
				nouveauTexte: texte.replace(regex, remplacement),
				nouvellePositionCurseur:
					positionCurseur + count * (remplacement.length - regex.source.length)
			};
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
			'ct',
			nouvellePositionCurseur
		));
	}

	releaseKey(event) {
		const modifier = this.determineActiveModifier(event);
		if (modifier) {
			this[modifier] = false;
			this.layerUpdate();
		}
	}
}
