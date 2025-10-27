import * as stores_infos from '$lib/stores_infos.js';
import { get } from 'svelte/store';

import characterFrequencies from '$lib/keyboard/data/characterFrequencies.json'; // Data coming from https://github.com/Nuclear-Squid/ergol/blob/main/corpus/en%2Bfr.json
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
			this.updateKeyboard();
		});

		// Automatically update the keyboard as soon as the keyboard configuration changes
		stores_infos[this.id].subscribe((value) => {
			this.updateKeyboard();
		});
	}

	getKeyboardLocation() {
		if (typeof document === 'undefined') {
			console.error('[Keyboard] Document not defined (likely running outside the browser)');
			return null;
		}

		const idKeyboard = `keyboard_${this.id}`;
		const location = document.getElementById(idKeyboard);

		if (!location) {
			console.error(`[Keyboard] Element with id "${idKeyboard}" not found in the DOM`);
			return null;
		}

		return location;
	}

	updateKeyboard() {
		console.info('[Keyboard] Update of the keyboard');
		if (!this.location) {
			this.location = this.getKeyboardLocation();
		}
		this.updateKeys();
		this.updateKeyboardConfiguration();
		this.pressCurrentLayerModifiers();
	}

	updateKeys() {
		if (!get(stores_infos['layoutData']) || !get(stores_infos[this.id]) || !this.location) {
			return;
		}

		for (let row = 1; row <= 7; row++) {
			for (let column = 0; column <= 15; column++) {
				const key = this.cleanKey(this.location, row, column);

				// Retrieve the id of the key at the specific location row x column
				// This id depends whether the layout is ISO or Ergodox (two different sets of properties)
				const keyIdentifier = get(stores_infos['layoutData'])[
					get(stores_infos[this.id])['type']
				].find((el) => el['row'] == row && el['column'] == column);

				if (keyIdentifier !== undefined) {
					// Retrieve what should be displayed on the key of this id
					const keyContent = get(stores_infos['layoutData'])['keys'].find(
						(el) => el['key'] === keyIdentifier['key']
					);

					this.fillKey(key, keyContent, row);
					this.setKeyProperties(key, keyIdentifier, keyContent, column);
					this.postProcessingKey(key);

					// Functionality to switch layer by clicking on a key
					if (get(stores_infos[this.id])['controls'] === 'yes') {
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

	cleanKey(location, row, column) {
		const keySelector = `keyboard-key[data-row='${row}'][data-column='${column}']`;

		// Event listeners cleaning
		const oldKey = location.querySelector(keySelector);
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
		newKey.replaceChildren(document.createElement('div'));
		newKey.className = '';
		newKey.style = '';

		return newKey;
	}

	fillKey(key, keyContent, row) {
		const keyDiv = key.querySelector('div');
		// const keyDiv = key;
		if (!get(stores_infos[this.id])) {
			return;
		}

		if (
			get(stores_infos[this.id])['layer'] !== 'Visuel' &&
			(keyContent[get(stores_infos[this.id])['layer']] === '' ||
				keyContent[get(stores_infos[this.id])['layer']] === undefined)
		) {
			/* Undefined key in the selected layer */
			return;
		}

		const plus = get(stores_infos[this.id])['plus'] === 'yes';

		if (get(stores_infos[this.id])['layer'] === 'Visuel') {
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
			if (plus && keyContent[get(stores_infos[this.id])['layer'] + '+'] !== undefined && row < 6) {
				// If the + layer exists AND the key isn’t on the thumb cluster
				keyDiv.innerHTML = keyContent[get(stores_infos[this.id])['layer'] + '+'];
				key.dataset['plus'] = 'yes';
			} else {
				keyDiv.innerHTML = keyContent[get(stores_infos[this.id])['layer']];
			}
		}
	}

	setKeyProperties(key, keyIdentifier, keyContent, column) {
		if (!get(stores_infos[this.id])) {
			return;
		}

		// Fill the data attributes of the key
		// This enables automatic styling of key groups with CSS
		key.dataset['key'] = keyIdentifier['key'];
		key.dataset['content'] = key.querySelector('div').innerHTML;
		key.dataset['finger'] = keyIdentifier['finger'];
		key.dataset['hand'] = keyIdentifier['hand'];
		key.dataset['type'] = keyContent['type'];
		key.dataset['column'] = column;

		if (
			get(stores_infos[this.id])['layer'] === 'Visuel' &&
			keyContent['Primary' + '-style'] !== undefined
		) {
			key.dataset['style'] = keyContent['Primary' + '-style'];
		} else {
			if (
				get(stores_infos[this.id])['plus'] === 'yes' &&
				keyContent[get(stores_infos[this.id])['layer'] + '+' + '-style'] !== undefined
			) {
				key.dataset['style'] = keyContent[get(stores_infos[this.id])['layer'] + '+' + '-style'];
			} else if (keyContent[get(stores_infos[this.id])['layer'] + '-style'] !== undefined) {
				key.dataset['style'] = keyContent[get(stores_infos[this.id])['layer'] + '-style'];
			}
		}

		key.style.setProperty('--size', keyIdentifier['size']);

		const frequency = characterFrequencies[keyContent[get(stores_infos[this.id])['layer']]];
		key.style.setProperty('--frequency', frequency);

		const frequency_normalized = // Between 0 et 1 with 1 for the most frequent key
			(characterFrequencies[keyContent[get(stores_infos[this.id])['layer']]] -
				characterFrequencies['min']) /
			(characterFrequencies['max'] - characterFrequencies['min']);
		key.style.setProperty(
			'--frequency_normalized',
			logarithmicTransformation(frequency_normalized, 40)
		);
	}

	postProcessingKey(key) {
		if (!get(stores_infos['layoutData']) || !get(stores_infos[this.id])) {
			return;
		}

		const keyName = key.dataset['key'];
		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		const type = get(stores_infos[this.id])['type'];
		const layer = get(stores_infos[this.id])['layer'];

		// Override the Space key content to also show the name of the layout
		const plusSymbol = plus
			? '<span class="glow plus" style = "position:relative; margin-left:0.1em">+</span>'
			: '';
		if (type === 'iso' && layer === 'Visuel' && keyName === 'Space') {
			if (plusSymbol) {
				key.innerHTML = `<span style="position:relative; top:-0.05em;">${get(stores_infos['layoutData'])['name'] + plusSymbol}</span>`;
			} else {
				key.innerHTML = get(stores_infos['layoutData'])['name'];
			}
		}

		// Make the ★ key glow
		if (plus && layer === 'Visuel' && keyName === 'j') {
			key.innerHTML = '<span class="glow" style = "position:initial">★</span>';
		}

		// For ISO, Layer is on LAlt instead of Space
		if (plus && type === 'iso' && layer === 'Layer' && keyName === 'LAlt') {
			key.innerHTML = 'Layer';
		}
		// For Ergodox, Layer is on Space instead of LAlt
		if (plus && type === 'ergodox' && layer === 'Layer' && keyName === 'Space') {
			key.innerHTML = 'Layer';
		}
	}

	layerSwitch(pressedKey) {
		if (!get(stores_infos['layoutData']) || !get(stores_infos[this.id])) {
			return;
		}

		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		const type = get(stores_infos[this.id])['type'];
		const layer = get(stores_infos[this.id])['layer'];

		let pressedKeyName = pressedKey.dataset['key'];
		let pressedKeyContent = pressedKey.dataset['content'];
		let deadKey = pressedKey.dataset['style'] === 'morte';
		let newLayer = layer;

		if (
			pressedKeyName === 'LShift' ||
			pressedKeyName === 'RShift' ||
			// RCtrl becomes Shift in Ergopti+ ISO
			(plus && type === 'iso' && pressedKeyName === 'RCtrl')
		) {
			pressedKeyName = 'Shift';
		}

		const layerTransitions = {
			Shift: {
				Shift: 'Visuel',
				AltGr: 'ShiftAltGr',
				ShiftAltGr: 'AltGr',
				CirconflexeShift: 'Circonflexe',
				Circonflexe: 'CirconflexeShift',
				TremaShift: 'Trema',
				Trema: 'TremaShift',
				ExposantShift: 'Exposant',
				Exposant: 'ExposantShift',
				IndiceShift: 'Indice',
				Indice: 'IndiceShift',
				GreekShift: 'Greek',
				Greek: 'GreekShift',
				RShift: 'R',
				R: 'RShift',
				CurrencyShift: 'Currency',
				Currency: 'CurrencyShift',
				À: 'Shift',
				',': 'Shift',
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

		if (pressedKeyName in layerTransitions) {
			const transitionRules = layerTransitions[pressedKeyName];
			let newLayerTemp;
			if (transitionRules) {
				newLayerTemp = transitionRules[layer] || transitionRules.default;
			}

			// Only change the layer if it exists on the Option key, as this key is always set on all layers to "Option"
			const keyContent = get(stores_infos['layoutData'])['keys'].find(
				(el) => el['key'] === 'Option'
			);
			const keyContentOnNewLayer = keyContent[newLayerTemp];
			if (keyContentOnNewLayer) {
				newLayer = newLayerTemp;
			} else {
				newLayer = 'Visuel';
			}
		}

		// Dead Keys
		if (pressedKeyContent === '◌̂' && deadKey) {
			newLayer = 'Circonflexe';
		}
		if (pressedKeyContent === '◌̈' && deadKey) {
			newLayer = 'Trema';
		}
		if (pressedKeyContent === 'ᵉ' && deadKey) {
			newLayer = 'Exposant';
		}
		if (pressedKeyContent === 'ᵢ' && deadKey) {
			newLayer = 'Indice';
		}
		if (['µ', 'δ'].includes(pressedKeyContent) && deadKey) {
			newLayer = 'Greek';
		}
		if (pressedKeyContent === 'ℝ' && deadKey) {
			newLayer = 'R';
		}
		if (pressedKeyContent === '¤' && deadKey) {
			newLayer = 'Currency';
		}

		if (plus) {
			// Comma
			if (pressedKeyName === ',') {
				if (['Visuel', 'Primary', 'Shift'].includes(layer)) {
					newLayer = ',';
				}
			}

			// À
			if (pressedKeyName === 'à') {
				if (['Visuel', 'Primary', 'Shift'].includes(layer)) {
					newLayer = 'À';
				} else if (layer === 'À') {
					newLayer = 'Visuel';
				}
			}

			// CapsLock
			if (pressedKeyName === 'CapsLock') {
				if (layer !== 'Ctrl') {
					newLayer = 'Ctrl';
				} else {
					newLayer = 'Visuel';
				}
			}

			// Space
			if (pressedKeyName === 'Space' && type === 'ergodox') {
				if (['Visuel', 'Primary'].includes(layer)) {
					newLayer = 'Layer';
				} else if (layer === 'Layer') {
					newLayer = 'Visuel';
				}
			}

			// LAlt
			if (pressedKeyName === 'LAlt' && type === 'iso') {
				if (layer === 'Layer') {
					newLayer = 'Visuel';
				} else {
					newLayer = 'Layer';
				}
			}
		}

		// At this point, the new layer has been determined
		// Most keys pressed won’t change the layer, as only some modifiers and deadkeys defined in this code do
		// Then, the layer variable is updated, and finally the keyboard
		if (newLayer !== layer) {
			stores_infos[this.id].update((currentData) => {
				currentData['layer'] = newLayer;
				return currentData;
			});
			this.updateKeyboard();
		}
	}

	updateKeyboardConfiguration() {
		if (!get(stores_infos[this.id]) || !this.location) {
			return;
		}

		this.location.dataset['type'] = get(stores_infos[this.id])['type'];
		this.location.dataset['layer'] = get(stores_infos[this.id])['layer'];
		this.location.dataset['plus'] = get(stores_infos[this.id])['plus'];
		this.location.dataset['color'] = get(stores_infos[this.id])['color'];
	}

	pressCurrentLayerModifiers() {
		if (!get(stores_infos['layoutData']) || !get(stores_infos[this.id]) || !this.location) {
			return;
		}

		function getKeyContent(layoutData, key, layer) {
			const keyContent = layoutData['keys'].find((el) => el['key'] === key);
			if (!keyContent) {
				return '';
			}
			const contentOnLayer = keyContent[layer];
			return contentOnLayer || '';
		}

		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		const type = get(stores_infos[this.id])['type'];
		const layer = get(stores_infos[this.id])['layer'];

		const keys = {
			LShift: this.location.querySelector("[data-key='LShift']"),
			RShift: this.location.querySelector("[data-key='RShift']"),
			LCtrl: this.location.querySelector("[data-key='LCtrl']"),
			RCtrl: this.location.querySelector("[data-key='RCtrl']"),
			LAlt: this.location.querySelector("[data-key='LAlt']"),
			RAlt: this.location.querySelector("[data-key='RAlt']"),
			CapsLock: this.location.querySelector("[data-key='CapsLock']"),
			Space: this.location.querySelector("[data-key='Space']")
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
			ExposantShift: ['LShift', 'RShift'],
			IndiceShift: ['LShift', 'RShift'],
			GreekShift: ['LShift', 'RShift'],
			RShift: ['LShift', 'RShift'],
			CurrencyShift: ['LShift', 'RShift']
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
			getKeyContent(get(stores_infos['layoutData']), 'RCtrl', layer + (plus ? '+' : '')).includes(
				'Shift'
			) &&
			[
				'Shift',
				'ShiftAltGr',
				'CirconflexeShift',
				'TremaShift',
				'ExposantShift',
				'IndiceShift',
				'GreekShift',
				'RShift',
				'CurrencyShift'
			].includes(layer)
		) {
			pressKey('RCtrl');
		}

		if (layer === 'Ctrl') {
			if (type === 'ergodox') {
				pressKey('RCtrl');
			}
			if (
				type === 'iso' &&
				plus &&
				getKeyContent(
					get(stores_infos['layoutData']),
					'CapsLock',
					layer + (plus ? '+' : '')
				).includes('Ctrl') &&
				!getKeyContent(
					get(stores_infos['layoutData']),
					'CapsLock',
					layer + (plus ? '+' : '')
				).includes('Ctrl +') // Not on Ctrl + Key shortcuts
			) {
				pressKey('CapsLock');
			}
			if (
				type === 'iso' &&
				getKeyContent(get(stores_infos['layoutData']), 'RCtrl', layer + (plus ? '+' : '')).includes(
					'Ctrl'
				) &&
				!getKeyContent(
					get(stores_infos['layoutData']),
					'RCtrl',
					layer + (plus ? '+' : '')
				).includes('Ctrl +') // Not on Ctrl + Key shortcuts
			) {
				pressKey('RCtrl');
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
		const location = this.getKeyboardLocation();
		if (!location) {
			return;
		}

		// Clear previously pressed keys
		const pressedKeys = location.querySelectorAll('.pressed-key');
		pressedKeys.forEach(function (el) {
			el.classList.remove('pressed-key');
		});

		function writeNext(i) {
			if (i >= text.length) return; // stop condition

			const nextLetter = text.charAt(i);
			const nextKey = location.querySelector(`keyboard-key[data-key='${nextLetter}']`);

			if (nextKey) {
				nextKey.classList.add('pressed-key');
			}

			if (makePreviousKeysDisappear && i > 0) {
				const previousLetter = text.charAt(i - 1);
				const previousKey = location.querySelector(`keyboard-key[data-key='${previousLetter}']`);
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
