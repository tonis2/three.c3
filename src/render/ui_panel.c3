<*
 An interface drawn into an image of its own, which a quad in the scene wears:
 the text and panels a headset can show.

 `c3c test --trust=full --test-noleak --test-filter three_tests::panel`

 ## Why an image, and not the overlay

 `Renderer.ui` is drawn over the finished frame, at the same pixels in both
 eyes, which on a headset reads as infinitely far away; and with MSAA the scene
 writes the eye images itself, so there is no finished frame to draw over. A
 panel is drawn into its own image before the scene pass and sampled by an
 ordinary material on a quad, so it sits in the world: at its distance in both
 eyes, depth-tested against the hands, in a multiview pass and in a screenshot,
 with no path of its own through the frame.

 ## Drawn when it changed, and only then

 cui is retained and says when it wants a picture (`UiLayer.take_request`). A
 panel nothing touched records nothing: no upload, no rendering, no blit, and
 the picture key does not move. One that changed records a rendering into level
 0 and the mip chain by blits, so text stays clean when the panel is small in
 the view.

 ## The image

 `TARGET_COLOR_FORMAT`, the format the overlay's pass draws, so the two put down
 the same bytes. It starts clear, and cui's blending over a clear image leaves
 colour premultiplied by alpha: a box-filtered mip level and a bilinear tap
 across the edge of a glyph average that correctly, where straight alpha would
 drag the transparent black into the edge. The material divides it back out
 (`js/prelude/panel.js`).

 The sampler clamps, since a panel's edge must not bleed into its opposite edge,
 and leans half a level sharp, since text is what is sampled.
*>
module three;

import std::math;
import std::collections::list;
import std::time;
import vk;

<*
 One panel: its interface, its image, and the quad the pointer is tested
 against. Heap-allocated and never moved, because cui holds the layer's address.
*>
struct UiPanel
{
	UiLayer layer;
	// The image's pixels. The interface is laid out in these divided by `layer.scale`.
	vk::Extent2D extent;
	uint levels;
	// Its slot in `Assets.textures`, of which the panel holds one reference.
	int texture;
	vk::Image image;
	// Level 0 alone, the rendering's attachment. The texture's own view sees every level.
	vk::ImageView target_view;
	// The quad in its mesh's own units, centred on the origin in the xy plane and
	// facing +z: where `hit` looks for the pointer.
	Vec2 size;
	// How many times the image has been drawn.
	uint redraws;
	// When the pointer last fed it, for the interface's own animations.
	Clock fed;
	bool fed_once;
}

<*
 Where a ray met a panel.
*>
struct PanelHit
{
	bool hit;
	// In the interface's points, from its top-left corner.
	float x;
	float y;
	// Along the ray, in the units its direction is in.
	float distance;
	Vec3 point;
	// A widget is under the pointer, or holds it for a drag.
	bool taken;
}

// Half a level sharp: text is what a panel is, and trilinear filtering errs soft.
const float PANEL_LOD_BIAS = -0.5f;

<*
 A panel of `width` x `height` pixels, laid out in that many divided by `scale`,
 with its image in the asset table and the renderer drawing it when it changes.

 @param width : "The image's pixels across"
 @param height : "The image's pixels down"
 @param scale : "Image pixels per interface point; clamped to 0.25..4 as three.ui.scale is"
 @param size : "The quad in its mesh's units, for the pointer's hit test"
 @require width > 0 && height > 0 : "A panel has pixels"
 @return "Owned by the renderer until free_panel"
