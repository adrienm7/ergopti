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
	import Genese from '../accueil/old/genese.svelte';

	import Autocritiques from './autocritiques.svelte';
	import Contact from './contact.svelte';
	import License from './license.svelte';
</script>

<svelte:head>
	<title>Informations</title>
	<meta name="description" content="Informations sur la disposition HyperTexte" />
</svelte:head>

<h1 data-aos="zoom-in" data-aos-mirror="true">Informations sur la disposition <Nom></Nom></h1>
<GeneseSources></GeneseSources>
<Autocritiques></Autocritiques>
<License></License>
<Contact></Contact>
