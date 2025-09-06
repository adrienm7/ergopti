import * as stores_infos from '$lib/stores_infos.js';
import { getKeyboardData } from '$lib/keyboard/getKeyboardData.js';

import characterFrequencies from '$lib/keyboard/characterFrequencies.json';
// Create the "max" and "min" keys containing the maximum value among the frequencies (the frequency of E) and the minimum value
characterFrequencies.max = Math.max(...Object.values(characterFrequencies));
characterFrequencies.min = Math.min(...Object.values(characterFrequencies));
// Apply a logarithmic scale to smooth differences between very common and very rare characters
function logarithmicTransformation(x, k) {
	return Math.log(1 + k * x) / Math.log(1 + k);
}

export class Keyboard {
	constructor(id) {
		this.id = id;

		// Subscribe to the store to always have the version currently selected
		stores_infos['version'].subscribe((value) => {
			this.version = value;
		});
		stores_infos['data_disposition'].subscribe((value) => {
			this.data_disposition = value;
			this.keyboardUpdate();
		});

		this.data_clavier = stores_infos[this.id]; // Enables modification of the keyboard data in the store

		// Subscribe to the store to receive real-time updates of the keyboard data
		this.data_clavier.subscribe((value) => {
			this.keyboardInformation = value;
		});
	}

	getKeyboardLocation() {
		if (typeof document !== 'undefined') {
			let keyboardLocation = document.getElementById(`clavier_${this.id}`);
			if (keyboardLocation === null) {
				// Lève une exception si l'emplacement n'est pas défini
				throw new Error('Emplacement clavier introuvable');
			}
			return keyboardLocation;
		}
		// Lève une exception si le document n'est pas défini
		throw new Error('Document non défini');
	}

	keyboardUpdate() {
		// This code isn’t necessary anymore, and when activated it generates many useless requests, as all keyboards will request the same file:
		// if (this.data_disposition === undefined) {
		// 	this.data_disposition = getKeyboardData(this.version);
		// }
		this.keysUpdate();
		this.keyboardInformationUpdate();
		this.currentLayerModifiersKeyPress();
	}

	keysUpdate() {
		if (this.data_disposition === undefined) {
			return;
		}
		try {
			const keyboardLocation = this.getKeyboardLocation();
			for (let row = 1; row <= 7; row++) {
				for (let column = 0; column <= 15; column++) {
					// Récupération de ce qui doit être affiché sur la touche, selon que la géométrie est iso ou ergodox (deux listes de propriétés différentes)
					const newKey = this.data_disposition[this.keyboardInformation.type].find(
						(el) => el['row'] == row && el['column'] == column
					);

					const keyboardKey = this.cleanKey(keyboardLocation, row, column);

					if (newKey !== undefined) {
						const newKeyContent = this.data_disposition['keys'].find(
							(el) => el['key'] === newKey['key']
						);

						if (
							this.keyboardInformation.layer !== 'Visuel' &&
							(newKeyContent[this.keyboardInformation.layer] === '' ||
								newKeyContent[this.keyboardInformation.layer] === undefined)
						) {
							keyboardKey.innerHTML = '<div><div>'; /* Undefined key in the selected layer */
						} else {
							if (this.keyboardInformation.layer === 'Visuel') {
								if (newKeyContent['type'] === 'ponctuation') {
									if (newKey['key'] === '"') {
										// Cas particulier de la touche « " »
										keyboardKey.innerHTML =
											'<div>' +
											newKeyContent['Shift'] +
											'<br/>' +
											newKeyContent['Primary'] +
											'</div>';
									} else {
										// Toutes les autres touches "doubles"
										keyboardKey.innerHTML =
											'<div>' +
											newKeyContent['AltGr'] +
											'<br/>' +
											newKeyContent['Primary'] +
											'</div>';
										if (newKeyContent['Primary' + '+'] !== undefined && row < 6) {
											// Si la layer + existe ET n’est pas en thumb cluster
											keyboardKey.dataset['plus'] = 'oui';
										}
									}
								} else {
									// Cas où la touche n’est pas double
									if (this.keyboardInformation.plus === 'oui') {
										// Cas où la touche n’est pas double et + est activé
										if (newKeyContent['Primary' + '+'] !== undefined && row < 6) {
											// Si la layer + existe ET n’est pas en thumb cluster
											keyboardKey.innerHTML = '<div>' + newKeyContent['Primary' + '+'] + '</div>';
											keyboardKey.dataset['plus'] = 'oui';
										} else {
											keyboardKey.innerHTML = '<div>' + newKeyContent['Primary'] + '</div>';
										}
									} else {
										keyboardKey.innerHTML = '<div>' + newKeyContent['Primary'] + '</div>';
									}
								}
							} else {
								// Toutes les couches autres que "Visuel"
								if (this.keyboardInformation.plus === 'oui') {
									if (
										newKeyContent[this.keyboardInformation.layer + '+'] !== undefined &&
										(row < 6 || newKey['key'] === 'Space')
									) {
										// Si la layer + existe et n’est pas en thumb cluster. Sur le thumb cluster, on affiche seulement le tap hold en space et pas en Alt ou Ctrl
										keyboardKey.innerHTML =
											'<div>' + newKeyContent[this.keyboardInformation.layer + '+'] + '</div>';
										keyboardKey.dataset.plus = 'oui';
									} else {
										keyboardKey.innerHTML =
											'<div>' + newKeyContent[this.keyboardInformation.layer] + '</div>';
									}
								} else {
									keyboardKey.innerHTML =
										'<div>' + newKeyContent[this.keyboardInformation.layer] + '</div>';
								}
							}
						}

						// Functionality to switch layer by clicking on a key
						// We can only have it working 100% correctly on the latest version, as some tap-holds changed
						if (
							this.keyboardInformation['controls'] === 'oui'
							// && this.version == '2.2'
						) {
							keyboardKey.addEventListener(
								'click',
								() => {
									this.layerSwitch(keyboardKey);
								},
								{ passive: true }
							);
						}

						this.postProcessingKeys(keyboardKey, newKey);
						this.setKeyProperties(keyboardKey, column, newKeyContent, newKey);
					}
				}
			}
		} catch (error) {
			return;
		}
	}

