<*
 How the headset draws, in one place both builds compile: the Quest entry
 (`android/entry.c3`, `xr/loop.c3`) draws with it, and the desktop's `--quest`
 draws the same way at a desk, so a picture that looks wrong in the headset can be
 looked at, and fixed, on the desktop.

 What the desktop cannot copy is the display end: foveation, which needs the
 headset's density map, and Super Resolution, the compositor's upscale and sharpen.
 The desktop upscales its target to the window bilinearly instead.
*>
module three;

import std::math;

// Of the runtime's recommended eye size, 1680x1760 on Quest 3. The game's table
// draws in 7.6 ms at this size over passthrough (GPU level 2, 74% busy at 72 Hz),
// against 5.6 ms at 0.7.
const float XR_RENDER_SCALE = 1.0f;

// Samples per pixel for the eyes: 4x MSAA, kept on the tile and resolved there.
const uint XR_MSAA = 4;

// A Quest 3 eye as its runtime reports it: 1760 rows recommended, over a view 44
// degrees up and 55 down (`xr: left eye fov` on the headset: 0.7679 and -0.9599
// rad). The span is the two tangents added, which is what the rows are spread over.
const float QUEST3_EYE_ROWS = 1760.0f;
const float QUEST3_EYE_TAN_SPAN = 0.9657f + 1.4281f;

<*
 The two pass settings the headset draws with.

 No depth prepass: Adreno bins the frame and builds a coarse depth of all of it
 (LRZ) before shading, which throws away hidden fragments without one, so the
 prepass there mostly doubled the vertex work - the binning pass ran every vertex
 twice per eye. `examples/vr_bench.js`: a 400k-triangle scene 15 ms with it and
 8.5 ms without; four overlapping walls cheaper without it too. A script can
 still turn it on.

 Shadows with one hardware-filtered tap: the four taps against the receiver's
 plane were 3.2 ms of a 7.7 ms frame on the game's table, and one tap 1.0 ms, with
 the same 2x2 filter and no difference anyone could see at the headset's shadow
 distances (`SKIP_RECEIVER_PLANE`).
*>
fn void Renderer.use_headset_passes(&self)
{
	self.pass.prepass.enabled = false;
	self.pass.one_tap_shadows = true;
	self.profile.depth_prepass = false;
	self.profile.shadow_filter = ShadowFilter.ONE_TAP;
}

<*
 Draw as a Quest 3 eye does at `eye_scale` of its recommended size: the headset's
 passes, and a target that follows the camera's field of view at the eye's
 pixels per degree instead of following the window. The target must already have
 the eye's samples, which only `Engine.open` gives it.

 @param eye_scale : `What debug.three.xr_scale would say: XR_RENDER_SCALE is what the headset renders.`
 @require eye_scale > 0.0f : "The eye scale must be positive"
*>
fn void Renderer.draw_like_quest(&self, float eye_scale)
{
	self.use_headset_passes();
	self.headset_density = eye_scale * QUEST3_EYE_ROWS / QUEST3_EYE_TAN_SPAN;
	self.profile.headset_density = self.headset_density;
}

<*
 Rows of target that put `density` pixels on each unit of view tangent across a
 vertical field of view of `fov` degrees: what the window gets under `--quest`.
 The centre of the view is where the two agree exactly, as it is the part a
 player looks at.

 @param density : `Pixels per unit of tangent, at the centre of the view.`
 @param fov : `The camera's vertical field of view, in degrees.`
 @require density > 0.0f : "The density must be positive"
 @ensure return > 0
*>
fn uint headset_rows(float density, float fov)
{
	double want = (double)density * 2.0 * math::tan(math::deg_to_rad((double)fov) * 0.5) + 0.5;
	if (want < 1.0) return 1;
	if (want > (double)RENDER_MAX_SIDE) return (uint)RENDER_MAX_SIDE;
	return (uint)want;
}
