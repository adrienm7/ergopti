var nodemailer = require('nodemailer');

const transporter = nodemailer.createTransport({
	host: 'mail.beseven.fr', // Remplacez par le nom de votre serveur SMTP
	port: 465, // Remplacez par le port de votre serveur SMTP
	secure: false,
	auth: {
		user: 'hypertexte@beseven@fr', // Remplacez par votre nom d'utilisateur SMTP
		pass: '~=qqrVHC_wS8' // Remplacez par votre mot de passe SMTP
	}
});

export async function sendMail({ name, email, message }) {
	const mailOptions = {
		from: email,
		to: 'moyaux.adrien@gmail.com',
		subject: `Message from ${name}`,
		text: message
	};

	return transporter.sendMail(mailOptions);
}
