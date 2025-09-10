import * as stores_infos from '$lib/stores_infos.js';
import { Keyboard } from '$lib/keyboard/Keyboard.js';
import magicReplacements from '$lib/keyboard/data/magicReplacements.json';

export class KeyboardEmulation extends Keyboard {
	constructor(id) {
		super(id);

		this['layer'] = 'Primary'; // Default layer
		this['activeLayers'] = {
			Shift: false,
			Alt: false,
			AltGr: false,
			Ctrl: false,
			Circonflexe: false,
			Trema: false,
			Exposant: false,
			Indice: false,
			R: false,
			À: false,
			',': false
		};

		// We use bind here is because otherwise the scope of "this" is changed in the text input and this.layoutData becomes undefined
		this.emulateKey = this.emulateKey.bind(this);
		this.releaseKey = this.releaseKey.bind(this);
	}

	layerUpdate() {
		// Determine the new value of the layer
		const priorities = [
			{ cond: this['activeLayers']['AltGr'] && this['activeLayers']['Shift'], value: 'ShiftAltGr' },
			{
				cond: this['activeLayers']['Circonflexe'] && this['activeLayers']['Shift'],
				value: 'CirconflexeShift'
			},
			{ cond: this['activeLayers']['Trema'] && this['activeLayers']['Shift'], value: 'TremaShift' },
			{ cond: this['activeLayers']['AltGr'], value: 'AltGr' },
			{ cond: this['activeLayers']['Shift'], value: 'Shift' },
			{ cond: this['activeLayers']['Ctrl'], value: 'Ctrl' },
			{ cond: this['activeLayers']['Circonflexe'], value: 'Circonflexe' },
			{ cond: this['activeLayers']['Trema'], value: 'Trema' },
			{ cond: this['activeLayers']['Exposant'], value: 'Exposant' },
			{ cond: this['activeLayers']['Indice'], value: 'Indice' },
			{ cond: this['activeLayers']['R'], value: 'R' },
			{ cond: this['activeLayers']['À'], value: 'À' },
			{ cond: this['activeLayers'][','], value: ',' }
		];
		const match = priorities.find((p) => p.cond);
		this['layer'] = match ? match.value : 'Primary'; // If no match, use default value Primary

		// Update the layer in the store
		stores_infos[this.id].update((currentData) => {
			currentData['layer'] = this['layer'];
			return currentData;
		});
		// Update the visual keyboard to show the new layer
		this.updateKeyboard();
	}

	emulateKey(event) {
		const activeModifier = this.determineActiveModifier(event); // Determine if the key pressed is a modifier
		if (activeModifier) {
			this['activeLayers'][activeModifier] = true; // Set the modifier state to active
			this.layerUpdate();
			if (this.keyboardConfiguration['plus'] === 'yes' && activeModifier === 'Alt') {
				this.sendResult('BackSpace');
			}
			// If a modifier has been pressed, no key to send right now, so we exit the function
			// It is only on the next key pressed that isn’t a modifier that the result of this key on the new layer will be given
			return;
		}

		// Do not intercept shortcuts with Ctrl
		if (this['activeLayers']['Ctrl'] && !this['activeLayers']['AltGr']) {
			// Note: when this["AltGr"] is active, Ctrl is also active, hence the "&& !this["AltGr"]"

			// Ctrl + key gives Ctrl + key emulation: Doesn’t work yet, may not be possible due to security reasons
			/*
            const ctrlEvent = new KeyboardEvent('keydown', {
				key: 'KeyA', // keyContent.touche,
				ctrlKey: true, // Spécifie que la touche Ctrl est enfoncée
				bubbles: true,
				cancelable: true
			});
			this.textarea.dispatchEvent(ctrlEvent);
            */
			return;
		}

		// If a key other than a modifier was pressed
		const keyCodePressed = event.code;
		const keyIdentifier = this.layoutData[this.keyboardConfiguration.type].find(
			(el) => el['code'] === keyCodePressed
		);
		this.pressKey(keyIdentifier['key']); // Press the key location on the visual keyboard layout

		if (keyIdentifier !== undefined) {
			event.preventDefault(); // Don’t send the key defined in the computer keyboard layout
			const keyContent = this.layoutData['keys'].find((el) => el['key'] === keyIdentifier['key']);

			const activeDeadKey = this.determineActiveDeadKey(keyContent); // Activate a potential dead key
			if (activeDeadKey) {
				this['activeLayers'][activeDeadKey] = true;
				this.layerUpdate();
				return;
			}

			const [resultToSend, charactersToDelete] = this.getResultToSendFinal(keyContent);
			this.sendResult(resultToSend, charactersToDelete);
		}
	}

	pressKey(key) {
		// Clean other pressed keys
		const keyboardLocation = this.getKeyboardLocation();
		const pressedKeys = keyboardLocation.querySelectorAll('.pressed-key');
		[].forEach.call(pressedKeys, function (el) {
			if (
				el.dataset['type'] !== 'special' ||
				el.dataset['key'] === 'BackSpace' ||
				el.dataset['key'] === 'Tab'
			) {
				el.classList.remove('pressed-key');
			}
		});

		// Press the key
		keyboardLocation
			.querySelector("keyboard-key[data-key='" + key + "']")
			.classList.add('pressed-key');
	}

