export async function getKeyboardData(version) {
	const fileName = `ergopti_v${version}`;
	const filePath = `/dispositions/data/${fileName}.json`;

	console.info(`[KeyboardData] Trying to load file at path "${filePath}"`);

	try {
		const response = await fetch(filePath);
		console.info(
			`[KeyboardData] Response received (status ${response.status}: ${response.statusText})`
		);
		if (!response.ok) {
			throw new Error(`Server responded with an invalid status (${response.status})`);
		}

		let data;
		try {
			data = await response.json();
		} catch (parseError) {
			throw new Error(`Failed to parse JSON from ${fileName}: ${parseError.message}`);
		}

		if (!data || typeof data !== 'object') {
			throw new Error(`File ${fileName} is empty or contains invalid data`);
		}

		console.info(`[KeyboardData] Layout data for ${fileName} successfully loaded`);
		console.debug(`[KeyboardData] Content:`, data);
		return data;
	} catch (error) {
		console.error(`[KeyboardData] Error while loading ${fileName}:`, error);
		return null;
	}
}
