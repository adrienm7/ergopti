<script>
	// import nodemailer from 'nodemailer';
	// import { onMount } from 'svelte';

	// onMount(() => {
	// 	const transporter = nodemailer.createTransport({
	// 		host: 'mail.beseven.fr', // Remplacez par le nom de votre serveur SMTP
	// 		port: 465, // Remplacez par le port de votre serveur SMTP
	// 		secure: false,
	// 		auth: {
	// 			user: 'hypertexte@beseven.fr', // Remplacez par votre nom d'utilisateur SMTP
	// 			pass: '~=qqrVHC_wS8' // Remplacez par votre mot de passe SMTP
	// 		}
	// 	});

	// 	let name = 'uie';
	// 	let email = 'aie@meu.fr';
	// 	let message = 'uei';

	// 	const mailOptions = {
	// 		from: email,
	// 		to: 'moyaux.adrien@gmail.com',
	// 		subject: `Message from ${name}`,
	// 		text: message
	// 	};

	// 	transporter.sendMail(mailOptions);
	// });
	import Nom from '$lib/composants/Nom.svelte';
	import NomPlus from '$lib/composants/NomPlus.svelte';
	import SFB from '$lib/composants/SFB.svelte';
</script>

<svelte:head>
	<title>Informations</title>
	<meta name="description" content="Informations sur la disposition HyperTexte" />
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Informations sur la disposition</h1>
	<h2 data-aos="zoom-out" data-aos-mirror="true">Genèse et Sources</h2>
	<p>
		La genèse de la disposition <Nom></Nom> remonte à 2022, à la suite de la découverte d'Optimot. Les
		premières versions de ce projet, baptisées Optim7, étaient des dérivés directs d'Optimot. L'objectif
		initial était de peaufiner légèrement les scores sur les analyseurs de dispositions existants. À
		cette époque, étant utilisateur de la disposition BÉPO, l'idée d'apprendre Optimot, pour peut-être
		découvrir encore une version améliorée par la suite, était peu attrayante. La meilleure façon de
		m’assurer de ne pas avoir à passer mon temps à apprendre de nouvelles dispositions était de créer
		la mienne, optimisée pour mes besoins, même si cela nécessitait un investissement en temps considérable.
	</p>
	<p>
		Rapidement, <Nom></Nom> s'est éloigné d'Optimot sur plusieurs aspects fondamentaux. L'un des points
		clés était ma volonté d'optimiser les <em>roulements</em>, entraînant de nombreux tests sur la
		disposition des touches principales, notamment sur la partie droite avec les consonnes. L'une
		des décisions majeures fut de privilégier un agencement SNTR plutôt que TSRN, car le bigramme NT
		est très fréquent, et il semblait pertinent de l'optimiser pour qu'il se réalise sur des doigts
		consécutifs. L’agencement final des quatre lettres de la rangée principale a été soigneusement
		conçu pour maximiser les bigrammes consonantiques, avec une disposition harmonieuse. Seuls les
		bigrammes ST et TS (comme dans "STaTS") ne profitent pas de cette optimisation en roulement.
	</p>
	<p>
		De plus, un grand nombre de touches mortes et de caractères spéciaux présents dans le pilote
		d'Optimot ont été supprimés, ne conservant que l'essentiel. Cette simplification a permis de
		libérer de nombreux emplacements sur la couche <bkd>AltGr</bkd>. Les symboles, auparavant peu
		accessibles sur la rangée numérique, ont été déplacés pour être plus facilement atteints sous la
		couche <kbd>AltGr</kbd>, tandis que les chiffres sont désormais directement accessibles, un
		changement très appréciable lors de l'utilisation quotidienne.
	</p>
	<h3 data-aos="fade-right" data-aos-mirror="true">Évolution incrémentale</h3>
	<p>
		À un certain stade de développement, il devint évident que la disposition n'était plus
		simplement une variante d'Optimot. Le besoin de renommer ce projet s’est alors imposé. Grâce à
		la suggestion d’un utilisateur nommé Zigmund sur Discord, le nom <Nom></Nom> a été retenu, après
		avoir longtemps cherché une alternative aussi marquante que celui d’Optimot.
	</p>
	<p>
		Bien que la création de <Nom></Nom> ait été un processus étalé sur plusieurs mois, près de 80% de
		la disposition est restée constante. Les ajustements concernaient principalement le déplacement de
		certaines lettres, nécessitant ainsi des phases de réapprentissage régulières. Néanmoins, la plupart
		des changements se sont avérés non pertinents, ce qui explique l'absence de modifications majeures
		entre les premières versions d’Optim7 et la version finale de <Nom></Nom>.
	</p>

	<h3 data-aos="fade-right" data-aos-mirror="true">
		Atouts de <NomPlus></NomPlus>
	</h3>
	<p>
		La singularité de <Nom></Nom> ne réside pas seulement dans ses excellents scores en français, anglais
		et en programmation, où elle rivalise avec les meilleures dispositions actuelles. Sa version étendue,
		<NomPlus></NomPlus>, pousse encore plus loin l’efficacité de cette disposition déjà très
		performante, en la rendant véritablement exceptionnelle. Le qualificatif d’exceptionnel n’est
		pas exagéré : <NomPlus></NomPlus> permet, une fois maîtrisée, de réduire presque totalement les <SFB
		></SFB>s, y compris ceux liés à la répétition d'une même touche. Cela est rendu possible grâce à
		la touche spéciale ★, permettant de réitérer la frappe de la touche précédente avec une fluidité
		inédite.
	</p>
	<p>
		Il convient de préciser que l’idée de cette touche de répétition n’est pas une invention propre,
		mais provient d'une disposition anglophone dont je ne retrouve plus le nom. D'autres éléments
		ont également été empruntés, comme l'utilisation d'AHK (AutoHotKey) dans la disposition Boo,
		pour modifier le comportement des combinaisons de touches. Ce système permet d'optimiser encore
		davantage les roulements sur les touches adjacentes qui n'engendrent pas de bigrammes habituels.
	</p>

	<h2 data-aos="zoom-out" data-aos-mirror="true">Contact</h2>
	<div class="encadre text-center">
		<!-- Vous pouvez contacter l’auteur de cette disposition à l’adresse <a
			href="mailto:moyaux.adrien@gmail.com">moyaux.adrien@gmail.com</a
		> -->
		Le créateur de la disposition <Nom /> et de ce site est <strong>Adrien MOYAUX</strong>.<br />
		Vous pouvez utiliser le formulaire <a href="https://beseven.fr/contact">ici</a> pour le contacter.
	</div>
	<h2 data-aos="zoom-out" data-aos-mirror="true">License</h2>
	<p>À définir</p>
</div>
