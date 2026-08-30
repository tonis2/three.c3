// A copy button on every code block. One listener, delegated.

document.addEventListener('click', async event => {
	const button = event.target.closest('.copy');
	if (!button) return;

	const code = button.parentElement.querySelector('code');
	try {
		await navigator.clipboard.writeText(code.textContent);
		button.textContent = 'Copied';
		button.setAttribute('data-done', '');
	} catch {
		// No clipboard permission, or an insecure origin. Selecting the block
		// is the fallback, so the reader can copy it the ordinary way.
		const range = document.createRange();
		range.selectNodeContents(code);
		const selection = getSelection();
		selection.removeAllRanges();
		selection.addRange(range);
		button.textContent = 'Selected';
	}
	setTimeout(() => { button.textContent = 'Copy'; button.removeAttribute('data-done'); }, 1600);
});
