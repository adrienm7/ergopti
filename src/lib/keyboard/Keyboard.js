import * as stores_infos from '$lib/stores_infos.js';

import characterFrequencies from '$lib/keyboard/characterFrequencies.json'; // Data coming from https://github.com/Nuclear-Squid/ergol/blob/main/corpus/en%2Bfr.json
// Create the "max" and "min" keys containing the maximum value among the frequencies (the frequency of E) and the minimum value
characterFrequencies.max = Math.max(...Object.values(characterFrequencies));
characterFrequencies.min = Math.min(...Object.values(characterFrequencies));
function logarithmicTransformation(value, scaleFactor) {
	// Apply a logarithmic scale to smooth differences between very common and very rare characters
	return Math.log(1 + scaleFactor * value) / Math.log(1 + scaleFactor);
}

export class Keyboard {
	constructor(id) {
		this.id = id;

		// Automatically update the keyboard as soon as layoutData changes
		stores_infos['layoutData'].subscribe((value) => {
			this.layoutData = value;
			this.updateKeyboard();
		});

		// Subscribe to the store to always have the version currently selected
		stores_infos['version'].subscribe((value) => {
			this.version = value;
		});

		// Enable modification of the keyboard data in the store
		this.data_clavier = stores_infos[this.id];

		// Subscribe to the store to receive real-time updates of the keyboard configuration
		this.data_clavier.subscribe((value) => {
			this.keyboardConfiguration = value;
		});
	}

	getKeyboardLocation() {
		if (typeof document !== 'undefined') {
			const idKeyboard = `clavier_${this.id}`;
			const keyboardLocation = document.getElementById(idKeyboard);
			if (keyboardLocation === null) {
				throw new Error(`Emplacement clavier ${idKeyboard} introuvable`);
			}
			return keyboardLocation;
		}
		throw new Error('Document non défini');
	}

	updateKeyboard() {
		if (this.layoutData !== undefined) {
			this.updateKeys();
			this.updateKeyboardConfiguration();
			this.pressCurrentLayerModifiers();
		}
	}

	updateKeys() {
		const keyboardLocation = this.getKeyboardLocation();

		for (let row = 1; row <= 7; row++) {
			for (let column = 0; column <= 15; column++) {
				const key = this.cleanKey(keyboardLocation, row, column);

				// Retrieve the id of the key at the specific location row x column
				// This id depends whether the layout is ISO or Ergodox (two different sets of properties)
				const keyIdentifier = this.layoutData[this.keyboardConfiguration.type].find(
					(el) => el['row'] == row && el['column'] == column
				);

				if (keyIdentifier !== undefined) {
					// Retrieve what should be displayed on the key of this id
					const keyContent = this.layoutData['keys'].find(
						(el) => el['key'] === keyIdentifier['key']
					);
					this.fillKey(key, keyContent, row);
					this.setKeyProperties(key, keyIdentifier, keyContent, column);
					this.postProcessingKey(key);

					// Functionality to switch layer by clicking on a key
					// It is only working 100% correctly on the latest version, as some tap-holds changed compared to previous versions
					// We still keep it enabled on old versions, as a 80%-working functionality is better than nothing
					if (
						this.keyboardConfiguration['controls'] === 'yes'
						// && this.version === '2.2'
					) {
						key.addEventListener(
							'click',
							() => {
								this.layerSwitch(key);
							},
							{ passive: true }
						);
					}
				}
			}
		}
	}

	cleanKey(keyboardLocation, row, column) {
		const keySelector = `keyboard-key[data-row='${row}'][data-column='${column}']`;

		// Event listeners cleaning
		const oldKey = keyboardLocation.querySelector(keySelector);
		let newKey = oldKey.cloneNode(true);
		oldKey.parentNode.replaceChild(newKey, oldKey);

		// Data attributes cleaning
		const keyAttributes = newKey.getAttributeNames();
		const keyAttributesToKeep = ['data-row', 'data-column'];
		keyAttributes.forEach((attribute) => {
			if (attribute.startsWith('data-') && !keyAttributesToKeep.includes(attribute)) {
				newKey.removeAttribute(attribute);
			}
		});
		newKey.dataset['key'] = '';

		// Key content and style cleaning
		newKey.innerHTML = '<div><div>';
		newKey.className = '';
		newKey.style = '';

		return newKey;
	}