*>
fn UiPanel*? Renderer.create_panel(&self, uint width, uint height, float scale, Vec2 size)
{
	Gpu* gpu = &self.gpu;
	vk::Format format = TARGET_COLOR_FORMAT;
	vk::Extent2D extent = { width, height };

	UiPanel* panel = mem::new(UiPanel);
	defer catch free(panel);
	panel.extent = extent;
	panel.size = size;
	panel.layer.set_scale(scale);
	panel.layer.ensure_sized(gpu, extent, format)!;
	defer catch panel.layer.free();

	uint levels = gpu.levels_for(width, height, rgba8(ColorSpace.SRGB), true);
	vk::Memory memory = gpu.create_device_image(format, width, height,
		IMAGE_USAGE_COLOR_ATTACHMENT_BIT | IMAGE_USAGE_SAMPLED_BIT | IMAGE_USAGE_TRANSFER_SRC_BIT
			| IMAGE_USAGE_TRANSFER_DST_BIT, levels)!;
	Texture texture = {
		.memory = memory,
		.image = memory.image,
		.width = width,
		.height = height,
		.levels = levels,
		.format = rgba8(ColorSpace.SRGB),
	};
	defer catch texture.free(gpu);
	texture.view = gpu.create_view_2d(memory.image, format, IMAGE_ASPECT_COLOR_BIT, levels)!;
	texture.sampler = vk::samplerCreateInfo().setMagFilter(FILTER_LINEAR).setMinFilter(FILTER_LINEAR)
		.setAddressModeU(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setAddressModeV(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE)
		.setAddressModeW(SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE).setMipmapMode(SAMPLER_MIPMAP_MODE_LINEAR)
		.setMipLodBias(PANEL_LOD_BIAS).setMinLod(0).setMaxLod((float)levels)
		.setBorderColor(BORDER_COLOR_FLOAT_TRANSPARENT_BLACK).build(gpu.handle)!;
	panel.target_view = gpu.create_view_2d(memory.image, format)!;
	defer catch gpu.retire_memory({}, panel.target_view);
	clear_panel_image(gpu, memory.image, levels)!;

	panel.image = memory.image;
	panel.levels = levels;
	panel.texture = self.pass.assets.install_texture(gpu, texture);
	if (!self.panels.is_initialized()) self.panels.init(mem);
	self.panels.push(panel);
	return panel;
}

<*
 Clear in every level and ready to sample, so a material that wears the panel
 before it first draws shows nothing rather than whatever the memory held.
*>
fn void? clear_panel_image(Gpu* gpu, vk::Image image, uint levels) @local
{
	vk::ImageSubresourceRange every = { ...COLOR_LEVEL, .levelCount = levels };
	gpu.handle.@single_time_command(queue: gpu.graphics ; vk::CommandBuffer cmd)
	{
		vk::ImageMemoryBarrier2 to_clear = {
			...IMAGE_BARRIER,
			.image = image,
			.srcStageMask = PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.oldLayout = IMAGE_LAYOUT_UNDEFINED,
			.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.subresourceRange = every,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_clear }));
		vk::ClearColorValue clear = { .float32 = { 0, 0, 0, 0 } };
		vk::cmdClearColorImage(cmd, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &every);
		vk::ImageMemoryBarrier2 to_sample = {
			...to_clear,
			.srcStageMask = PIPELINE_STAGE_2_CLEAR_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
			.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_sample }));
	}!;
}

<*
 Takes a panel down: its interface, its view, and its reference to the image.
 A material still wearing the image keeps it, cleared to whatever was last drawn.

 @param [&inout] panel : "One create_panel answered; gone after this"
*>
fn void Renderer.free_panel(&self, UiPanel* panel)
{
	foreach (i, p : self.panels)
	{
		if (p != panel) continue;
		self.panels.remove_at(i);
		break;
	}
	// `CanvasPass.free` waits for the device, so the view goes with nothing in flight.
	panel.layer.free();
	self.gpu.retire_memory({}, panel.target_view);
	self.pass.assets.release_texture(&self.gpu, panel.texture);
	free(panel);
}

<*
 Every panel, for a renderer going down or a test giving its device back.
*>
fn void Renderer.free_panels(&self)
{
	while (self.panels.len() > 0) self.free_panel(self.panels[^1]);
	self.panels.free();
	// `List.free` leaves `allocator` set; clear it so a reused `Renderer`
	// re-initialises against the current allocator.
	self.panels = {};
}

<*
 Draws every panel whose interface changed, before the scene samples them.
 Outside every rendering; see `UiPanel.record`.
*>
fn void? Renderer.record_panels(&self, vk::CommandBuffer cmd)
{
	foreach (panel : self.panels)
	{
		if (panel.record(cmd)!) self.panel_epoch++;
	}
}

