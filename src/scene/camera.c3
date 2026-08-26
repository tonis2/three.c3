<*
 A turntable camera, and how it frames what it is shown.

 Deliberately the smallest camera that does the job: yaw, pitch, roll, a target
 and a boom length.

 `frame_bounds` is the part worth keeping either way. An agent that loads a model
 has no idea how big it is — a kit piece is a metre across, a terrain tile is a
 kilometre — so the default view has to be derived from the geometry rather than
 guessed, or the first render of every unfamiliar asset is an empty screen with
 the model either inside the near plane or a speck at the horizon.
*>
module three;

import std::math;
import std::math::vector;
import std::math::matrix;
import collision;

struct Camera
{
	Vec3 target;
	float distance;
	// Degrees. Yaw turns around +Y, pitch lifts the eye above the horizon.
	float yaw;
	float pitch;

	<*
	 Degrees around the view direction. Zero is level, and level is what
	 everything that does not set this gets.

	 The third angle, and not a fourth setter on `orbit`: yaw and pitch aim the
	 camera and are what a drag writes, while roll does not aim it at all — it
	 turns the picture. A turntable has no use for it; a cockpit in a banking
	 aircraft and a turret on a listing ship are the cases where a level horizon
	 is the wrong answer.

	 A plain field with no clamp. Yaw wraps and pitch is held a degree off the
	 pole because both protect `look_at` from a degenerate basis; roll cannot
	 produce one — it rotates the up vector *around* the forward axis, so the
	 cross product it feeds is never near zero however far it is wound.
	*>
	float roll;

	float fov;
	float near_plane;
	float far_plane;
}

fn Camera default_camera()
{
	return {
		.target = { 0, 0, 0 },
		.distance = 3.0,
		.yaw = 35.0,
		.pitch = 20.0,
		.fov = 45.0,
		.near_plane = 0.01,
		.far_plane = 1000.0,
	};
}

// How far the eye may be lifted, in degrees. One short of the pole, and the
// missing degree is load-bearing: at exactly 90 the eye sits on the up axis,
// `look_at`'s cross product is zero, and the view matrix comes back full of NaN.
// Nothing errors — the frame renders empty, which reads as "the scene is gone".
const float CAMERA_PITCH_LIMIT = 89.0f;

<*
 How much room `frame_bounds` leaves around what it framed. 1.0 is a fit with the
 outermost corner exactly on the frustum wall.

 It scales the lateral requirement, not the finished distance, and the two are
 only the same thing for a box whose corners all sit near the target's depth. A
 corner leaning towards the eye is seen at a fraction of the orbit distance, so a
 percentage added to the distance arrives as a large multiple of *that corner's*
 depth: framing a 60-unit box end-on, where the near face sits 1.4 units in front
 of a 31-unit orbit, 5% on the distance more than doubled the near face's depth
 and halved the picture. Applied to the requirement it is 5% of the frame, at
 every shape and every angle.
*>
const float FRAME_MARGIN = 1.05f;

fn Vec3 Camera.eye(&self) => self.target + self.orbit_dir() * self.distance;

<*
 The unit vector from the target towards the eye, from the orbit angles alone.

 Split out of `eye` because two callers need the direction at a moment when the
 distance is not to be trusted: `basis` is asked for the screen axes by a pan
 that may have dollied all the way in, and `frame_bounds` is *choosing* the
 distance. Recovering it by normalizing `target - eye()` gives the same vector
 whenever the distance is positive and NaN when it is zero.
*>
fn Vec3 Camera.orbit_dir(&self)
{
	float yaw        = math::deg_to_rad(self.yaw);
	float pitch      = math::deg_to_rad(self.pitch);
	float horizontal = math::cos(pitch);
	return { horizontal * math::sin(yaw), math::sin(pitch), horizontal * math::cos(yaw) };
}