	fillKey(key, keyContent, row) {
		if (
			this.keyboardConfiguration.layer !== 'Visuel' &&
			(keyContent[this.keyboardConfiguration.layer] === '' ||
				keyContent[this.keyboardConfiguration.layer] === undefined)
		) {
			/* Undefined key in the selected layer */
			return;
		}

		let keyDiv = key.querySelector('div');
		const plus = this.keyboardConfiguration.plus === 'yes';

		if (this.keyboardConfiguration.layer === 'Visuel') {
			if (keyContent['type'] === 'ponctuation') {
				// Every "double" keys of ponctuation
				keyDiv.innerHTML = `<output-altgr>${keyContent['AltGr']}</output-altgr><br/><output-primary>${keyContent['Primary']}</output-primary>`;
			} else {
				// All keys that aren’t "double"
				if (plus && keyContent['Primary' + '+'] !== undefined && row < 6) {
					// If the + layer exists AND the key isn’t on the thumb cluster
					keyDiv.innerHTML = keyContent['Primary' + '+'];
					key.dataset['plus'] = 'yes';
				} else {
					keyDiv.innerHTML = keyContent['Primary'];
				}
			}
		} else {
			// All layers other than "Visuel"
			if (plus && keyContent[this.keyboardConfiguration.layer + '+'] !== undefined && row < 6) {
				// If the + layer exists AND the key isn’t on the thumb cluster
				keyDiv.innerHTML = keyContent[this.keyboardConfiguration.layer + '+'];
				key.dataset.plus = 'yes';
			} else {
				keyDiv.innerHTML = keyContent[this.keyboardConfiguration.layer];
			}
		}
	}

	setKeyProperties(key, keyIdentifier, keyContent, column) {
		// On ajoute des this.keyboardConfiguration dans les data attributes de la touche
		// This enables automatic styling of key groups with CSS
		key.dataset['key'] = keyIdentifier['key'];
		key.dataset['finger'] = keyIdentifier['finger'];
		key.dataset['hand'] = keyIdentifier['hand'];
		key.dataset['type'] = keyContent['type'];
		key.dataset['column'] = column;

		if (
			this.keyboardConfiguration.layer === 'Visuel' &&
			keyContent['Primary' + '-style'] !== undefined
		) {
			key.dataset['style'] = keyContent['Primary' + '-style'];
		} else {
			if (
				this.keyboardConfiguration.plus === 'yes' &&
				keyContent[this.keyboardConfiguration.layer + '+' + '-style'] !== undefined
			) {
				key.dataset['style'] = keyContent[this.keyboardConfiguration.layer + '+' + '-style'];
			} else if (keyContent[this.keyboardConfiguration.layer + '-style'] !== undefined) {
				key.dataset['style'] = keyContent[this.keyboardConfiguration.layer + '-style'];
			}
		}

		key.style.setProperty('--size', keyIdentifier['size']);

		const frequency = characterFrequencies[keyContent[this.keyboardConfiguration.layer]];
		key.style.setProperty('--frequency', frequency);

		const frequency_normalized = // Between 0 et 1 with 1 for the most frequent key
			(characterFrequencies[keyContent[this.keyboardConfiguration.layer]] -
				characterFrequencies['min']) /
			(characterFrequencies['max'] - characterFrequencies['min']);
		key.style.setProperty(
			'--frequency_normalized',
			logarithmicTransformation(frequency_normalized, 40)
		);
	}

