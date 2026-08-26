<*
 sRGB and linear conversion.

 Shaders decode per fragment on their own (`shaders/mesh.slang`,
 `shaders/material.slang`), so this file exists for the colours that never
 reach one:

 - Clear colours. `vkCmdBeginRendering` writes them straight into an `_SRGB`
   attachment, which encodes on write, so they have to arrive linear.
 - glTF export. `baseColorFactor` is linear by specification, while a script's
   `mesh.color` is sRGB.
 - Test expectations that want to be written in the units the script used.

 The curve here is the exact piecewise sRGB transfer function rather than
 `pow(c, 2.2)`. The approximation is only ~3/255 off measured on its own, but
 the device always *encodes* with the exact curve, so a value decoded by the
 approximation and re-encoded by hardware drifts up to 9/255 — enough to break
 the round trip of setting a background, screenshotting it and reading the same
 bytes back. `the_approximation_would_not_have_survived` measures that drift.
*>
module three;

import std::math;

<*
 sRGB to linear — what a sampler does to a texture, applied to a value that
 never went through a sampler.

 @param c : `One channel, 0..1. Out of range is clamped rather than reflected: a negative raised to a fractional power is NaN, and a NaN clear colour is a black frame with nothing to say why.`
*>
fn float srgb_to_linear(float c)
{
	c = math::clamp(c, 0.0f, 1.0f);
	if (c <= 0.04045f) return c / 12.92f;
	return (float)math::pow((double)((c + 0.055f) / 1.055f), 2.4);
}

<*
 Linear to sRGB — the inverse, and what an `_SRGB` colour attachment does on
 write. Used by tests stating expectations in display units, and by the
 exporter going the other way.

 @param c : `One channel, 0..1. Clamped, for the reason above.`
*>
fn float linear_to_srgb(float c)
{
	c = math::clamp(c, 0.0f, 1.0f);
	if (c <= 0.0031308f) return c * 12.92f;
	return 1.055f * (float)math::pow((double)c, 1.0 / 2.4) - 0.055f;
}

<*
 Decodes rgb and leaves alpha untouched: alpha is a linear coverage fraction,
 not a colour, and running it through the curve is the classic way to make a
 half-transparent thing wrong.
*>
fn float[4] srgb_to_linear_rgb(float[4] c) =>
	{ srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), c[3] };