	cleanKey(keyboardLocation, row, column) {
		// Suppression des event listeners sur la touche
		const keyboardKey0 = keyboardLocation.querySelector(
			"keyboard-key[data-row='" + row + "'][data-column='" + column + "']"
		);
		let keyboardKey = keyboardKey0.cloneNode(true);
		keyboardKey0.parentNode.replaceChild(keyboardKey, keyboardKey0);

		// Nettoyage des attributs de la touche
		const attributes = keyboardKey.getAttributeNames();
		const attributesToKeep = ['data-row', 'data-column'];
		attributes.forEach((attribute) => {
			if (attribute.startsWith('data-') && !attributesToKeep.includes(attribute)) {
				keyboardKey.removeAttribute(attribute);
			}
		});
		// Suppression du contenu de la touche
		keyboardKey.dataset['key'] = '';
		keyboardKey.dataset['plus'] = 'non';
		keyboardKey.classList.remove('pressed-key'); // Suppression de la classe css pour les touches pressées

		return keyboardLocation.querySelector(
			"keyboard-key[data-row='" + row + "'][data-column='" + column + "']"
		);
	}

	setKeyProperties(keyboardKey, column, newKeyContent, newKey) {
		// On ajoute des this.keyboardInformation dans les data attributes de la touche
		// This enables automatic styling of key groups with CSS
		keyboardKey.dataset['key'] = newKey['key'];
		keyboardKey.dataset['column'] = column;
		keyboardKey.dataset['finger'] = newKey['finger'];
		keyboardKey.dataset['hand'] = newKey['hand'];
		keyboardKey.dataset['type'] = newKeyContent['type'];
		keyboardKey.dataset['style'] = '';

		if (
			this.keyboardInformation.layer === 'Visuel' &&
			newKeyContent['Primary' + '-style'] !== undefined &&
			newKeyContent['Primary' + '-style'] !== ''
		) {
			keyboardKey.dataset['style'] = newKeyContent['Primary' + '-style'];
		} else {
			if (
				this.keyboardInformation.plus === 'oui' &&
				newKeyContent[this.keyboardInformation.layer + '+' + '-style'] !== undefined &&
				newKeyContent[this.keyboardInformation.layer + '+' + '-style'] !== ''
			) {
				keyboardKey.dataset['style'] =
					newKeyContent[this.keyboardInformation.layer + '+' + '-style'];
			} else if (
				newKeyContent[this.keyboardInformation.layer + '-style'] !== undefined &&
				newKeyContent[this.keyboardInformation.layer + '-style'] !== ''
			) {
				keyboardKey.dataset['style'] = newKeyContent[this.keyboardInformation.layer + '-style'];
			}
		}

		keyboardKey.style.setProperty('--size', newKey['size']);

		let frequency = characterFrequencies[newKeyContent[this.keyboardInformation.layer]];
		keyboardKey.style.setProperty('--frequency', frequency);

		let frequency_normalized = // Between 0 et 1 avec 1 pour la lettre la plus fréquente
			(characterFrequencies[newKeyContent[this.keyboardInformation.layer]] -
				characterFrequencies['min']) /
			(characterFrequencies['max'] - characterFrequencies['min']);
		keyboardKey.style.setProperty(
			'--frequency_normalized',
			logarithmicTransformation(frequency_normalized, 40)
		);
	}