<*
 Keeps the eye off the pole and the yaw in [-180, 180).

 The yaw wrap is not cosmetic. Yaw accumulates one drag delta at a time and
 nothing else resets it, so a long session walks it into the thousands, where a
 float's spacing is coarse enough that a slow drag starts to step.
*>
fn void Camera.clamp_angles(&self)
{
	self.pitch = math::clamp(self.pitch, -CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT);
	self.yaw -= 360.0f * math::floor((self.yaw + 180.0f) / 360.0f);
}

<*
 Puts the near and far planes back where the distance and the scene say they
 belong.

 The planes are derived, never set. A fixed near plane against a model a
 kilometre wide spends the whole depth buffer on the first few metres, which is
 z-fighting across the entire scene and reads as a rendering bug rather than a
 camera setting.

 ## `reach`

 `distance * 8` alone is a guess about how big the scene is, made from the only
 number this struct has, and it is wrong in one direction with an invisible
 failure: a sky 190 units across stops being drawn the moment the camera dollies
 in to 20, because the far plane followed the camera down to 160. That looks like
 a skybox that works at some zoom levels and vanishes at others, which reads as a
 winding or culling bug.

 So the caller may say how far away the furthest thing it intends to draw is, and
 `MeshPass.derive_camera_planes` is the one that knows. The multiple stays as the
 floor, so an empty scene and a scene whose bounds have not been walked yet
 behave exactly as they did before.

 The near plane is deliberately not raised to match. Widening `far` costs depth
 precision at the far end, and pushing `near` out to buy it back would clip
 whatever the camera is close to — geometry that quietly disappears is a worse
 failure than two distant coplanar faces flickering.

 `frame_bounds` does *not* call this: it knows the model's radius and is fitting
 the distance at the same time, so it can put the far plane just beyond the
 geometry instead of at a multiple of anything.

 @param reach : `World-space distance from the eye to the furthest thing worth drawing. Zero to derive from the orbit distance alone.`
*>
fn void Camera.derive_planes(&self, float reach = 0.0f)
{
	// First person cannot derive either plane from the boom, because there is no
	// boom. Both rules above are multiples of `distance`, so at zero they give a
	// near of 0.0001 and a far of whatever `reach` happened to be — a depth ratio
	// in the millions, which spends the whole buffer on the first centimetre.
	// Five centimetres is a statement about *eyes*: nearer than a head gets to a
	// wall it is standing against. The far floor keeps an empty scene projectable
	// at all — `reach` is zero before the bounds have been walked, and a far plane
	// at the near plane is a projection matrix full of infinities.
	if (self.distance <= 0.0f)
	{
		self.near_plane = FIRST_PERSON_NEAR;
		self.far_plane = math::max(reach, FIRST_PERSON_NEAR * 1000.0f);
		return;
	}

	self.near_plane = math::max(self.distance * 0.001f, 0.0001f);
	self.far_plane = math::max(self.distance * 8.0f, reach);
}

// The near plane when the eye is the anchor. See `derive_planes`.
const float FIRST_PERSON_NEAR = 0.05f;

<*
 Which way is up for this camera, in world space.

 World +Y until `roll` is set, and the one function that decides it. `view`,
 `basis` and `view_bounds` spelling `{ 0, 1, 0 }` inline is how a rolled view
 matrix ends up disagreeing with a rolled pan: the picture leans and the drag
 does not, which reads as the mouse being broken.

 Rodrigues around the forward axis, well conditioned at every roll because `up`
 and `forward` are perpendicular by construction — the sine term is the
 full-length `right` vector, and the degeneracy the pitch clamp guards against
 cannot arise here.
*>
fn Vec3 Camera.up(&self)
{
	if (self.roll == 0.0f) return { 0, 1, 0 };

	Vec3 forward = self.orbit_dir() * -1.0f;
	Vec3 sideways = forward.cross((Vec3) { 0, 1, 0 });
	// Same fallback as `basis`, and for the same reason: a caller may write
	// `pitch` past the clamp directly, and a NaN up vector is an empty frame.
	if (sideways.length() < 1e-6f) sideways = (Vec3) { 1, 0, 0 };
	sideways = sideways.normalize();
	Vec3 level = sideways.cross(forward);

	float angle = math::deg_to_rad(self.roll);
	return level * math::cos(angle) + sideways * math::sin(angle);
}

