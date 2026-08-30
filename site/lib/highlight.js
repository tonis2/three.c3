// Syntax highlighting, kept out of the markup pipeline.
//
// Nothing that renders a code block knows a highlighter exists. A block is
// written as `<pre><code class="language-js">`, which is the markup Markdown
// and MDN both describe, and this walks the DOM afterwards and colours what it
// finds. So the language is an attribute in the HTML, the colours are classes
// in the stylesheet, and neither the templates nor the Markdown renderer call
// into a highlighter to get them.
//
// `manual` has to be set before Prism's core module body runs — it reads
// `window.Prism.manual` once, at init — and ES imports are hoisted above
// statements, so it lives in its own module imported first. Without it Prism
// highlights once on DOMContentLoaded, which for a page that renders after that
// and re-renders on every route is the wrong moment every time.

import './prism-manual.js';
import Prism from 'prismjs/components/prism-core.js';
import 'prismjs/components/prism-clike.js';
import 'prismjs/components/prism-javascript.js';
import 'prismjs/components/prism-bash.js';

// A block is highlighted once. Re-running over a whole route on every keystroke
// in the search box would be the reference's 39 code blocks re-tokenised for
// nothing; Lit builds a fresh <code> when the content actually changes, and a
// fresh element has no mark on it.
export function highlight(root) {
	for (const block of root.querySelectorAll('code[class*="language-"]:not([data-lit])')) {
		block.setAttribute('data-lit', '');
		Prism.highlightElement(block);
	}
}
