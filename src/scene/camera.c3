<*
 A turntable camera, and how it frames what it is shown.

 Not in `plan.md`'s source tree, and here because M1 needs one: something has to
 decide where the eye is before a `.glb` can be looked at. It is deliberately
 the smallest camera that does the job — `Object3D`, `lookAt` and a Three.js
 shaped `PerspectiveCamera` are M2/M3, and this is the thing they will replace.

 `frame_bounds` is the part worth keeping either way. An agent that loads a
 model has no idea how big it is — a kit piece is a metre across, a terrain
 tile is a kilometre — so the default view has to be derived from the geometry
 rather than guessed, or the first render of every unfamiliar asset is an empty
 screen with the model either inside the near plane or a speck at the horizon.
*>
module three;

import std::math;
import std::math::vector;
import std::math::matrix;

struct Camera
{
	Vec3 target;
	float distance;
	// Degrees. Yaw turns around +Y, pitch lifts the eye above the horizon.
	float yaw;
	float pitch;
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
// `look_at`'s cross product is zero, and the view matrix comes back full of
// NaN. Nothing errors — the frame renders empty, which reads as "the scene is
// gone" rather than as "the camera is broken".
const float CAMERA_PITCH_LIMIT = 89.0f;

fn Vec3 Camera.eye(&self)
{
	float yaw        = math::deg_to_rad(self.yaw);
	float pitch      = math::deg_to_rad(self.pitch);
	float horizontal = math::cos(pitch);
	return self.target + (Vec3) { horizontal * math::sin(yaw), math::sin(pitch), horizontal * math::cos(yaw) }
		* self.distance;
}

<*
 Keep the eye off the pole and the yaw in [-180, 180).

 The yaw wrap is not cosmetic. Yaw accumulates one drag delta at a time and
 nothing else ever resets it, so a long session walks it into the thousands,
 where a float's spacing is coarse enough that a slow drag starts to step.
*>
fn void Camera.clamp_angles(&self)
{
	self.pitch = math::clamp(self.pitch, -CAMERA_PITCH_LIMIT, CAMERA_PITCH_LIMIT);
	self.yaw -= 360.0f * math::floor((self.yaw + 180.0f) / 360.0f);
}

<*
 Put the near and far planes back where the distance says they belong.

 **The planes are derived, never set.** A fixed near plane against a model a
 kilometre wide spends the whole depth buffer on the first few metres, which is
 z-fighting across the entire scene and reads as a rendering bug rather than as
 a camera setting.

 `frame_bounds` does *not* call this and is not meant to: it knows the model's
 radius, so it can put the far plane just beyond the geometry instead of at a
 multiple of the distance. Everything that only moves the camera — `cameraSet`,
 an orbit drag, a scroll — has no radius to work from and comes here.
*>
fn void Camera.derive_planes(&self)
{
	self.near_plane = math::max(self.distance * 0.001f, 0.0001f);
	self.far_plane = self.distance * 8.0f;
}

<*
 The camera's right and up axes in world space.

 @param right : `Out. Screen +X, world space, normalized.`
 @param up : `Out. Screen +Y, world space, normalized.`
*>
fn void Camera.basis(&self, Vec3* right, Vec3* up)
{
	Vec3 forward = (self.target - self.eye()).normalize();
	Vec3 sideways = forward.cross((Vec3) { 0, 1, 0 });

	// The pitch clamp is what normally keeps this from happening, but the clamp
	// is applied where angles are *written* and a caller can reach these fields
	// directly. A zero-length cross would normalize to NaN and silently poison
	// the target, so degeneracy falls back to a fixed axis instead.
	if (sideways.length() < 1e-6f) sideways = (Vec3) { 1, 0, 0 };

	*right = sideways.normalize();
	*up = right.cross(forward);
}

<*
 How much world space one screen point covers, at the distance the camera is
 focused on.

 This is what makes a pan track the cursor rather than merely follow it: the
 point under the mouse when the drag started is the point under the mouse for
 the whole drag, at any distance and any field of view.

 @param viewport_height : `The viewport's height in the same units the pointer is reported in.`
*>
fn float Camera.world_per_point(&self, float viewport_height)
{
	if (viewport_height < 1.0f) return 0.0f;
	float visible = 2.0f * self.distance * math::tan(math::deg_to_rad(self.fov) * 0.5f);
	return visible / viewport_height;
}

fn Matrix4f Camera.view(&self)
{
	return matrix::look_at{float}(self.eye(), self.target, { 0.0, 1.0, 0.0 });
}

<*
 `std::math::matrix` builds a right-handed, [0,1]-depth projection with +Y up —
 glm's convention. Vulkan's clip space has +Y down.

 **There is no Y flip here**, unlike crig, and that is not an oversight:
 `gpu/target.c3` binds a negative-height viewport, which does the same job at
 the other end. Doing both would cancel out and render the model upside down.
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
 Aim at the middle of a bounding box and back off far enough to see all of it.

 The distance is derived from the box's bounding *sphere* rather than from its
 height, because a model that is wide and flat would otherwise be framed by its
 short axis and run off both sides of the screen. The sphere is orientation
 independent, so the fit holds however the camera is turned afterwards.

 The near and far planes are re-derived from the same number: a fixed 0.01 near
 plane against a kilometre-wide model spends the entire depth buffer on the
 first few metres, which is z-fighting across the whole scene.

 @param min : `Corner of the model's axis-aligned bounds, model space.`
*>
fn void Camera.frame_bounds(&self, Vec3 min, Vec3 max)
{
	Vec3 extent = max - min;
	self.target = (min + max) * 0.5f;

	float radius = extent.length() * 0.5f;
	if (radius <= 0.0f) radius = 1.0f;

	// The half-angle the *narrower* of the two screen axes subtends is what
	// actually bounds the fit, and the vertical is the one this projection is
	// specified by. A little slack keeps the silhouette off the edge.
	float half_fov = math::deg_to_rad(self.fov) * 0.5f;
	self.distance = radius / math::sin(half_fov) * 1.25f;

	self.near_plane = math::max(self.distance * 0.001f, 0.0001f);
	self.far_plane = self.distance + radius * 4.0f;
}