	determineActiveModifier(event) {
		const plus = this.keyboardConfiguration['plus'] === 'yes';

		if (event.code === 'AltRight' || event.code === 'AltGraph') {
			return 'AltGr';
		} else if (
			event.code === 'ShiftLeft' ||
			event.code === 'ShiftRight' ||
			(plus && event.code === 'ControlRight')
		) {
			return 'Shift';
		} else if (event.code === 'AltLeft') {
			return 'Alt';
		} else if (event.code === 'ControlLeft' || (!plus && event.code === 'ControlRight')) {
			return 'Ctrl';
		}

		return false;
	}

	determineActiveDeadKey(keyContent) {
		const keyPressed = this.getResultToSend(keyContent);
		const deadKeys = {
			'◌̂': 'Circonflexe',
			'◌̈': 'Trema',
			ᵉ: 'Exposant',
			ᵢ: 'Indice',
			ℝ: 'R'
		};
		return deadKeys[keyPressed];
	}

	getResultToSend(keyContent) {
		let resultToSend = '';
		if (this.keyboardConfiguration['plus'] === 'yes') {
			if (keyContent[this['layer'] + '+'] !== undefined) {
				resultToSend = keyContent[this['layer'] + '+'];
			} else {
				resultToSend = keyContent[this['layer']];
			}
		} else {
			resultToSend = keyContent[this['layer']];
		}
		return resultToSend;
	}

	getResultToSendFinal(keyContent) {
		const plus = this.keyboardConfiguration['plus'] === 'yes';
		const keyPressed = keyContent['key'];
		let resultToSend = this.getResultToSend(keyContent);
		let charactersToDelete = 0;

		// If a dead key or assimilated is currently activated, it needs to be deactivated now that we send the character present on it
		for (const layerName of ['Circonflexe', 'Trema', 'Exposant', 'Indice', 'R', 'À', ',']) {
			if (this['activeLayers'][layerName]) {
				if (layerName === 'À' || layerName === ',') {
					charactersToDelete = 1; // Delete the previously typed "à" or "," before sending the result on the layer
				}
				this['activeLayers'][layerName] = false;
				this.layerUpdate();
				break;
			}
		}

		// If "à" or "," is on the key to send, we send the character and switch layer
		if (resultToSend === 'à') {
			this['activeLayers']['À'] = true;
			this.layerUpdate();
		}
		if (resultToSend === ',') {
			this['activeLayers'][','] = true;
			this.layerUpdate();
		}

		if (keyPressed === 'BackSpace') {
			resultToSend = 'BackSpace';
		} else if (
			this['activeLayers']['Ctrl'] &&
			(keyPressed === 'BackSpace' || (plus && keyPressed === 'LAlt'))
		) {
			resultToSend = 'Ctrl-BackSpace';
		} else if (
			this['activeLayers']['Ctrl'] & (keyPressed === 'Delete') ||
			resultToSend === '"Ctrl + ⌦"'
		) {
			resultToSend = 'Ctrl-Delete';
		} else if (
			keyPressed === 'Delete' ||
			(plus && this['activeLayers']['Shift'] && keyPressed === 'LAlt')
		) {
			resultToSend = 'Delete';
		} else if (keyPressed === 'Enter' || (plus && keyPressed === 'CapsLock')) {
			resultToSend = 'Enter';
		}
		return [resultToSend, charactersToDelete];
	}

