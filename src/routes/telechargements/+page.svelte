<script>
	import Nom_Plus from '$lib/composants/Nom_Plus.svelte';
	import EnsembleClavier from '$lib/composants/clavier/Ensemble_Clavier.svelte';
	import { onMount } from 'svelte';
	import data from '$lib/data/hypertexte.json';

	let champTexte = '';
	let emplacementClavier = null;

	function emulationClavier(event) {
		event.preventDefault();
		let keyPressed = event.code;
		let res = data['touches'].find((el) => el['code'] == keyPressed);
		let touche = keyPressed;
		if (event.shiftKey & event.altKey & event.ctrlKey) {
			touche = res['ShiftAltGr'];
		} else if (!event.shiftKey & event.altKey & event.ctrlKey) {
			touche = res['AltGr'];
		} else if (event.shiftKey & !event.altKey & !event.ctrlKey) {
			touche = res['Shift'];
		} else if (!event.shiftKey & !event.altKey & !event.ctrlKey) {
			touche = res['Primary'];
		}
		presserTouche(res['touche']);
		champTexte = champTexte + touche;
	}

	function presserTouche(touche) {
		// Nettoyage des touches actives
		const touchesActives = emplacementClavier.querySelectorAll('.touche-active');
		[].forEach.call(touchesActives, function (el) {
			el.classList.remove('touche-active');
		});

		emplacementClavier
			.querySelector("bloc-touche[data-touche='" + touche + "']")
			.classList.add('touche-active');
	}

	onMount(() => {
		emplacementClavier = document.getElementById('clavier-emulation');
	});
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
</div>

<EnsembleClavier
	emplacement={'clavier-emulation'}
	type={'iso'}
	couche={'Visuel'}
	couleur={'non'}
	plus={'non'}
	controles={'non'}
/>
<div class="contenu">
	<div class="paragraphe">[Clavier virtuel ici qui remplace ce qu’on tape en azerty]</div>
	<input type="text" id="input-text" on:keydown={emulationClavier} value={champTexte} />
	<p id="output-text" />
</div>

<style>
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
