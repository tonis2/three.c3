module three_tests::shadow_registry;

import three;
import std::core::test;

fn three::ShadowViewKey key(uint light, uint part = 0,
	three::ShadowViewKind kind = three::ShadowViewKind.DIRECTIONAL)
{
	return { .light = light, .part = part, .kind = kind };
}

fn void registry_recycles_entries_after_a_scene_reset() @test
{
	three::ShadowViewSet views = { .budget = { .max_views = 2, .max_texels = 1024, .max_bytes = 4096 } };
	views.reset();
	uint old_a = views.admit(key(10), 8);
	uint old_b = views.admit(key(20), 8);
	test::@check(old_a != three::SHADOW_VIEW_NONE && old_b != three::SHADOW_VIEW_NONE,
		"initial views are admitted");

	views.reset();
	views.want_light(30, three::ShadowViewKind.DIRECTIONAL);
	uint fresh = views.admit(key(30), 8);
	test::@check(fresh != three::SHADOW_VIEW_NONE, "an unused entry is recycled");
	test::@check(views.find(key(30)) == fresh && !views.views[old_a].live && !views.views[old_b].live,
		"reset leaves old identities inactive for possible reuse");
}

fn void changing_resolution_invalidates_only_that_cached_view() @test
{
	three::ShadowViewSet views;
	views.reset();
	uint a = views.admit(key(1), 16);
	uint b = views.admit(key(2), 16);
	views.views[a].static_valid = true;
	views.views[b].static_valid = true;
	views.views[a].dynamic_valid = true;

	views.reset();
	views.want_light(1, three::ShadowViewKind.DIRECTIONAL);
	views.want_light(2, three::ShadowViewKind.DIRECTIONAL);
	test::@check(views.admit(key(1), 32) == a, "resized view retains its stable slot");
	test::@check(views.admit(key(2), 16) == b, "unchanged view retains its stable slot");
	test::@check(!views.views[a].static_valid && views.views[b].static_valid,
		"resize invalidates only the changed cached depth");
}

fn void packed_light_reordering_preserves_cache_identity() @test
{
	three::ShadowViewSet views;
	views.reset();
	uint a = views.admit(key(101), 16);
	uint b = views.admit(key(202), 16);
	views.views[a].static_valid = true;
	views.views[b].static_valid = true;

	views.reset();
	views.want_light(202, three::ShadowViewKind.DIRECTIONAL);
	views.want_light(101, three::ShadowViewKind.DIRECTIONAL);
	test::@check(views.admit(key(202), 16) == b, "second light keeps its slot when packed first");
	test::@check(views.admit(key(101), 16) == a, "first light keeps its slot when packed second");
	test::@check(views.views[a].static_valid && views.views[b].static_valid,
		"reordering does not invalidate either cache entry");
}

fn void projection_or_scene_changes_invalidate_per_view() @test
{
	three::ShadowViewSet views;
	views.reset();
	uint a = views.admit(key(7), 16);
	uint b = views.admit(key(8), 16);
	views.views[a].invalidate(111, 3);
	views.views[b].invalidate(222, 3);
	views.views[a].static_valid = true;
	views.views[b].static_valid = true;

	views.views[a].invalidate(112, 3);
	test::@check(!views.views[a].static_valid && !views.views[a].dynamic_valid && views.views[b].static_valid,
		"one light projection change does not flush another light");
	views.views[a].static_valid = true;
	views.views[a].invalidate(112, 4);
	test::@check(!views.views[a].static_valid, "scene revision invalidates cached depth");
	views.views[a].static_valid = true;
	views.views[a].invalidate(112, 4);
	test::@check(views.views[a].static_valid, "unchanged key and revision preserve cached depth");
}

fn void point_lights_are_admitted_atomically_under_budget() @test
{
	three::ShadowViewSet views = { .budget = { .max_views = 5, .max_texels = 4096, .max_bytes = 16384 } };
	views.reset();
	uint admitted = views.admit_light(42, three::ShadowViewKind.POINT, 8);
	test::@check(admitted == three::SHADOW_VIEW_NONE && views.active == 0 && views.count == 0,
		"a six-face light is rejected without partial registry state");
}