<*
 Draws the image if the interface asked for a picture, then its mip chain, and
 leaves every level ready to sample. Outside every rendering: the upload bakes
 glyphs and may grow a buffer, and it keeps `UiLayer.upload`'s contract with the
 fence wait of the frame recording it.

 @return "Whether the image was drawn"
*>
fn bool? UiPanel.record(&self, vk::CommandBuffer cmd)
{
	if (!self.layer.take_request()) return false;
	self.layer.upload_sized(self.extent)!;
	// What the flush itself asked for is in the picture it just made.
	self.layer.take_request();

	// The previous frame's samples finish before either write; neither level's
	// contents are kept, since level 0 is cleared and the rest are blitted over.
	vk::ImageMemoryBarrier2 open_top = {
		...IMAGE_BARRIER,
		.image = self.image,
		.srcStageMask = PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
		.dstStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.dstAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.oldLayout = IMAGE_LAYOUT_UNDEFINED,
		.newLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
	};
	vk::ImageMemoryBarrier2 open_rest = {
		...open_top,
		.dstStageMask = PIPELINE_STAGE_2_BLIT_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
		.newLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
		.subresourceRange = { ...COLOR_LEVEL, .baseMipLevel = 1, .levelCount = self.levels - 1 },
	};
	vk::ImageMemoryBarrier2[2] open = { open_top, open_rest };
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers(open[:self.levels > 1 ? 2 : 1]));

	vk::RenderingAttachmentInfo color = vk::renderingAttachmentInfo().setImageView(self.target_view)
		.setImageLayout(IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL)
		.setLoadOp(ATTACHMENT_LOAD_OP_CLEAR)
		.setStoreOp(ATTACHMENT_STORE_OP_STORE)
		.setClearValue({ .color = { .float32 = { 0, 0, 0, 0 } } });
	vk::RenderingInfo rendering = vk::renderingInfo().setRenderArea({ .extent = self.extent }).setLayerCount(1)
		.setColorAttachments({ color });
	vk::cmdBeginRendering(cmd, &rendering);
	set_full_viewport(cmd, self.extent, false);
	self.layer.record(cmd, self.extent)!;
	vk::cmdEndRendering(cmd);

	record_panel_mips(cmd, self.image, self.extent, self.levels);
	self.redraws++;
	return true;
}

<*
 Level 0 down the chain, each level a blit of the one above, then every level
 to the layout a material samples it in.
*>
fn void record_panel_mips(vk::CommandBuffer cmd, vk::Image image, vk::Extent2D extent, uint levels) @local
{
	vk::ImageMemoryBarrier2 top_to_source = {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
		.srcAccessMask = ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_BLIT_BIT,
		.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ top_to_source }));

	for (uint level = 1; level < levels; level++)
	{
		vk::ImageBlit down = {
			.srcSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = level - 1, .layerCount = 1 },
			.srcOffsets = { {}, { (int)level_extent(extent.width, level - 1), (int)level_extent(extent.height, level - 1), 1 } },
			.dstSubresource = { .aspectMask = IMAGE_ASPECT_COLOR_BIT, .mipLevel = level, .layerCount = 1 },
			.dstOffsets = { {}, { (int)level_extent(extent.width, level), (int)level_extent(extent.height, level), 1 } },
		};
		vk::cmdBlitImage(cmd, image, IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			1, &down, FILTER_LINEAR);
		vk::ImageMemoryBarrier2 to_source = {
			...IMAGE_BARRIER,
			.image = image,
			.srcStageMask = PIPELINE_STAGE_2_BLIT_BIT,
			.srcAccessMask = ACCESS_2_TRANSFER_WRITE_BIT,
			.dstStageMask = PIPELINE_STAGE_2_BLIT_BIT,
			.dstAccessMask = ACCESS_2_TRANSFER_READ_BIT,
			.oldLayout = IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
			.newLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
			.subresourceRange = { ...COLOR_LEVEL, .baseMipLevel = level },
		};
		vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_source }));
	}

	vk::ImageMemoryBarrier2 to_sample = {
		...IMAGE_BARRIER,
		.image = image,
		.srcStageMask = PIPELINE_STAGE_2_BLIT_BIT,
		.srcAccessMask = ACCESS_2_TRANSFER_READ_BIT | ACCESS_2_TRANSFER_WRITE_BIT,
		.dstStageMask = PIPELINE_STAGE_2_ALL_GRAPHICS_BIT,
		.dstAccessMask = ACCESS_2_SHADER_READ_BIT,
		.oldLayout = IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
		.newLayout = IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
		.subresourceRange = { ...COLOR_LEVEL, .levelCount = levels },
	};
	vk::cmdPipelineBarrier2(cmd, &&vk::dependencyInfo().setImageMemoryBarriers({ to_sample }));
}