<*
 The camera's right and up axes in world space.

 Rolled, because a pan is a drag across the *picture* and the picture is what
 `roll` turns. Dragging along a rolled view's screen X and having the target move
 along an unrolled world axis is the disagreement `Camera.up` exists to prevent.

 @param right : `Out. Screen +X, world space, normalized.`
 @param up : `Out. Screen +Y, world space, normalized.`
*>
fn void Camera.basis(&self, Vec3* right, Vec3* up)
{
	Vec3 forward = self.orbit_dir() * -1.0f;
	Vec3 sideways = forward.cross(self.up());

	// The pitch clamp normally keeps this from happening, but the clamp is applied
	// where angles are *written* and a caller can reach these fields directly. A
	// zero-length cross would normalize to NaN and silently poison the target.
	if (sideways.length() < 1e-6f) sideways = (Vec3) { 1, 0, 0 };

	*right = sideways.normalize();
	*up = right.cross(forward);
}

<*
 How much world space one screen point covers, at the distance the camera is
 focused on.

 This is what makes a pan track the cursor rather than merely follow it: the
 point under the mouse when the drag started is the point under the mouse for the
 whole drag, at any distance and any field of view.

 @param viewport_height : `The viewport's height in the same units the pointer is reported in.`
*>
fn float Camera.world_per_point(&self, float viewport_height)
{
	if (viewport_height < 1.0f) return 0.0f;
	float visible = 2.0f * self.distance * math::tan(math::deg_to_rad(self.fov) * 0.5f);
	return visible / viewport_height;
}

<*
 The view matrix, from either end of the boom.

 A boom of zero length is first person, and that is the whole of what first
 person is here. `distance` means how far the eye is from the point it orbits, so
 taking it to zero puts the eye *on* that point — a character's head, once
 `CameraFollow` is writing the point every frame. Nothing else changes: yaw and
 pitch still aim it, `orbit()` still turns it, and a script that scrolls back out
 is in third person again with no mode to switch.

 What cannot survive it is `look_at`, whose forward vector is `target - eye` —
 the zero vector at distance zero, and a matrix full of NaN. So the direction
 comes from the orbit angles through `orbit_dir` instead.
*>
fn Matrix4f Camera.view(&self)
{
	Vec3 eye = self.eye();
	Vec3 at = self.distance > 0.0f
		? self.target
		// One unit along the way the camera is already pointing. The length is
		// arbitrary and cancels: `look_at` normalizes.
		: eye - self.orbit_dir();
	return matrix::look_at{float}(eye, at, self.up());
}

<*
 `std::math::matrix` builds a right-handed, [0,1]-depth projection with +Y up —
 glm's convention. Vulkan's clip space has +Y down.

 There is no Y flip here: `gpu/target.c3` binds a negative-height viewport, which
 does the same job at the other end. Doing both would cancel out and render the
 model upside down.
*>
fn Matrix4f Camera.projection(&self, float aspect)
{
	return matrix::perspective{float}(math::deg_to_rad(self.fov), aspect, self.near_plane, self.far_plane);
}

fn Matrix4f Camera.view_projection(&self, float aspect)
{
	return self.projection(aspect) * self.view();
}

