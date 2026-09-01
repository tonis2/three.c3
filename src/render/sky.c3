<*
 The sky: an image behind the scene, and the thing metals reflect.

 Two halves of one feature, with one image behind them:

 - **The background.** Three vertices at the far plane, sampled by the direction
 through each pixel — `shaders/sky.slang` has how, and why it is
 equirectangular rather than a cubemap.
 - **The environment.** The same image bound at `ENVIRONMENT_BINDING` in every
 shader that shades a surface, reflected by `environment_light`. This is the
 half the plan is actually about: a metal reflects and does not scatter, so
 with nothing around it to reflect, `material.metalness` renders dark and the
 four punctual lights give it a highlight and nothing else.

 They are two fields rather than one because Three.js has two — `scene.background`
 and `scene.environment` — and because a scene that wants an environment and a
 flat colour behind it is ordinary: an interior lit by a window, a studio
 turntable. Setting the background alone is a picture nothing reflects, which is
 what a painted backdrop is.

 ## Drawn first, not last

 A sky at the far plane with depth writes off passes the depth test exactly where
 nothing else has been drawn, so drawing it *last* would visit fewer pixels — and
 would be wrong. A transparent surface writes no depth either, so a sky drawn
 after one would pass the test over it and paint the glass out of the frame. So it
 goes first, and the opaque geometry overdraws it.

 What that costs is one fullscreen texture sample per frame in the worst case,
 against a correctness bug that only appears in scenes with glass in them.

 ## One angle, two consumers

 `rotation` reaches the background through this pass's push block and the
 reflections through `FrameBlock.environment.y`, written from the same field of
 the same `SkyLook` in the same frame. Two destinations, one source — a metal
 reflecting a sky pointing somewhere other than the one on screen is the failure
 that arrangement exists to make impossible.

 The two *intensities* are genuinely separate numbers and Three.js has both:
 dimming a backdrop and dimming what the scene is lit by are different requests.
*>
module three;

import vk;
import std::math::matrix;

<*
 What the sky draws with: solid triangles, depth tested, depth not written,
 nothing blended.

 Every flag is load-bearing. The test is on so the sky lands behind whatever has
 already been drawn — which is nothing, on the pass's own ordering, and is the
 point anyway the moment a second sky-drawing pass is ever added. The write is
 off because the sky occludes nothing: geometry behind the far plane does not
 exist, and a depth of 1 written everywhere would be indistinguishable from the
 cleared buffer while costing the bandwidth.

 The cull mode is dynamic here as everywhere, and `record_sky` sets it to none: a
 fullscreen triangle has a winding nobody chose.
*>
const PipelineState SKY_STATE = {
	.topology = PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
	.depth_test = true,
	.depth_write = false,
};

<*
 `shaders/sky.slang`'s push block, and the whole of what the pass tells it.

 It shares nothing with `MESH_PUSH_FIELDS` for `POST_PUSH_FIELDS`'s reason: a sky
 has no geometry, no instances and no draw record, so a contract requiring
 `positions` would require a pointer nothing could supply.

 The inverse view-projection rather than the view-projection: the shader's
 question is "which way is this pixel looking", which is the matrix run backwards,
 and inverting it once on the CPU beats inverting it per fragment by every
 measure there is.
*>
struct SkyPush
{
	Matrix4f inverse_view_projection;
	// x intensity, y rotation in radians about world Y, zw unused.
	float[4] params;
}

const PushFieldLayout[*] SKY_PUSH_FIELDS = {
	{ "inverse_view_projection", 0, 64 },
	{ "params", 64, 16 },
};

$assert SkyPush::size == 80 : "SkyPush no longer matches shaders/sky.slang";

<*
 What a scene's sky is — `scene.background` and `scene.environment`.

 Two texture slots and three numbers, on the `SceneLook` beside the clear colour
 and the lights, because the answer to "what is behind this level and what is it
 lit by" belongs to the level and not to the renderer. Switching scenes brings it
 back with everything else.

 Both indices are counted references into `Assets.textures`: assigning one
 retains and drops what was there, `Scene.free` gives both back, and a script may
 `dispose()` its own handle the moment it has assigned it.
*>
struct SkyLook
{
	// The image drawn behind the scene, or `NO_TEXTURE` for the clear colour.
	int background;
	// The image surfaces reflect, or `NO_TEXTURE` for none — which is what every
	// scene written before this existed has, and is why nothing any of them draws
	// changes.
	int environment;
	// A multiplier on each, separately. Three.js has `backgroundIntensity` and
	// `environmentIntensity` and they answer different questions: how bright the
	// backdrop is, and how much light the scene takes from it.
	float background_intensity;
	float environment_intensity;
	// About world Y, in radians, and **shared by both** — see the file header.
	float rotation;
}

const SkyLook DEFAULT_SKY = {
	.background = NO_TEXTURE,
	.environment = NO_TEXTURE,
	.background_intensity = 1.0,
	.environment_intensity = 1.0,
	.rotation = 0.0,
};

