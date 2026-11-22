<*
 The hand-written OpenXR structs against openxr.h.

	`c3c test --test-noleak --test-filter three_tests::xr_abi`

 The runtime reads these through raw pointers, so a field one slot off is not a
 compile error but a session that fails in a way that names nothing. The numbers
 are `sizeof`/`offsetof` from a C program built against the loader's own
 headers (OpenXR 1.1.65), which `./setup.sh android` unpacks under
 packaging/android/third_party/aar/prefab/modules/headers/include. x86_64 and aarch64 lay these out the same way, so the
 desktop suite checks the Quest build.
*>
module three_tests::xr_abi;

import xr;

fn void sizes() @test
{
	test::eq(xr::ApplicationInfo::size, 272);
	test::eq(xr::InstanceCreateInfo::size, 328);
	test::eq(xr::InstanceProperties::size, 152);
	test::eq(xr::ExtensionProperties::size, 152);
	test::eq(xr::EventDataDisplayRefreshRateChangedFB::size, 24);
	test::eq($reflect(xr::ExtensionProperties.extension_version).offset, 144);
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

// Controller input, haptics and system properties.
fn void action_sizes() @test
{
	test::eq(xr::Vector2f::size, 8);
	test::eq(xr::ActionSetCreateInfo::size, 216);
	test::eq(xr::ActionCreateInfo::size, 224);
	test::eq(xr::ActionSuggestedBinding::size, 16);
	test::eq(xr::InteractionProfileSuggestedBinding::size, 40);
	test::eq(xr::SessionActionSetsAttachInfo::size, 32);
	test::eq(xr::ActiveActionSet::size, 16);
	test::eq(xr::ActionsSyncInfo::size, 32);
	test::eq(xr::ActionStateGetInfo::size, 32);
	test::eq(xr::ActionStateBoolean::size, 40);
	test::eq(xr::ActionStateFloat::size, 40);
	test::eq(xr::ActionStateVector2f::size, 48);
	test::eq(xr::ActionStatePose::size, 24);
	test::eq(xr::ActionSpaceCreateInfo::size, 64);
	test::eq(xr::SpaceLocation::size, 56);
	test::eq(xr::HapticActionInfo::size, 32);
	test::eq(xr::HapticVibration::size, 32);
	test::eq(xr::InteractionProfileState::size, 24);
	test::eq(xr::EventDataInteractionProfileChanged::size, 24);
	test::eq(xr::SystemProperties::size, 304);
	test::eq(xr::SystemGraphicsProperties::size, 12);
	test::eq(xr::SystemTrackingProperties::size, 8);
}

fn void action_offsets() @test
{
	test::eq((usz)$reflect(xr::ActionSetCreateInfo.localized_action_set_name).offset, (usz)80);
	test::eq((usz)$reflect(xr::ActionSetCreateInfo.priority).offset, (usz)208);
	test::eq((usz)$reflect(xr::ActionCreateInfo.action_type).offset, (usz)80);
	test::eq((usz)$reflect(xr::ActionCreateInfo.count_subaction_paths).offset, (usz)84);
	test::eq((usz)$reflect(xr::ActionCreateInfo.subaction_paths).offset, (usz)88);
	test::eq((usz)$reflect(xr::ActionCreateInfo.localized_action_name).offset, (usz)96);
	test::eq((usz)$reflect(xr::ActionSuggestedBinding.binding).offset, (usz)8);
	test::eq((usz)$reflect(xr::InteractionProfileSuggestedBinding.count_suggested_bindings).offset, (usz)24);
	test::eq((usz)$reflect(xr::InteractionProfileSuggestedBinding.suggested_bindings).offset, (usz)32);
	test::eq((usz)$reflect(xr::SessionActionSetsAttachInfo.action_sets).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionsSyncInfo.active_action_sets).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionStateGetInfo.subaction_path).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionStateBoolean.changed_since_last_sync).offset, (usz)20);
	test::eq((usz)$reflect(xr::ActionStateBoolean.last_change_time).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionStateBoolean.is_active).offset, (usz)32);
	test::eq((usz)$reflect(xr::ActionStateFloat.is_active).offset, (usz)32);
	test::eq((usz)$reflect(xr::ActionStateVector2f.changed_since_last_sync).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionStateVector2f.last_change_time).offset, (usz)32);
	test::eq((usz)$reflect(xr::ActionStateVector2f.is_active).offset, (usz)40);
	test::eq((usz)$reflect(xr::ActionStatePose.is_active).offset, (usz)16);
	test::eq((usz)$reflect(xr::ActionSpaceCreateInfo.subaction_path).offset, (usz)24);
	test::eq((usz)$reflect(xr::ActionSpaceCreateInfo.pose_in_action_space).offset, (usz)32);
	test::eq((usz)$reflect(xr::SpaceLocation.pose).offset, (usz)24);
	test::eq((usz)$reflect(xr::HapticActionInfo.subaction_path).offset, (usz)24);
	test::eq((usz)$reflect(xr::HapticVibration.frequency).offset, (usz)24);
	test::eq((usz)$reflect(xr::HapticVibration.amplitude).offset, (usz)28);
	test::eq((usz)$reflect(xr::InteractionProfileState.interaction_profile).offset, (usz)16);
	test::eq((usz)$reflect(xr::SystemProperties.vendor_id).offset, (usz)24);
	test::eq((usz)$reflect(xr::SystemProperties.system_name).offset, (usz)28);
	test::eq((usz)$reflect(xr::SystemProperties.graphics_properties).offset, (usz)284);
	test::eq((usz)$reflect(xr::SystemProperties.tracking_properties).offset, (usz)296);
}