<*
 Aims at the middle of a bounding box and backs off far enough to see all of it.

 The exact fit, against both half-angles. Every corner of the box is projected
 onto the screen axes and onto the view axis, and the distance kept is the
 largest any one corner asks for. `toward` is the part of a corner's offset that
 leans towards the eye: a near corner is seen at a shallower depth than the
 target and so needs *more* distance for the same lateral offset, which is why
 the binding corner is usually a near one rather than the furthest.

 The two ways to get this wrong, both of which overshoot and compound:

 - Fitting the bounding *sphere* through the corners. That is the tightest bound
   holding whichever way the camera is turned, which is only worth paying for if
   the camera is going to turn — and this runs on `frameAll`, at a known
   orientation. Framing a cube by its corner sphere spends a factor of sqrt(3).
 - Fitting the vertical half-angle alone. It is the one the projection is
   specified by, but only the *narrower* of the two on a frame wider than it is
   tall; on 16:9 the horizontal is nearly twice as wide and is left empty, and on
   a portrait frame the never-fitted horizontal lets the silhouette run off the
   sides.

 The cost of the exact fit is what the sphere was bought for: it is good at the
 orientation it was made at, and orbiting afterwards can carry a long box's ends
 out of frame. That is the normal behaviour of a framing helper.

 The margin is `FRAME_MARGIN`, applied to each corner's lateral requirement
 rather than to the distance that comes out — see its header.

 The near and far planes are re-derived from the distance. `far` keeps using the
 corner radius, because unlike the fit it genuinely must hold at any orientation:
 `MeshPass.derive_camera_planes` re-derives it during a drag, and a far plane
 that breathed as the turntable turned would pop distant geometry in and out.

 @param min : `Corner of the model's axis-aligned bounds, model space.`
 @param max : `The opposite corner.`
 @param aspect : `Viewport width divided by height. Non-positive is read as 1, which fits the vertical alone and is what a caller with nothing to measure should want.`
*>
fn void Camera.frame_bounds(&self, Vec3 min, Vec3 max, float aspect = 1.0f)
{
	self.target = (min + max) * 0.5f;

	Vec3 half = (max - min) * 0.5f;
	float radius = half.length();
	// A box with no size at all — one point, or a scene holding nothing — has no
	// fit to compute. A unit box keeps every expression below away from a divide
	// by zero.
	if (radius <= 0.0f)
	{
		half = { 1, 1, 1 };
		radius = half.length();
	}

	float tan_v = math::tan(math::deg_to_rad(self.fov) * 0.5f);
	// Spelled as a negated `>` rather than `<= 0` so a NaN lands here too: a
	// target measured at zero height divides to one, and NaN fails every
	// comparison, so `<= 0` would wave it through into `tan_h` and make the whole
	// fit NaN — a camera at no distance, which renders an empty frame and says
	// nothing about why.
	if (!(aspect > 0.0f)) aspect = 1.0f;
	float tan_h = tan_v * aspect;

	Vec3 to_eye = self.orbit_dir();
	Vec3 right, up;
	self.basis(&right, &up);

	float needed = 0.0f;
	for (int i = 0; i < 8; i++)
	{
		Vec3 corner = {
			(i & 1) != 0 ? half.x : -half.x,
			(i & 2) != 0 ? half.y : -half.y,
			(i & 4) != 0 ? half.z : -half.z,
		};
		float toward = corner.dot(to_eye);
		float v = math::abs(corner.dot(up));
		float h = math::abs(corner.dot(right));
		needed = math::max(needed, toward + v * FRAME_MARGIN / tan_v);
		needed = math::max(needed, toward + h * FRAME_MARGIN / tan_h);
	}

	self.distance = needed;
	// Only reachable if every corner asked for a non-positive distance, which the
	// degenerate-box guard above already rules out. Kept because the alternative
	// to a cheap floor is an eye sitting on its own target, which `look_at`
	// answers with a matrix of NaN and an empty frame.
	if (self.distance <= 0.0f) self.distance = radius;

	self.near_plane = math::max(self.distance * 0.001f, 0.0001f);
	self.far_plane = self.distance + radius * 4.0f;
}

