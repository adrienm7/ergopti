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
</script>

<svelte:head>
	<title>Contact</title>
	<meta
		name="description"
		content="Contactez l’auteur de la disposition HyperTexte sur cette page"
	/>
</svelte:head>

<div class="contenu">
	<h1 data-aos="zoom-in" data-aos-mirror="true">Contact</h1>
	<div class="encadre text-center">
		<!-- Vous pouvez contacter l’auteur de cette disposition à l’adresse <a
			href="mailto:moyaux.adrien@gmail.com">moyaux.adrien@gmail.com</a
		> -->
		Utilisez le formulaire <a href="https://beseven.fr/contact">ici</a> pour contacter l’auteur de la
		disposition HyperTexte.
	</div>
</div>
