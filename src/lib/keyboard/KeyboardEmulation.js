import * as stores_infos from '$lib/stores_infos.js';
import { get } from 'svelte/store';
import { Keyboard } from '$lib/keyboard/Keyboard.js';
import magicReplacements from '$lib/keyboard/data/magicReplacements.json';

export class KeyboardEmulation extends Keyboard {
	constructor(id) {
		super(id);

		this['layer'] = 'Primary'; // Default layer
		this['modifiers'] = {
			Shift: false,
			Alt: false,
			AltGr: false,
			Ctrl: false,
			Circonflexe: false,
			Trema: false,
			Exposant: false,
			Indice: false,
			R: false,
			Currency: false,
			À: false,
			',': false
		};

		// We use bind here is because otherwise the scope of "this" is changed in the text input and this["name"] becomes undefined
		this.emulateKey = this.emulateKey.bind(this);
		this.releaseKey = this.releaseKey.bind(this);
	}

	layerUpdate() {
		// Determine the new value of the layer
		const priorities = [
			{ cond: this['modifiers']['AltGr'] && this['modifiers']['Shift'], value: 'ShiftAltGr' },
			{
				cond: this['modifiers']['Circonflexe'] && this['modifiers']['Shift'],
				value: 'CirconflexeShift'
			},
			{ cond: this['modifiers']['Circonflexe'], value: 'Circonflexe' },
			{ cond: this['modifiers']['Trema'] && this['modifiers']['Shift'], value: 'TremaShift' },
			{ cond: this['modifiers']['Trema'], value: 'Trema' },
			{ cond: this['modifiers']['Exposant'] && this['modifiers']['Shift'], value: 'ExposantShift' },
			{ cond: this['modifiers']['Exposant'], value: 'Exposant' },
			{ cond: this['modifiers']['Indice'] && this['modifiers']['Shift'], value: 'IndiceShift' },
			{ cond: this['modifiers']['Indice'], value: 'Indice' },
			{ cond: this['modifiers']['R'] && this['modifiers']['Shift'], value: 'RShift' },
			{ cond: this['modifiers']['R'], value: 'R' },
			{ cond: this['modifiers']['Currency'] && this['modifiers']['Shift'], value: 'CurrencyShift' },
			{ cond: this['modifiers']['Currency'], value: 'Currency' },
			{ cond: this['modifiers']['AltGr'], value: 'AltGr' },
			{ cond: this['modifiers']['Shift'], value: 'Shift' },
			{ cond: this['modifiers']['Ctrl'], value: 'Ctrl' },
			{ cond: this['modifiers']['R'], value: 'R' },
			{ cond: this['modifiers']['À'], value: 'À' },
			{ cond: this['modifiers'][','], value: ',' }
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
		const layoutData = get(stores_infos['layoutData']);
		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		const type = get(stores_infos[this.id])['type'];

		const activeModifier = this.determineActiveModifier(event); // Determine if the key pressed is a modifier
		if (activeModifier) {
			this['modifiers'][activeModifier] = true; // Set the modifier state to active
			this.layerUpdate();
			if (plus && activeModifier === 'Alt') {
				this.sendResult('BackSpace');
			}
			// If a modifier has been pressed, no key to send right now, so we exit the function
			// It is only on the next key pressed that isn’t a modifier that the result of this key on the new layer will be given
			return;
		}

		// Do not intercept shortcuts with Ctrl
		if (this['modifiers']['Ctrl'] && !this['modifiers']['AltGr']) {
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
		const keyIdentifier = layoutData[type].find((el) => el['code'] === keyCodePressed);
		this.pressKey(keyIdentifier['key']); // Press the key location on the visual keyboard layout

		if (keyIdentifier !== undefined) {
			event.preventDefault(); // Don’t send the key defined in the computer keyboard layout
			const keyContent = layoutData['keys'].find((el) => el['key'] === keyIdentifier['key']);

			const activeDeadKey = this.determineActiveDeadKey(keyContent); // Activate a potential dead key
			if (activeDeadKey) {
				this['modifiers'][activeDeadKey] = true;
				this.layerUpdate();
				return;
			}

			const [resultToSend, charactersToDelete] = this.getResultToSendFinal(keyContent);
			this.sendResult(resultToSend, charactersToDelete);
		}
	}

	pressKey(key) {
		// Clean other pressed keys
		const keyboardLocation = this.location;
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
		keyboardLocation.querySelector(`keyboard-key[data-key='${key}']`).classList.add('pressed-key');
	}

	determineActiveModifier(event) {
		const plus = get(stores_infos[this.id])['plus'] === 'yes';

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
			ℝ: 'R',
			'¤': 'Currency'
		};
		return deadKeys[keyPressed];
	}

	getResultToSend(keyContent) {
		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		let resultToSend = '';

		if (plus) {
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
		const plus = get(stores_infos[this.id])['plus'] === 'yes';
		const keyPressed = keyContent['key'];
		let resultToSend = this.getResultToSend(keyContent);
		let charactersToDelete = 0;

		// If a dead key or assimilated is currently activated, it needs to be deactivated now that we send the character present on it
		for (const layerName of [
			'Circonflexe',
			'Trema',
			'Exposant',
			'Indice',
			'R',
			'Currency',
			'À',
			','
		]) {
			if (this['modifiers'][layerName]) {
				if (layerName === 'À' || layerName === ',') {
					charactersToDelete = 1; // Delete the previously typed "à" or "," before sending the result on the layer
				}
				this['modifiers'][layerName] = false;
				this.layerUpdate();
				break;
			}
		}

		// If "à" or "," is on the key to send, we send the character and switch layer
		if (resultToSend === 'à') {
			this['modifiers']['À'] = true;
			this.layerUpdate();
		}
		if (resultToSend === ',') {
			this['modifiers'][','] = true;
			this.layerUpdate();
		}

		if (keyPressed === 'BackSpace') {
			resultToSend = 'BackSpace';
		} else if (
			this['modifiers']['Ctrl'] &&
			(keyPressed === 'BackSpace' || (plus && keyPressed === 'LAlt'))
		) {
			resultToSend = 'Ctrl-BackSpace';
		} else if (
			this['modifiers']['Ctrl'] & (keyPressed === 'Delete') ||
			resultToSend === '"Ctrl + ⌦"'
		) {
			resultToSend = 'Ctrl-Delete';
		} else if (
			keyPressed === 'Delete' ||
			(plus && this['modifiers']['Shift'] && keyPressed === 'LAlt')
		) {
			resultToSend = 'Delete';
		} else if (keyPressed === 'Enter' || (plus && keyPressed === 'CapsLock')) {
			resultToSend = 'Enter';
		}
		return [resultToSend, charactersToDelete];
	}

	sendResult(resultToSend, charactersToDelete = 0) {
		const plus = get(stores_infos[this.id])['plus'] === 'yes';
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

		if (plus) {
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
			const matches = [...newTextAreaValue.matchAll(regex)];
			newTextAreaValue = newTextAreaValue.replace(regex, replacement);

			// Attention, regex escapes characters with "\".
			// Thus, the number of characters really typed isn’t the length of the regex string
			const charactersAddedCount = matches.reduce(
				(acc, m) => acc + (replacement.length - m[0].length),
				0
			); // For each match, calculate the number of characters added in the text input and sum them all
			newCursorPosition = newCursorPosition + charactersAddedCount;
		}

		/* Prevent SFBs involving ★U, like NNU : N★U is the normal way, but we can also do N★Ê */
		/* Except for the R, because "arrêt" exists in French */
		regexReplaceCursor(/([^\Wr]){2}ê/g, '$1$1u');

		/* Automatic typographic apostrophe */
		regexReplaceCursor(/([cdjlmnst])'/gi, '$1’');

		const replacementsSFBs = [
			[/èy/g, 'aî'],
			[/yè/g, 'â'],
			[/êé/g, 'oe'],
			[/éê/g, 'eo'],
			[/éà/g, 'ié'],
			[/àé/g, 'éi'],
			[/ê\./g, 'u.'],
			[/ê,/g, 'u,']
		];

		const replacementsRolls = [
			[/hc/g, 'wh'],
			[/sx/g, 'sk'],
			[/cx/g, 'ck'],
			[/eé/g, 'ez'],
			[/p'/g, 'ct'],
			[/<@/g, '</'],
			[/<%/g, '<='],
			[/>%/g, '>='],
			[/#!/g, ' := '],
			[/!#/g, ' != '],
			[/\(#/g, '("'],
			[/\[#/g, '["'],
			[/#\]/g, '"]'],
			[/#\[/g, '"]'],
			[/#\(/g, '")'],
			[/\[\)/g, ' = ""'],
			[/\\\"/g, '/*'],
			[/\"\\/g, '*\\'],
			[/\$=/g, ' => '],
			[/=\$/g, ' <= '],
			[/\+\?/g, ' -> '],
			[/\?\+/g, ' <- ']
		];

		const replacementsDeadKeyECirc = [
			[/êa/g, 'â'],
			[/êi/g, 'î'],
			[/êo/g, 'ô'],
			[/êu/g, 'û'],
			[/êe/g, 'œ']
		];

		function* caseHandling(list) {
			for (const [regex, replacement] of list) {
				// Lowercase replacement given in the list
				yield [regex, replacement];
				// Uppercase
				yield [new RegExp(regex.source.toUpperCase(), regex.flags), replacement.toUpperCase()];
				// Title case (first letter uppercase, rest lowercase)
				const titleSrc = regex.source.charAt(0).toUpperCase() + regex.source.slice(1);
				const titleRepl = replacement.charAt(0).toUpperCase() + replacement.slice(1);
				yield [new RegExp(titleSrc, regex.flags), titleRepl];
			}
		}

		for (const [regex, replacement] of [
			...caseHandling(replacementsSFBs),
			...caseHandling(replacementsRolls),
			...caseHandling(replacementsDeadKeyECirc)
		]) {
			regexReplaceCursor(regex, replacement);
		}

		return [newTextAreaValue, newCursorPosition];
	}

	releaseKey(event) {
		const modifier = this.determineActiveModifier(event);
		if (modifier) {
			this['modifiers'][modifier] = false;
			this.layerUpdate();
		}
	}
}
