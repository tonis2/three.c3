<*
 sRGB and linear, in C3.

 **The shaders own the hot path; this file is for the places a colour crosses
 without passing through one.** `shaders/mesh.slang` and
 `shaders/material.slang` each carry their own `srgb_to_linear`, because a
 per-fragment decode is free on the device and because the two shaders must not
 be able to disagree. Three things convert on this side instead:

 - **The clear colour.** It never reaches a shader — `vkCmdBeginRendering`
   writes it, and an `_SRGB` attachment encodes it on the way in, so it has to
   arrive linear like everything else the target stores.
 - **glTF export.** `baseColorFactor` is defined linear by the glTF
   specification, so writing a script's `mesh.color` there raw is writing an
   sRGB number into a linear field. Before the target became `_SRGB` this was a
   genuine fork — the number that matched this engine and the number that
   matched a colour-managed viewer were different — and closing that fork is
   half of why the target moved.
 - **Anything a test wants to state in the same units the script did.**

 ## Why the piecewise curve and not `pow(c, 2.2)`

 Because the hardware does the piecewise one, and the property worth having is
 that a colour survives its own round trip: set a background, screenshot it, read
 the same bytes back.

 Compared against the real curve directly, `pow(c, 2.2)` is off by about 3
 eight-bit levels at worst, which sounds ignorable. That comparison is the wrong
 one. The device encodes with the exact curve no matter what this file decoded
 with, so the number that matters is what a value loses going out through the
 hardware after coming in through the approximation: **up to 9 levels, worst
 around 15/255**. `the_approximation_would_not_have_survived` measures exactly
 that, so the reasoning here cannot rot into "close enough" without a test going
 red to say so.
*>
module three;

import std::math;

<*
 sRGB to linear: what the sampler does to a texture, applied to a number that
 did not come through a sampler.

 @param c : `One channel, 0..1. Out of range is clamped rather than reflected: a negative raised to a fractional power is a NaN, and a NaN clear colour is a black frame with nothing to say why.`
*>
fn float srgb_to_linear(float c)
{
	c = math::clamp(c, 0.0f, 1.0f);
	if (c <= 0.04045f) return c / 12.92f;
	return (float)math::pow((double)((c + 0.055f) / 1.055f), 2.4);
}

<*
 Linear to sRGB: the inverse, and what the `_SRGB` colour attachment does on
 write. Here so a test can state an expectation in the units the eye uses, and
 so the exporter can go back the other way when it has to.

 @param c : `One channel, 0..1. Clamped, for the reason above.`
*>
fn float linear_to_srgb(float c)
{
	c = math::clamp(c, 0.0f, 1.0f);
	if (c <= 0.0031308f) return c * 12.92f;
	return 1.055f * (float)math::pow((double)c, 1.0 / 2.4) - 0.055f;
}

<*
 The rgb of a colour, decoded. Alpha is not a colour and is never transferred —
 it is already a linear coverage fraction, and putting it through the curve is
 the classic way to make a half-transparent thing the wrong kind of wrong.
*>
fn float[4] srgb_to_linear_rgb(float[4] c) =>
	{ srgb_to_linear(c[0]), srgb_to_linear(c[1]), srgb_to_linear(c[2]), c[3] };
