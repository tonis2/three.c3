<*
 The import door `load_source` resolves through: an imported name is a
 `ShaderFile` member or nothing.

 The enum is the one list of what ships, so a name it does not have must be a
 fault rather than a read from a `shaders/` directory a shipped binary would not
 have beside it.
*>
module three_tests::shader_import;

import three;
import std::core::test;

fn void an_import_resolves_through_the_shader_file_enum() @test
{
	String lighting = three::load_import("lighting.shady")!!;
	defer free(lighting);

	test::@check(lighting.contains("shade_lights"),
		"the enum's name for lighting.shady should read that file");
}

fn void an_import_that_is_not_a_shader_file_is_refused() @test
{
	String? fetched = three::load_import("ghost.shady");
	bool refused = false;
	if (catch fetched) refused = true;

	test::@check(refused, "a name the enum does not know is not an import");
}