	postProcessingKeys(keyboardKey, newKey) {
		// Modification on the Space key to also show the name of the Layout
		let plus = this.keyboardInformation.plus === 'oui' ? ' <span class="glow">+</span>' : '';
		if (
			this.keyboardInformation.layer === 'Visuel' &&
			this.keyboardInformation.type === 'iso' &&
			newKey['key'] === 'Space'
		) {
			keyboardKey.innerHTML = '<div>' + this.data_disposition['name'] + plus + '</div>';
		}

		// Make the ★ key glow
		if (
			this.keyboardInformation.layer === 'Visuel' &&
			this.keyboardInformation.plus === 'oui' &&
			newKey['key'] === 'magique'
		) {
			keyboardKey.innerHTML = '<div><span class="glow" style = "position:initial">★</span></div>';
		}

		// For ISO, Layer is on LAlt instead of Space
		if (
			this.keyboardInformation.type === 'iso' &&
			this.keyboardInformation.layer === 'Layer' &&
			this.keyboardInformation.plus === 'oui' &&
			newKey['key'] === 'LAlt'
		) {
			keyboardKey.innerHTML = '<div>Layer</div>';
		}
		// For Ergodox, Layer is on Space instead of LAlt
		if (
			this.keyboardInformation.type === 'ergodox' &&
			this.keyboardInformation.layer === 'Layer' &&
			this.keyboardInformation.plus === 'oui' &&
			newKey['key'] === 'Space'
		) {
			keyboardKey.innerHTML = '<div>Layer</div>';
		}
	}

	layerSwitch(pressedKey) {
		let pressedKeyName = pressedKey.dataset['key'];
		const currentLayer = this.keyboardInformation.layer;
		const plus = this.keyboardInformation.plus === 'oui';
		const type = this.keyboardInformation.type;
		let newLayer = currentLayer;

		if (
			pressedKeyName === 'LShift' ||
			pressedKeyName === 'RShift' ||
			// RCtrl becomes Shift in Ergopti+
			(pressedKeyName === 'RCtrl' && plus)
		) {
			pressedKeyName = 'Shift';
		}

		const mappings = {
			Shift: {
				Shift: 'Visuel',
				AltGr: 'ShiftAltGr',
				ShiftAltGr: 'AltGr',
				CirconflexeShift: 'Circonflexe',
				Circonflexe: 'CirconflexeShift',
				TremaShift: 'Trema',
				Trema: 'TremaShift',
				GreekShift: 'Greek',
				Greek: 'GreekShift',
				À: 'Shift',
				',': 'Shift',
				Exposant: 'Shift',
				Indice: 'Shift',
				default: 'Shift'
			},
			RAlt: {
				AltGr: 'Visuel',
				Shift: 'ShiftAltGr',
				ShiftAltGr: 'Shift',
				default: 'AltGr'
			},
			LCtrl: {
				Ctrl: 'Visuel',
				default: 'Ctrl'
			},
			RCtrl: {
				Ctrl: 'Visuel',
				default: 'Ctrl'
			}
		};

		if (pressedKeyName in mappings) {
			const rules = mappings[pressedKeyName];
			if (rules) {
				newLayer = rules[currentLayer] || rules.default;
			}
		}

		// Dead Keys on direct access
		if (['Visuel', 'Primary'].includes(currentLayer)) {
			if (pressedKeyName === 'Circonflexe') {
				newLayer = 'Circonflexe';
			}

			if (pressedKeyName === 'Trema') {
				newLayer = 'Trema';
			}
		}

		// Dead Keys on Shift + AltGr
		if (currentLayer === 'ShiftAltGr') {
			if (pressedKeyName === 'e') {
				newLayer = 'Exposant';
			}

			if (pressedKeyName === 'u') {
				newLayer = 'Greek';
			}

			if (pressedKeyName === 't') {
				newLayer = 'Trema';
			}

			if (pressedKeyName === 'r') {
				newLayer = 'R';
			}

			if (pressedKeyName === 'ê') {
				newLayer = 'Circonflexe';
			}

			if (pressedKeyName === 'à') {
				newLayer = 'Indice';
			}
		}

		if (plus) {
			// Comma
			if (pressedKeyName === ',') {
				if (['Visuel', 'Primary', 'Shift'].includes(currentLayer)) {
					newLayer = ',';
				}
			}

			// À
			if (pressedKeyName === 'à') {
				if (['Visuel', 'Primary', 'Shift'].includes(currentLayer)) {
					newLayer = 'À';
				} else if (currentLayer === 'À') {
					newLayer = 'Visuel';
				}
			}

			// CapsLock
			if (pressedKeyName === 'CapsLock') {
				if (currentLayer !== 'Ctrl') {
					newLayer = 'Ctrl';
				} else {
					newLayer = 'Visuel';
				}
			}

			// Space
			if (pressedKeyName === 'Space' && type === 'ergodox') {
				if (['Visuel', 'Primary'].includes(currentLayer)) {
					newLayer = 'Layer';
				} else if (currentLayer === 'Layer') {
					newLayer = 'Visuel';
				}
			}

			// LAlt
			if (pressedKeyName === 'LAlt' && type === 'iso') {
				if (currentLayer === 'Layer') {
					newLayer = 'Visuel';
				} else {
					newLayer = 'Layer';
				}
			}
		}

		// At this point, the new layer has been determined
		// Most keys pressed won’t change the layer, as only some modifiers and deadkeys defined in this code do
		// Then, the layer variable is updated, and finally the keyboard
		if (newLayer !== currentLayer) {
			this.data_clavier.update((currentData) => {
				currentData['layer'] = newLayer;
				return currentData;
			});
			this.keyboardUpdate();
		}
	}