fn void passthrough_layout() @test
{
	test::eq(xr::SystemPassthroughProperties2FB::size, 24);
	test::eq(xr::PassthroughCreateInfoFB::size, 24);
	test::eq(xr::PassthroughLayerCreateInfoFB::size, 40);
	test::eq(xr::CompositionLayerPassthroughFB::size, 40);
	test::eq(xr::EventDataPassthroughStateChangedFB::size, 24);
	test::eq((usz)$reflect(xr::PassthroughLayerCreateInfoFB.flags).offset, (usz)24);
	test::eq((usz)$reflect(xr::PassthroughLayerCreateInfoFB.purpose).offset, (usz)32);
	test::eq((usz)$reflect(xr::CompositionLayerPassthroughFB.space).offset, (usz)24);
	test::eq((usz)$reflect(xr::CompositionLayerPassthroughFB.layer_handle).offset, (usz)32);
	// Read through a CompositionLayerBaseHeader pointer in the layer list.
	test::eq((usz)$reflect(xr::CompositionLayerPassthroughFB.flags).offset,
		(usz)$reflect(xr::CompositionLayerBaseHeader.layer_flags).offset);
	test::eq((usz)$reflect(xr::CompositionLayerPassthroughFB.space).offset,
		(usz)$reflect(xr::CompositionLayerBaseHeader.space).offset);
}

// A wrong structure type is the same silent failure as a wrong offset.
fn void constants() @test
{
	test::eq(xr::TYPE_SYSTEM_PROPERTIES, 5);
	test::eq(xr::TYPE_HAPTIC_VIBRATION, 13);
	test::eq(xr::TYPE_ACTION_STATE_BOOLEAN, 23);
	test::eq(xr::TYPE_ACTION_STATE_FLOAT, 24);
	test::eq(xr::TYPE_ACTION_STATE_VECTOR2F, 25);
	test::eq(xr::TYPE_ACTION_STATE_POSE, 27);
	test::eq(xr::TYPE_ACTION_SET_CREATE_INFO, 28);
	test::eq(xr::TYPE_ACTION_CREATE_INFO, 29);
	test::eq(xr::TYPE_ACTION_SPACE_CREATE_INFO, 38);
	test::eq(xr::TYPE_SPACE_LOCATION, 42);
	test::eq(xr::TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING, 51);
	test::eq(xr::TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED, 52);
	test::eq(xr::TYPE_INTERACTION_PROFILE_STATE, 53);
	test::eq(xr::TYPE_ACTION_STATE_GET_INFO, 58);
	test::eq(xr::TYPE_HAPTIC_ACTION_INFO, 59);
	test::eq(xr::TYPE_SESSION_ACTION_SETS_ATTACH_INFO, 60);
	test::eq(xr::TYPE_ACTIONS_SYNC_INFO, 61);
	test::eq(xr::TYPE_PASSTHROUGH_CREATE_INFO_FB, 1000118001);
	test::eq(xr::TYPE_PASSTHROUGH_LAYER_CREATE_INFO_FB, 1000118002);
	test::eq(xr::TYPE_COMPOSITION_LAYER_PASSTHROUGH_FB, 1000118003);
	test::eq(xr::TYPE_SYSTEM_PASSTHROUGH_PROPERTIES2_FB, 1000118006);
	test::eq(xr::TYPE_EVENT_DATA_PASSTHROUGH_STATE_CHANGED_FB, 1000118030);
	test::eq(xr::ACTION_TYPE_VIBRATION_OUTPUT, 100);
	test::eq(xr::COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT, (xr::Flags64)2);
	test::eq(xr::MIN_HAPTIC_DURATION, (xr::Duration)-1);
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