<*
 A camera that tracks something instead of standing still.

 The whole of "attach": a node whose world position the camera's orbit point
 follows, an offset from it, and how sluggishly.

 ## It writes one field, and that is what makes it compose

 The follow writes `Camera.target` and nothing else. So a drag still orbits, a
 wheel still zooms, `three.camera.orbit()` still aims — none of them touch the
 target — and first person is not a mode here at all: it is `distance` at zero,
 which puts the eye on the point being followed. Third person, first person, and
 scrolling between the two are one code path.

 A pan is the one gesture that stops working, because a pan is the one that
 writes the target: `Controls` moves it and the next tick moves it back. That is
 not silent — the picture visibly refuses to slide — and the answer is
 `three.camera.detach()`, or `three.controls.enabled = false` for a scene that
 owns the camera outright.

 The offset is in world space by default. A head is `[0, 1.7, 0]` above a
 character's origin whichever way it faces, which covers first person and the
 shoulder height a third-person boom orbits around. What world space cannot
 express is a camera bolted *into* something that pitches and rolls — that is
 `local_offset`.
*>
struct CameraFollow
{
	bool active;
	NodeId node;
	Vec3 offset;

	<*
	 Whether `offset` is read in the followed node's own frame rather than in the
	 world's — `camera.attach(obj, { local: true })`.

	 A world offset of `[0, 1.7, 0]` is a head and is correct whichever way a
	 character faces, which is why it is the default. `[0, 1.2, 0.4]` in the
	 *pilot's* frame is a seat; in the world's frame it is a seat that slides out
	 through the fuselage as the aircraft turns. The same distinction separates a
	 shoulder camera from a turret.

	 One 3x3 multiply, by the node's world matrix with the translation column left
	 out — so it carries the node's rotation *and its scale*, which is deliberate:
	 a seat inside a model scaled to half size is at half the offset, and the
	 alternative is an offset that means something different depending on what
	 units the asset was authored in.

	 The camera's own roll is not touched by this. Banking the picture with the
	 aircraft is `three.camera.roll`, written from the script each frame, and the
	 two are separate because a turret wants the offset and a level horizon.
	*>
	bool local_offset;

	<*
	 The time constant of the catch-up, in milliseconds. Zero is rigid.

	 Exponential rather than a fraction per frame: the same lag has to mean the
	 same *lateness in seconds* at 60 Hz and at 144, and a fixed fraction per
	 frame is twice as fast on the faster display.
	*>
	float lag_ms;
}

// The lag step is integrated over a clamped delta, for the reason `Controls`
// clamps its coast: a frame that took a second — a tool call ran to completion on
// the same loop — would otherwise snap the camera the whole way and read as a
// teleport rather than as a catch-up.
const float FOLLOW_MAX_STEP_MS = 100.0f;

<*
 Moves the orbit point towards where the followed thing is now.

 @param anchor : `The followed node's world position. The offset is added here, not by the caller.`
 @param dt_ms : `Milliseconds since the last call. Zero or less snaps, because there is no time for a lag to be a lag over.`
*>
fn void CameraFollow.apply(&self, Camera* camera, Vec3 anchor, float dt_ms)
{
	self.settle(camera, anchor + self.offset, dt_ms);
}

<*
 The same, from the followed node's world matrix rather than from its position.

 The form `local_offset` needs, and the reason there are two entry points: a
 world-space offset only ever needed the translation, so a caller could hand over
 three floats. An offset in the node's own frame needs the rotation and the scale
 as well, and there is no way to spell that as a `Vec3`.

 `apply` above is kept for callers that genuinely have only a point — the tests,
 which construct a follow with no node behind it.

 @param world : `The followed node's world matrix, column-major, as Node.world holds it.`
*>
fn void CameraFollow.apply_world(&self, Camera* camera, Matrix4f world, float dt_ms)
{
	float[<16>] m = world.m;
	Vec3 anchor = { m[12], m[13], m[14] };

	Vec3 offset = self.offset;
	if (self.local_offset)
	{
		// The upper 3x3, applied as a direction: the translation column is already
		// `anchor`, and adding it twice would put a seat at twice the aircraft's
		// position — which away from the origin reads as the camera being flung
		// into the distance the moment `local` is set.
		offset = (Vec3) {
			m[0] * self.offset.x + m[4] * self.offset.y + m[8] * self.offset.z,
			m[1] * self.offset.x + m[5] * self.offset.y + m[9] * self.offset.z,
			m[2] * self.offset.x + m[6] * self.offset.y + m[10] * self.offset.z,
		};
	}

	self.settle(camera, anchor + offset, dt_ms);
}

