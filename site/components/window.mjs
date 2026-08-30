// A code listing dressed as an editor window.
//
// The chrome is decoration and says so: the dots are empty `<i>` elements and
// the filename is a label, so a screen reader reads the code and nothing else.

import { html, code } from '../lib/markup.js';

export function codeWindow(filename, source, language = 'javascript') {
	return html`<div class="window">
      <div class="titlebar">
        <span class="dots"><i></i><i></i><i></i></span>
        <span class="filename">${filename}</span>
      </div>
      ${code(source, language)}
    </div>`;
}
