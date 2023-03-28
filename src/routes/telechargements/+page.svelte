<script>
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import { onMount } from 'svelte';
	import data from '$lib/data/hypertexte.json';

	let emplacementClavier;
	let plus = 'oui';

	// Maj automatique de la couche
	export let shift = false;
	export let altgr = false;
	let couche = 'Primary';
	$: if (altgr && shift) {
		couche = 'ShiftAltGr';
		restart();
	} else if (altgr && !shift) {
		couche = 'AltGr';
		restart();
	} else if (!altgr && shift) {
		couche = 'Shift';
		restart();
	} else {
		couche = 'Primary';
		restart();
	}
	// Pour maj le clavier
	let unique = {}; // every {} is unique, {} === {} evaluates to false
	function restart() {
		unique = {};
	}

	function emulationClavier(event) {
		// Si touche modificatrice
		if (event.code === 'AltRight') {
			altgr = true;
			return;
		}
		if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			shift = true;
			return;
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
				return;
			} else if (keyPressed === 'Enter' || keyPressed === 'AltRight') {
				champTexte = champTexte + '<br>';
				return;
			} else {
				let touche = '';
				if (event.shiftKey && altgr) {
					touche = toucheClavier['ShiftAltGr'];
				} else if (!event.shiftKey && altgr) {
					touche = toucheClavier['AltGr'];
				} else if (event.shiftKey && !altgr) {
					touche = toucheClavier['Shift'];
				} else if (!event.shiftKey && !altgr) {
					touche = toucheClavier['Primary'];
				}

				// Corrections localisées
				if (plus === 'oui') {
					if (toucheClavier['touche'] === 'q') {
						touche = 'qu';
					}
					if (toucheClavier['touche'] === 'magique') {
						touche = champTexte.slice(-1);
					}
				}
				console.log(touche);
				touche = touche.replace(/<span class='espace-insecable'><\/span>/g, ' ');
				console.log(touche);
				envoiTouche_ReplacerCurseur(touche);
			}
		}
	}

	function envoiTouche_ReplacerCurseur(touche) {
		// Récupérer le div et le contenu à insérer
		var divEditable = document.getElementById('input-text');

		// Récupérer la position du curseur dans le div
		var positionCurseur = window.getSelection().getRangeAt(0).startOffset;

		// Récupérer le contenu HTML avant et après la position du curseur
		var contenuAvantCurseur = divEditable.innerHTML.substring(0, positionCurseur);
		var contenuApresCurseur = divEditable.innerHTML.substring(positionCurseur);

		// Concaténer les trois parties pour obtenir le contenu HTML mis à jour
		if (touche === 'Backspace') {
			divEditable.innerHTML =
				contenuAvantCurseur.substring(0, positionCurseur - 1) + contenuApresCurseur;
			var nouvellePositionCurseur = positionCurseur - 1;
		} else {
			divEditable.innerHTML = contenuAvantCurseur + touche + contenuApresCurseur;
			var nouvellePositionCurseur = positionCurseur + touche.length;
		}

		// Remettre le curseur à sa position initiale
		var range = document.createRange();
		var sel = window.getSelection();
		range.setStart(divEditable.childNodes[0], nouvellePositionCurseur);
		range.collapse(true);
		sel.removeAllRanges();
		sel.addRange(range);
	}

	function relacherModificateurs(event) {
		if (event.code === 'AltRight') {
			altgr = false;
			restart();
			return;
		}
		if (event.code === 'ShiftLeft' || event.code === 'ShiftRight') {
			shift = false;
			restart();
			return;
		}
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

	let champTexte = '';
</script>

<svelte:head>
	<title>Téléchargements</title>
	<meta name="description" content="Télécharger HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Téléchargements</h1>

	<div class="paragraphe">
		<!-- <div class="btn-group">
			<button><a href="/downloads/HyperTexte.exe">HyperTexte.exe</a></button>
			<button><a href="/downloads/HyperTexte.kbe">HyperTexte.kbe</a></button>
		</div> -->

		<h2 data-aos="zoom-out" data-aos-mirror="true">Fichiers</h2>

		<h3>Pour installer la disposition</h3>
		<mini-espace />
		<div>
			<a href="/files/KbdEditInstallerhypertexte_v030.exe"><button>HyperTexte.v1.0.3.exe</button></a
			>
		</div>
		<mini-espace />
		<div>
			<a href="/files/HyperTexte v0.30.kbe"><button>Fichier source de HyperTexte.v1.0.3</button></a>
		</div>
		<mini-espace />
		<div>
			<a aria-disabled="true"><button>HyperTextePlus.exe — Pas encore disponible</button></a>
		</div>
		<petit-espace />

		<h3>Pour les comparateurs de disposition</h3>
		<mini-espace />
		<div>
			<span>Version ISO : </span><a href="/files/hypertexte.v1.0.3.fr.iso.txt"
				><button>hypertexte.v1.0.3.fr.iso</button></a
			>
		</div>
		<mini-espace />
		<div>
			<span>Version Ergodox : </span><a href="/files/hypertexte.v1.0.3.fr.ergodox.txt"
				><button>hypertexte.v1.0.3.fr.ergodox</button></a
			>
		</div>
	</div>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Installation</h2>
	<h3>Instructions générales</h3>
	<p>
		Si vous pouvez installer la disposition, utilisez le .exe. Sinon, vous pouvez utiliser le script
		AHK pour que le script convertisse toutes vos frappes quelque soit votre disposition. Vous aurez
		alors automatiquement la meilleure version de la disposition : <Nom_Plus />
	</p>
	<petit-espace />
	<h3>Comment installer la disposition sur Windows</h3>
	<p>[À faire]</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Tester la disposition en ligne</h2>

	{#key unique}
		<EnsembleClavier
			emplacement={'clavier-emulation'}
			type={'iso'}
			{couche}
			couleur={'non'}
			plus={'non'}
			controles={'non'}
		/>
	{/key}

	<mini-espace />
	<div style="margin: 0 auto; width: 100%;">
		<div
			contenteditable="true"
			id="input-text"
			on:keydown={emulationClavier}
			on:keyup={relacherModificateurs}
		>
			{@html champTexte}
		</div>
	</div>
	<p id="output-text" />
</div>

<style>
	#input-text {
		display: block;
		margin: 0 auto;
		width: 70%;
		min-height: 50px;
		padding: 12px;
		border-radius: 7px;
		background-color: white;
		color: black;
	}
	h3 {
		display: inline-block;
		position: relative;
		color: white;
		font-weight: normal;
	}

	h3::after {
		display: block;
		position: absolute;
		height: 4px;
		width: 100%;
		content: '';
		background: white;
		border-radius: 10px;
		margin-top: 2px;
	}
</style>