	sendResult(resultToSend, charactersToDelete = 0) {
		let newTextAreaValue = this.textarea.value;
		if (charactersToDelete > 0) {
			newTextAreaValue = newTextAreaValue.slice(0, -charactersToDelete);
		}

		// Clean potential html code, added for visualisation reasons, that can’t be rendered in a plain text input box
		resultToSend = resultToSend.replace(/<espace-insecable><\/espace-insecable>/g, ' ');
		resultToSend = resultToSend.replace(/<tap-hold>.*<\/tap-hold>/g, '');
		resultToSend = resultToSend.replace('␣', ' ');

		// Retrieve cursor position as well as text before and after
		const cursorPosition = this.textarea.selectionStart;
		const textBeforeCursor = newTextAreaValue.substring(0, cursorPosition);
		const textAfterCursor = newTextAreaValue.substring(cursorPosition);

		let newCursorPosition = cursorPosition + 1; // Most times, we add a character
		// newTextAreaValue will be the concatenation of the 3 updated parts : before, cursor, after
		if (resultToSend === 'BackSpace') {
			newTextAreaValue = textBeforeCursor.substring(0, cursorPosition - 1) + textAfterCursor;
			newCursorPosition = cursorPosition - 1;
		} else if (resultToSend === 'Ctrl-BackSpace') {
			const textBeforeSuppression = textBeforeCursor;
			const textAfterSuppression = textBeforeCursor.replace(/\s*\S*$/, '');
			newTextAreaValue = textAfterSuppression + textAfterCursor;
			const suppressedCharactersNumber = textBeforeSuppression.length - textAfterSuppression.length;
			newCursorPosition = cursorPosition - suppressedCharactersNumber;
		} else if (resultToSend === 'Ctrl-Delete') {
			const textAfterSuppression = textAfterCursor.replace(/^\S*\s*/, '');
			newTextAreaValue = textBeforeCursor + textAfterSuppression;
			newCursorPosition = cursorPosition;
		} else if (resultToSend === 'Delete') {
			newTextAreaValue = textBeforeCursor + textAfterCursor.substring(1, textAfterCursor.length);
			newCursorPosition = cursorPosition;
		} else if (resultToSend === 'Enter') {
			newTextAreaValue = textBeforeCursor + '\n' + textAfterCursor;
		} else if (resultToSend === 'Tab') {
			newTextAreaValue = textBeforeCursor + '\t' + textAfterCursor;
		} else if (resultToSend === '★') {
			const currentWord = textBeforeCursor.split(/\s+/).slice(-1)[0];
			if (currentWord.toLowerCase() in magicReplacements) {
				let replacement = magicReplacements[currentWord.toLowerCase()];

				if (currentWord === currentWord.toUpperCase() && currentWord.length > 1) {
					replacement = replacement.toUpperCase();
				} else if (
					currentWord ===
					currentWord.charAt(0).toUpperCase() + currentWord.slice(1).toLowerCase()
				) {
					replacement = replacement.charAt(0).toUpperCase() + replacement.slice(1).toLowerCase();
				} else {
					replacement = replacement.toLowerCase();
				}

				let regex = /(\s*)(\S+)$/;
				let match = textBeforeCursor.match(regex);
				let prefix = match ? match[1] : '';

				newTextAreaValue = textBeforeCursor.replace(regex, prefix + replacement) + textAfterCursor;
				newCursorPosition = cursorPosition + replacement.length;
			} else {
				// If no replacement is found, double the previous character
				newTextAreaValue = textBeforeCursor + textBeforeCursor.slice(-1) + textAfterCursor;
			}
		} else {
			newTextAreaValue = textBeforeCursor + resultToSend + textAfterCursor;
			newCursorPosition = cursorPosition + resultToSend.length;
		}

		if (this.keyboardConfiguration['plus'] === 'yes') {
			[newTextAreaValue, newCursorPosition] = this.ergoptiPlusFeatures(
				newTextAreaValue,
				newCursorPosition
			);
		}

		this.textarea.value = newTextAreaValue;
		this.textarea.setSelectionRange(newCursorPosition, newCursorPosition);
	}

	ergoptiPlusFeatures(TextAreaValue, CursorPosition) {
		let newTextAreaValue = TextAreaValue;
		let newCursorPosition = CursorPosition;

		function regexReplaceCursor(regex, replacement) {
			const matchCount = (newTextAreaValue.match(regex) || []).length; // Number of replacements to be made, as it will modify the cursor position
			newTextAreaValue = newTextAreaValue.replace(regex, replacement);
			newCursorPosition =
				newCursorPosition + matchCount * (replacement.length - regex.source.length);
		}

		/* Prevent SFBs involving ★U, like NNU : N★U is the normal way, but we can also do N★Ê */
		/* Except for the R, because "arrêt" exists in French */
		regexReplaceCursor(/([^\Wr]){2}ê/g, '$1$1u');

		/* Automatic typographic apostrophe */
		regexReplaceCursor(/([cdjlmnst])'/gi, '$1’');

		const replacementsSFBs = [
			[/êé/g, 'aî'],
			[/éê/g, 'â'],
			[/eê/g, 'eo'],
			[/ê\./g, 'u.'],
			[/ê,/g, 'u,']
		];

		const replacementsRolls = [
			[/yè/g, 'éi'],
			[/èy/g, 'ié'],
			[/hc/g, 'wh'],
			[/sx/g, 'sk'],
			[/cx/g, 'ck'],
			[/eé/g, 'eé'],
			[/p'/g, 'ct'],
			[/<@/g, '</'],
			[/<%/g, '<='],
			[/>%/g, '>='],
			[/#!/g, ' := '],
			[/!#/g, ' != '],
			[/\(#/g, '("'],
			[/\[#/g, '["'],
			[/\[\)/g, ' = ""'],
			[/\\\"/g, '/*'],
			[/\"\\/g, '*\\'],
			[/$=/g, ' => '],
			[/=$/g, ' <= '],
			[/+?/g, ' -> '],
			[/?+/g, ' <- ']
		];

		const replacementsDeadKeyECirc = [
			[/êa/g, 'â'],
			[/êi/g, 'î'],
			[/êo/g, 'ô'],
			[/êu/g, 'û']
		];

		for (const [regex, replacement] of [
			...replacementsSFBs,
			...replacementsRolls,
			...replacementsDeadKeyECirc
		]) {
			regexReplaceCursor(regex, replacement);
		}

		return [newTextAreaValue, newCursorPosition];
	}

	releaseKey(event) {
		const modifier = this.determineActiveModifier(event);
		if (modifier) {
			this['activeLayers'][modifier] = false;
			this.layerUpdate();
		}
	}
}