<*
 Moves the orbit point towards `want`, at the lag.

 Split out so the two entry points above cannot drift on the one thing that is
 actually a decision — how the catch-up is integrated — while differing on the
 one thing that genuinely is different, which is where `want` came from.
*>
fn void CameraFollow.settle(&self, Camera* camera, Vec3 want, float dt_ms)
{
	if (self.lag_ms <= 0.0f || dt_ms <= 0.0f)
	{
		camera.target = want;
		return;
	}

	float step = math::min(dt_ms, FOLLOW_MAX_STEP_MS);
	// 1 - e^(-t/τ): the fraction of the remaining distance to close this frame.
	float t = 1.0f - math::exp(-step / self.lag_ms);
	camera.target = camera.target + (want - camera.target) * t;
}

<*
 The world box of everything this camera can see, out to `reach`.

 A shadow map fitted around `Scene.bounds` spends its texels on the whole level;
 a village is 224 units across and the camera frames about 70 of them, so nine
 tenths of the map is rasterised into and never sampled. This is the box that
 says which tenth is worth having.

 Built from the camera's own fields rather than from the inverse of its
 view-projection: the eight corners are `eye + forward * d ± right * w ± up * h`
 at two depths, which is four multiplies rather than a matrix inversion, and it
 cannot disagree with `view()` about handedness because it comes from the same
 `orbit_dir`. The basis is `look_at`'s: forward towards the target, right the
 cross with world up, up the cross back.

 The result is conservative and axis-aligned, which is the right shape for what
 reads it: intersecting it with the scene's own box is two `min`/`max` pairs, and
 a tighter hull would buy texels that the square, snapped fit in `ShadowMap.fit`
 immediately gives back.

 @param aspect : `Width over height, the same number view_projection is given. A different one here would size the box for a frame nobody is drawing.`
 @param reach : `How far down the view direction to bother with, in world units. 0 or more than the far plane means the far plane — which for the default camera is 1000 units and is why shadow.distance exists.`
*>
fn collision::Aabb3 Camera.view_bounds(&self, float aspect, float reach = 0)
{
	Vec3 back    = self.orbit_dir();
	Vec3 forward = -back;
	// `look_at` builds its basis this way round, and at the 89-degree pitch limit
	// the cross product is still well conditioned.
	//
	// Rolled, through `Camera.up`, so the box is around the frustum the frame is
	// actually drawn with. A roll rotates the frustum about its own axis and the
	// axis-aligned box around it genuinely changes — for a wide field of view, by
	// up to a factor of the aspect ratio.
	Vec3 right = forward.cross(self.up()).normalize();
	Vec3 up    = right.cross(forward);

	float near = self.near_plane;
	float far  = self.far_plane;
	if (reach > 0.0f && reach < far) far = reach;
	if (far <= near) far = near + 1.0f;

	float tan_half = math::tan(math::deg_to_rad(self.fov) * 0.5f);
	Vec3 eye = self.eye();

	collision::Aabb3 box = collision::NEW_AABB3;
	float[2] depths = { near, far };
	foreach (d : depths)
	{
		float h = d * tan_half;
		float w = h * aspect;
		Vec3 centre = eye + forward * d;
		float[2] signs = { -1.0f, 1.0f };
		foreach (sx : signs)
		{
			foreach (sy : signs)
			{
				Vec3 corner = centre + right * (w * sx) + up * (h * sy);
				box.min = math::min(box.min, corner);
				box.max = math::max(box.max, corner);
			}
		}
	}
	return box;
}
