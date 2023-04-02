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
	let modificateur = activationModificateur(event);
	if (modificateur) {
		return; // Si c'est une touche modificatrice, on quitte la fonction
	}

	// Attention, quand AltGr est activé, Ctrl l’est aussi, d’où le &
	if (control & !altgr) {
		return true; // Ne pas intercepter les raccourcis avec Ctrl
	}

	// Si touche normale
	let keyPressed = event.code;
	let res = data['iso'].find((el) => el['code'] == keyPressed);
	if (res !== undefined) {
		event.preventDefault(); // La touche selon le pilote de l’ordinateur n’est pas tapée
		let toucheClavier = data.touches.find((el) => el['touche'] == res['touche']);
		presserToucheClavier(toucheClavier['touche']);
		if (keyPressed === 'CapsLock' || keyPressed === 'Backspace') {
			envoiTouche_ReplacerCurseur('Backspace');
		} else if (
			keyPressed === 'Enter' ||
			keyPressed === 'AltRight' ||
			(toucheClavier['touche'] === 'magique' && plus === 'non')
		) {
			envoiTouche_ReplacerCurseur('Enter');
		} else if (a_grave) {
			if (keyPressed === 'Space') {
				touche = ' ';
			} else {
				// On supprime le à avant de taper le raccourci en à
				var textarea = document.getElementById('input-text');
				textarea.value = textarea.value.slice(0, -1);
				touche = toucheClavier['À'];
			}
			a_grave = false;
		} else {
			fonction(event, toucheClavier);
		}
	}
}

function fonction(event, toucheClavier) {
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
	if (plus === 'oui') {
		if (toucheClavier[couche + '+'] !== undefined) {
			touche = toucheClavier[couche + '+'];
		} else {
			touche = toucheClavier[couche];
		}
	} else {
		touche = toucheClavier[couche];
	}

	// Corrections localisées
	if (plus === 'oui') {
		if (toucheClavier['touche'] === 'q') {
			touche = 'qu';
		}
	}
	touche = touche.replace(/<span class='espace-insecable'><\/span>/g, ' ');
	envoiTouche_ReplacerCurseur(touche);
}
function envoiTouche_ReplacerCurseur(touche) {
	// Récupérer la textarea et le contenu à insérer
	var textarea = document.getElementById('input-text');

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
		let toucheRepetee = texteAvantCurseur.slice(-1);
		textarea.value = texteAvantCurseur + toucheRepetee + texteApresCurseur;
		nouvellePositionCurseur = positionCurseur + 1;
	} else {
		textarea.value = texteAvantCurseur + touche + texteApresCurseur;
		nouvellePositionCurseur = positionCurseur + touche.length;
	}
	textarea.setSelectionRange(nouvellePositionCurseur, nouvellePositionCurseur);
}

function presserToucheClavier(touche) {
	emplacementClavier = document.getElementById('clavier-emulation');

	// Nettoyage des touches actives
	const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
	[].forEach.call(touchesActives, function (el) {
		el.classList.remove('touche-active');
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
}
