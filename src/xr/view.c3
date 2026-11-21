<*
 Turning where the runtime says an eye is into a view and a projection.

 The script's camera stays the rig: its target is where the player stands and its
 yaw is where they face, so a game that moves `three.camera` still moves the
 player. The head then looks around from there; pitch and roll come from the
 head alone, because tilting the world under a headset is a quick way to make
 somebody sick.
*>
module three @feat(ANDROID);

import std::math;
import std::math::vector;
import std::math::matrix;
import xr;

<*
 Locks `camera` to one eye.

 @param [&inout] camera : "The camera to drive; its target and yaw are the rig"
 @param rig_position : "Where the tracking space's origin sits in the world"
 @param rig_yaw : "Degrees the tracking space is turned about +Y"
*>
fn void head_lock(Camera* camera, Vec3 rig_position, float rig_yaw, xr::View view)
{
	float yaw = math::deg_to_rad(rig_yaw);
	xr::Quaternionf q = view.pose.orientation;
	Vec3 local = { view.pose.position.x, view.pose.position.y, view.pose.position.z };

	Vec3 eye     = rig_position + turn_y(local, yaw);
	Vec3 forward = turn_y(rotate(q, { 0, 0, -1 }), yaw);
	Vec3 up      = turn_y(rotate(q, { 0, 1, 0 }), yaw);

	camera.head_eye = eye;
	camera.head_view = matrix::look_at{float}(eye, eye + forward, up);
	camera.head_projection = fov_projection(view.fov, camera.near_plane, camera.far_plane);
	// What code that reads `fov` (the shadow fit, picking) should assume.
	camera.fov = math::rad_to_deg(view.fov.angle_up - view.fov.angle_down);
	camera.head_locked = true;
}

// `v` turned by `angle` radians about +Y, the way yaw turns the orbit camera.
fn Vec3 turn_y(Vec3 v, float angle) @local
{
	float c = math::cos(angle);
	float s = math::sin(angle);
	return { v.x * c + v.z * s, v.y, -v.x * s + v.z * c };
}

fn Vec3 rotate(xr::Quaternionf q, Vec3 v) @local
{
	Vec3 u = { q.x, q.y, q.z };
	Vec3 t = u.cross(v) * 2.0f;
	return v + t * q.w + u.cross(t);
}

<*
 The off-axis projection for one eye, in `matrix::perspective`'s convention:
 right-handed, depth 0 at near and 1 at far, +Y up. The Y flip stays where it
 is, in the viewport (`gpu/target.c3`).

 @require near > 0 && far > near : "Planes must be ordered and positive"
*>
fn Matrix4f fov_projection(xr::Fovf fov, float near, float far)
{
	float left  = math::tan(fov.angle_left);
	float right = math::tan(fov.angle_right);
	float up    = math::tan(fov.angle_up);
	float down  = math::tan(fov.angle_down);
	float depth = 1.0f / (near - far);
	return (Matrix4f) { .m = {
		[0]  = 2.0f / (right - left),
		[5]  = 2.0f / (up - down),
		[8]  = (right + left) / (right - left),
		[9]  = (up + down) / (up - down),
		[10] = far * depth,
		[11] = -1,
		[14] = far * near * depth,
	} };
}
