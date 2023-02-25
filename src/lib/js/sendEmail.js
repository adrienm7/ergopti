import nodemailer from 'nodemailer';

export async function sendEmail(name, email, message) {
	const transporter = nodemailer.createTransport({
		host: 'mail.beseven.fr', // Remplacez par le nom de votre serveur SMTP
		port: 465, // Remplacez par le port de votre serveur SMTP
		secure: false,
		auth: {
			user: 'hypertexte@beseven@fr', // Remplacez par votre nom d'utilisateur SMTP
			pass: '~=qqrVHC_wS8' // Remplacez par votre mot de passe SMTP
		}
	});

	const info = await transporter.sendMail({
		from: `"${name}" <${email}>`,
		to: 'moyaux.adrien@gmail.com', // Remplacez par l'adresse e-mail de l'administrateur de votre site
		subject: 'New message from contact form',
		text: message
	});

	console.log(`Message sent: ${info.messageId}`);
}