	postProcessingKey(key) {
		const keyName = key.dataset['key'];

		// Override the Space key content to also show the name of the layout
		const plus = this.keyboardConfiguration.plus === 'yes' ? ' <span class="glow">+</span>' : '';
		if (
			this.keyboardConfiguration.layer === 'Visuel' &&
			this.keyboardConfiguration.type === 'iso' &&
			keyName === 'Space'
		) {
			key.innerHTML = `<div>${this.layoutData['name']}${plus}</div>`;
		}

		// Make the ★ key glow
		if (
			this.keyboardConfiguration.layer === 'Visuel' &&
			this.keyboardConfiguration.plus === 'yes' &&
			keyName === 'magique'
		) {
			key.innerHTML = '<div><span class="glow" style = "position:initial">★</span></div>';
		}

		// For ISO, Layer is on LAlt instead of Space
		if (
			this.keyboardConfiguration.type === 'iso' &&
			this.keyboardConfiguration.layer === 'Layer' &&
			this.keyboardConfiguration.plus === 'yes' &&
			keyName === 'LAlt'
		) {
			key.innerHTML = '<div>Layer</div>';
		}
		// For Ergodox, Layer is on Space instead of LAlt
		if (
			this.keyboardConfiguration.type === 'ergodox' &&
			this.keyboardConfiguration.layer === 'Layer' &&
			this.keyboardConfiguration.plus === 'yes' &&
			keyName === 'Space'
		) {
			key.innerHTML = '<div>Layer</div>';
		}
	}

	layerSwitch(pressedKey) {
		let pressedKeyName = pressedKey.dataset['key'];
		const currentLayer = this.keyboardConfiguration.layer;
		const plus = this.keyboardConfiguration.plus === 'yes';
		const type = this.keyboardConfiguration.type;
		let newLayer = currentLayer;

		if (
			pressedKeyName === 'LShift' ||
			pressedKeyName === 'RShift' ||
			// RCtrl becomes Shift in Ergopti+ ISO
			(pressedKeyName === 'RCtrl' && type === 'iso' && plus)
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
			this.updateKeyboard();
		}
	}

	updateKeyboardConfiguration() {
		const keyboardLocation = this.getKeyboardLocation();
		keyboardLocation.dataset['type'] = this.keyboardConfiguration.type;
		keyboardLocation.dataset['layer'] = this.keyboardConfiguration.layer;
		keyboardLocation.dataset['plus'] = this.keyboardConfiguration.plus;
		keyboardLocation.dataset['couleur'] = this.keyboardConfiguration.couleur;
	}

	pressCurrentLayerModifiers() {
		const keyboardLocation = this.getKeyboardLocation();
		const layer = this.keyboardConfiguration.layer;
		const plus = this.keyboardConfiguration.plus === 'yes';
		const type = this.keyboardConfiguration.type;

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

		// Utility function to pressKey a key if it exists
		function pressKey(key) {
			if (keys[key] !== null) {
				keys[key].classList.add('pressed-key');
			}
		}

		// Mapping of keys to pressKey for each layer
		const layerMap = {
			Shift: ['LShift', 'RShift'],
			Ctrl: ['LCtrl'], // RCtrl is a special case
			AltGr: ['RAlt'],
			ShiftAltGr: ['LShift', 'RShift', 'RAlt'],
			CirconflexeShift: ['LShift', 'RShift'],
			TremaShift: ['LShift', 'RShift'],
			GreekShift: ['LShift', 'RShift']
		};

		// pressKey keys for the current layer
		const keysToActivate = layerMap[layer];
		if (keysToActivate !== undefined) {
			for (const key of keysToActivate) {
				pressKey(key);
			}
		}

		// Special cases
		if (
			plus &&
			type === 'iso' &&
			['Shift', 'ShiftAltGr', 'CirconflexeShift', 'TremaShift', 'GreekShift'].includes(layer)
		) {
			pressKey('RCtrl');
		}

		if (layer === 'Ctrl') {
			if (type === 'ergodox') {
				pressKey('RCtrl');
			}
			if (type === 'iso') {
				if (plus) {
					pressKey('CapsLock');
				} else {
					pressKey('RCtrl');
				}
			}
		}

		if (layer === 'Layer') {
			if (type === 'iso') {
				pressKey('LAlt');
			}
			if (type === 'ergodox') {
				pressKey('Space');
			}
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
