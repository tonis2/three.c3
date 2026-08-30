// Light DOM rather than shadow DOM.
//
// The site has one stylesheet and these components are made of its classes —
// `.picker`, `.slide`, `.dots` — so an element that hid inside a shadow root
// would need a copy of the CSS to look like the page it is sitting in.

import { LitElement } from 'lit';

export class LightElement extends LitElement {
	createRenderRoot() {
		this.replaceChildren();
		return this;
	}
}