<*
 Where a ray meets the front of the quad, in the world: the plane through the
 mesh's origin spanned by its x and y axes, inside the panel's size. The front is
 the side +z faces; a ray from behind misses, as a ray through a wall would.

 @param world : "The mesh's world matrix"
 @param origin : "Where the ray starts, in the world"
 @param direction : "Need not be unit length; the distance is in its units"
*>
fn PanelHit UiPanel.hit(&self, Matrix4f world, Vec3 origin, Vec3 direction)
{
	Vec3 centre = transform_point(world, { 0, 0, 0 });
	Vec3 across = transform_direction(world, { 1, 0, 0 });
	Vec3 up = transform_direction(world, { 0, 1, 0 });
	Vec3 normal = across.cross(up);

	float facing = direction.dot(normal);
	if (facing >= 0) return { };
	float t = (centre - origin).dot(normal) / facing;
	if (t < 0) return { };

	// The hit in the quad's own units: solve the offset as a mix of the two axes,
	// which holds under a scale that is not uniform.
	Vec3 point = origin + direction * t;
	Vec3 offset = point - centre;
	float aa = across.dot(across);
	float ab = across.dot(up);
	float bb = up.dot(up);
	float det = aa * bb - ab * ab;
	if (det <= 1e-12f) return { };
	float oa = offset.dot(across);
	float ob = offset.dot(up);
	float x = (oa * bb - ob * ab) / det;
	float y = (ob * aa - oa * ab) / det;

	float u = x / self.size.x + 0.5f;
	float v = 0.5f - y / self.size.y;
	if (u < 0 || u > 1 || v < 0 || v > 1) return { };

	Vec2 at = self.layer.points({ u * (float)self.extent.width, v * (float)self.extent.height });
	return { .hit = true, .x = at.x, .y = at.y, .distance = t, .point = point };
}

<*
 One frame of pointer from a ray: where it meets the quad, and the interface's
 answer to it. A miss still reaches the interface, far off its edge, so a hover
 ends and a drag that left the panel goes on until the button is let go.

 Widget handlers run from inside here.

 @param world : "The mesh's world matrix"
 @param origin : "Where the ray starts, in the world"
 @param direction : "Which way it points"
 @param down : "The button that presses, held"
 @param scroll : "Wheel notches over the panel this frame, positive away from the user"
*>
fn PanelHit UiPanel.point(&self, Matrix4f world, Vec3 origin, Vec3 direction, bool down, float scroll)
{
	PanelHit answer = self.hit(world, origin, direction);
	Vec2 pixels = answer.hit
		? (Vec2){ answer.x, answer.y } * (self.layer.scale > 0 ? self.layer.scale : 1)
		: (Vec2){ -1e6f, -1e6f };
	Cursor cursor = {
		.inside = answer.hit,
		.down = down,
		.x = pixels.x,
		.y = pixels.y,
		.scroll = answer.hit ? scroll : 0,
	};
	// The interface's animations run on the wall clock; a long gap is one step,
	// not a fast-forward.
	float dt_ms = self.fed_once ? (float)self.fed.mark().to_sec() * 1000.0f : 0;
	if (!self.fed_once) self.fed = clock::now();
	self.fed_once = true;
	self.layer.feed(cursor, { }, "", math::min(dt_ms, 100.0f));
	answer.taken = self.layer.wants_pointer;
	return answer;
}
