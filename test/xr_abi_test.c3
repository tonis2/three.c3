<*
 The hand-written OpenXR structs against openxr.h.

	`c3c test --test-noleak --test-filter three_tests::xr_abi`

 The runtime reads these through raw pointers, so a field one slot off is not a
 compile error but a session that fails in a way that names nothing. The numbers
 are `sizeof`/`offsetof` from a C program built against the loader's own
 headers (OpenXR 1.1.65). x86_64 and aarch64 lay these out the same way, so the
 desktop suite checks the Quest build.
*>
module three_tests::xr_abi;

import xr;

fn void sizes() @test
{
	test::eq(xr::ApplicationInfo::size, 272);
	test::eq(xr::InstanceCreateInfo::size, 328);
	test::eq(xr::InstanceProperties::size, 152);
	test::eq(xr::SystemGetInfo::size, 24);
	test::eq(xr::ViewConfigurationView::size, 40);
	test::eq(xr::GraphicsRequirementsVulkanKHR::size, 32);
	test::eq(xr::GraphicsBindingVulkanKHR::size, 48);
	test::eq(xr::SessionCreateInfo::size, 32);
	test::eq(xr::SessionBeginInfo::size, 24);
	test::eq(xr::ReferenceSpaceCreateInfo::size, 48);
	test::eq(xr::SwapchainCreateInfo::size, 64);
	test::eq(xr::SwapchainImageVulkanKHR::size, 24);
	test::eq(xr::SwapchainImageWaitInfo::size, 24);
	test::eq(xr::FrameState::size, 40);
	test::eq(xr::CompositionLayerProjectionView::size, 96);
	test::eq(xr::CompositionLayerProjection::size, 48);
	test::eq(xr::FrameEndInfo::size, 40);
	test::eq(xr::ViewLocateInfo::size, 40);
	test::eq(xr::ViewState::size, 24);
	test::eq(xr::View::size, 64);
	test::eq(xr::EventDataBuffer::size, 4016);
	test::eq(xr::EventDataSessionStateChanged::size, 40);
	test::eq(xr::SwapchainSubImage::size, 32);
	test::eq(xr::Posef::size, 28);
	test::eq(xr::Fovf::size, 16);
	test::eq(xr::InstanceCreateInfoAndroidKHR::size, 32);
	test::eq(xr::LoaderInitInfoAndroidKHR::size, 32);
}

fn void offsets() @test
{
	test::eq((usz)$reflect(xr::InstanceCreateInfo.application_info).offset, (usz)24);
	test::eq((usz)$reflect(xr::InstanceCreateInfo.enabled_extension_names).offset, (usz)320);
	test::eq((usz)$reflect(xr::ApplicationInfo.api_version).offset, (usz)264);
	test::eq((usz)$reflect(xr::SwapchainCreateInfo.format).offset, (usz)32);
	test::eq((usz)$reflect(xr::SwapchainCreateInfo.mip_count).offset, (usz)60);
	test::eq((usz)$reflect(xr::FrameState.should_render).offset, (usz)32);
	test::eq((usz)$reflect(xr::CompositionLayerProjectionView.sub_image).offset, (usz)64);
	test::eq((usz)$reflect(xr::CompositionLayerProjection.views).offset, (usz)40);
	test::eq((usz)$reflect(xr::FrameEndInfo.layers).offset, (usz)32);
	test::eq((usz)$reflect(xr::ViewLocateInfo.space).offset, (usz)32);
	test::eq((usz)$reflect(xr::View.fov).offset, (usz)44);
	test::eq((usz)$reflect(xr::EventDataSessionStateChanged.time).offset, (usz)32);
	test::eq((usz)$reflect(xr::GraphicsBindingVulkanKHR.queue_index).offset, (usz)44);
	test::eq((usz)$reflect(xr::SwapchainSubImage.image_array_index).offset, (usz)24);
	test::eq((usz)$reflect(xr::ReferenceSpaceCreateInfo.pose_in_reference_space).offset, (usz)20);
}