	keyboardInformationUpdate() {
		try {
			const keyboardLocation = this.getKeyboardLocation();
			keyboardLocation.dataset['type'] = this.keyboardInformation.type;
			keyboardLocation.dataset['layer'] = this.keyboardInformation.layer;
			keyboardLocation.dataset['plus'] = this.keyboardInformation.plus;
			keyboardLocation.dataset['couleur'] = this.keyboardInformation.couleur;
		} catch (error) {
			return;
		}
	}

	currentLayerModifiersKeyPress() {
		try {
			const keyboardLocation = this.getKeyboardLocation();
			const layer = this.keyboardInformation.layer;
			const plus = this.keyboardInformation.plus === 'oui';
			const type = this.keyboardInformation.type;

			const keys = {
				LShift: keyboardLocation.querySelector("[data-key='LShift']"),
				RShift: keyboardLocation.querySelector("[data-key='RShift']"),
				LCtrl: keyboardLocation.querySelector("[data-key='LCtrl']"),
				RCtrl: keyboardLocation.querySelector("[data-key='RCtrl']"),
				LAlt: keyboardLocation.querySelector("[data-key='LAlt']"),
				RAlt: keyboardLocation.querySelector("[data-key='RAlt']"),
				CapsLock: keyboardLocation.querySelector("[data-key='CapsLock']"),
				Space: keyboardLocation.querySelector("[data-key='Space']")
			};

			// Utility function to activate a key if it exists
			function activate(key) {
				if (keys[key] !== null) {
					keys[key].classList.add('pressed-key');
				}
			}

			// Mapping of keys to activate for each layer
			const layerMap = {
				Shift: ['LShift', 'RShift'],
				Ctrl: ['LCtrl'], // RCtrl is a special case
				AltGr: ['RAlt'],
				ShiftAltGr: ['LShift', 'RShift', 'RAlt'],
				CirconflexeShift: ['LShift', 'RShift'],
				TremaShift: ['LShift', 'RShift'],
				GreekShift: ['LShift', 'RShift']
			};

			// Activate keys for the current layer
			const keysToActivate = layerMap[layer];
			if (keysToActivate !== undefined) {
				for (const key of keysToActivate) {
					activate(key);
				}
			}

			// Special cases
			if (
				plus &&
				type === 'iso' &&
				['Shift', 'ShiftAltGr', 'CirconflexeShift', 'TremaShift', 'GreekShift'].includes(layer)
			) {
				activate('RCtrl');
			}

			if (layer === 'Ctrl') {
				if (plus) {
					activate('CapsLock');
				} else {
					activate('RCtrl');
				}
			}

			if (layer === 'Layer') {
				if (type === 'iso') {
					activate('LAlt');
				}
				if (type === 'ergodox') {
					activate('Space');
				}
			}
		} catch (error) {
			return;
		}
	}

	typeText(text, speed, makePreviousKeysDisappear) {
		const keyboardLocation = this.getKeyboardLocation();

		// Clear previously pressed keys
		const pressedKeys = keyboardLocation.querySelectorAll('.pressed-key');
		pressedKeys.forEach(function (el) {
			el.classList.remove('pressed-key');
		});

		function writeNext(i) {
			if (i >= text.length) return; // stop condition

			const nextLetter = text.charAt(i);
			const nextKey = keyboardLocation.querySelector("keyboard-key[data-key='" + nextLetter + "']");

			if (nextKey) {
				nextKey.classList.add('pressed-key');
			}

			if (makePreviousKeysDisappear && i > 0) {
				const previousLetter = text.charAt(i - 1);
				const previousKey = keyboardLocation.querySelector(
					"keyboard-key[data-key='" + previousLetter + "']"
				);
				if (previousKey) {
					previousKey.classList.remove('pressed-key');
				}
			}

			setTimeout(function () {
				writeNext(i + 1);
			}, speed);
		}

		writeNext(0);
	}
}
