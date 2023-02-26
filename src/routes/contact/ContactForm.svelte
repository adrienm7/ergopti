<script>
	import { sendEmail } from '$lib/js/sendEmail';

	let name = 'Moi';
	let email = 'ieau@eua.fr';
	let message = 'ieau ,ighta';
	let sent = false;

	const onSubmit = async (event) => {
		event.preventDefault();
		await sendEmail(name, email, message);
		sent = true;
	};
</script>

{#if sent}
	<p>Thank you for your message!</p>
{:else}
	<form on:submit={onSubmit}>
		<label>
			Your Name:
			<input type="text" bind:value={name} required />
		</label>

		<label>
			Your Email:
			<input type="email" bind:value={email} required />
		</label>

		<label>
			Your Message:
			<textarea bind:value={message} required />
		</label>

		<button type="submit">Send</button>
	</form>
{/if}