<*
 The environment half of the sky, as the frame block carries it.

 Zero intensity is how "there is no sky" is spelled, which is the same trick
 `shadow.w` plays: the shader's answer is identical for an absent image and one
 turned all the way down, and a second flag would be a second thing to keep in
 step with the first.

 The mip count comes off the texture rather than from the extents, because a
 device that cannot blit the format gives one level whatever was asked for —
 `Texture.levels` has the argument — and a `roughness` scaled by a chain that is
 not there would sample level 3 of a one-level image.
*>
fn float[4] MeshPass.environment_params(&self)
{
	if (self.scene == null) return { 0, 0, 0, 0 };
	SkyLook sky = self.scene.look.sky;
	if (sky.environment == NO_TEXTURE || sky.environment_intensity <= 0) return { 0, 0, 0, 0 };

	Texture* image = self.assets.texture_at(sky.environment);
	float top      = image.levels > 1 ? (float)(image.levels - 1) : 0.0f;
	return { sky.environment_intensity, sky.rotation, top, 0 };
}

<*
 Three vertices, if this scene has a background image.

 Recorded inside the scene's rendering and before every bucket — `MeshPass.record`
 opens with it. Nothing at all happens for a scene with no background, which is
 every scene until a script assigns one, so a frame that had no sky is the frame
 it always was.

 The pipeline is acquired at `MeshPass.init` beside the line and blend variants
 and for the same reason: building it the first time somebody assigns a sky would
 put a Slang compile inside that frame.
*>
fn void MeshPass.record_sky(&self, vk::CommandBuffer cmd)
{
	if (self.sky_pipeline == null || self.scene == null) return;

	SkyLook sky = self.scene.look.sky;
	if (sky.background == NO_TEXTURE || sky.background_intensity <= 0) return;
	if (!self.assets.texture_alive(sky.background)) return;

	vk::cmdBindPipeline(cmd, PIPELINE_BIND_POINT_GRAPHICS, self.sky_pipeline.handle);
	// None, for the reason `SKY_STATE` gives. Set here rather than left to the
	// bucket loop below it: the first bucket sets its own material's mode, so
	// this cannot be inherited in either direction.
	vk::cmdSetCullMode(cmd, CULL_MODE_NONE);

	SampledBindings samplers;
	samplers.add(0, self.assets.texture_at(sky.background).descriptor());
	samplers.push(cmd, self.sky_pipeline);

	SkyPush push = {
		.inverse_view_projection = invert(self.frame_view_projection),
		.params = { sky.background_intensity, sky.rotation, 0, 0 },
	};
	vk::cmdPushConstants(cmd, self.sky_pipeline.layout, self.sky_pipeline.shader.stages, 0, SkyPush::size, &push);

	// No index buffer and no vertex input: `SV_VertexID` is all the vertex stage
	// reads, which is the same arrangement the post chain draws under.
	vk::cmdDraw(cmd, 3, 1, 0, 0);
}

<*
 Assigns one of a scene's two sky images, counting the references.

 The retain happens before the release, which matters in the one case that looks
 like a no-op and is not: assigning the image already there. `held == texture`
 returns early rather than relying on the order, which is what
 `set_material_texture` does beside it and for the same reason.

 On the pass rather than on the `Scene`, because giving a reference back needs a
 device and a scene has none — `Assets.gpu` is the one this table uploads
 through, and it is the one every other release in this file uses.

 @param background : `True for scene.background, false for scene.environment.`
 @param texture : `An index into Assets.textures, or NO_TEXTURE to clear it.`
*>
fn void MeshPass.set_scene_sky(&self, Scene* scene, bool background, int texture)
{
	if (scene == null) return;
	if (texture != NO_TEXTURE && !self.assets.texture_alive(texture)) return;

	int held = background ? scene.look.sky.background : scene.look.sky.environment;
	if (held == texture) return;

	if (texture != NO_TEXTURE) self.assets.retain_texture(texture);
	self.assets.release_texture(self.assets.gpu, held);

	if (background)
	{
		scene.look.sky.background = texture;
	}
	else
	{
		scene.look.sky.environment = texture;
	}
}

<*
 Gives back both of a scene's sky references.

 Called where a scene goes — `dispose_scene` and `free_scenes` — rather than from
 `Scene.free`, which has no device to release through. A scene disposed without
 this leaves two images resident with nothing naming them, which is the same leak
 `Scene.free`'s own first line exists to prevent for geometry.
*>
fn void MeshPass.release_sky(&self, Scene* scene)
{
	if (scene == null) return;
	self.assets.release_texture(self.assets.gpu, scene.look.sky.background);
	self.assets.release_texture(self.assets.gpu, scene.look.sky.environment);
	scene.look.sky.background = NO_TEXTURE;
	scene.look.sky.environment = NO_TEXTURE;
}