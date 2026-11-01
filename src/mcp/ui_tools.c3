<*
 `ui_tree` and `ui_input`: an agent reads the interface and uses it the way a
 person would. Coordinates in and out are the screenshot's pixels, so a widget
 is clicked where it is seen.
*>
module three;

import std::collections::object;
import std::core::dstring;
import std::math;
import mcp;
import cui;

faultdef TOOL_NO_UI, TOOL_BAD_TARGET, TOOL_BAD_ACTION;

const String UI_TREE_SCHEMA = `{"type":"object","properties":{`
	`"under":{"type":"string","description":"An element id to list from; omit for the whole interface."},`
	`"match":{"type":"string","description":"Only lines containing this text (case-insensitive)."},`
	`"all":{"type":"boolean","description":"Also list hidden and layout-only elements. Default false."}}}`;

const String UI_INPUT_SCHEMA = `{"type":"object","properties":{`
	`"action":{"type":"string","enum":["click","double_click","right_click","middle_click","hover","drag","scroll","type","keys"],"description":"Default click."},`
	`"id":{"type":"string","description":"Target by element id (from ui_tree's #id)."},`
	`"text":{"type":"string","description":"Target by what it says: a label, tooltip or row. Exact beats prefix beats substring."},`
	`"x":{"type":"number"},"y":{"type":"number","description":"Target by screenshot pixels."},`
	`"to":{"type":"object","description":"drag: where to, as {id|text|x,y}."},`
	`"type":{"type":"string","description":"type: the text typed into the focused field, after clicking the target if one is given."},`
	`"keys":{"type":"string","description":"keys: chords separated by spaces, e.g. \"ctrl+a Backspace Return\". click/drag/scroll: modifiers held, e.g. \"shift\"."},`
	`"dy":{"type":"number","description":"scroll: wheel notches, positive is up. Default 1."},`
	`"dx":{"type":"number"},`
	`"seconds":{"type":"number","description":"hover: how long to rest. Default 1."},`
	`"image":{"type":"boolean","description":"Whether the reply carries the frame after. Default true."}}}`;

fn void add_ui_tools(mcp::Server* server, ToolHost* host)
{
	server.add_tool(
		{
			.name = "ui_tree",
			.description = "List the interface's widgets, one per line, indented by nesting: "
				"`Type #id \"text\" = value [x,y wxh]` in screenshot pixels, with clickable sub-cells as `part` lines. "
				"Use it to find what ui_input can click.",
			.input_schema = UI_TREE_SCHEMA,
			.handler = &tool_ui_tree,
			.user_data = host,
		}
	);
	server.add_tool(
		{
			.name = "ui_input",
			.description = "Use the interface like a person: click, double/right click, hover, drag, scroll, "
				"type or press keys, on a widget named by id, by its text, or at screenshot pixels. "
				"Answers with what was hit and the frame after.",
			.input_schema = UI_INPUT_SCHEMA,
			.handler = &tool_ui_input,
			.user_data = host,
			.raw_content = true,
		}
	);
}

fn UiLayer*? tool_ui(ToolHost* host, DString* detail) @local
{
	if (host == null || host.renderer == null || host.renderer.ui.ui == null)
	{
		detail.append_string("this process has no interface to drive");
		return TOOL_NO_UI~;
	}
	return &host.renderer.ui;
}

fn float tool_ui_scale(ToolHost* host) @local
{
	uint width = host.renderer.target.extent.width;
	uint height = host.renderer.target.extent.height;
	return host.renderer.ui.image_scale(width, height, FRAME_MAX_EDGE);
}

fn String? tool_ui_tree(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	UiLayer* layer = tool_ui(host, detail)!;
	String under = "";
	String match = "";
	bool all = false;
	if (args != null)
	{
		if (try s = args.get_string("under")) under = s;
		if (try s = args.get_string("match")) match = s;
		if (try b = args.get_bool("all")) all = b;
	}

	DString tree;
	tree.init(mem, 4096);
	defer tree.free();
	if (catch layer.ui.describe_tree(&tree, under, all, tool_ui_scale(host)))
	{
		detail.appendf("no element has the id '%s'", under)!!;
		return TOOL_BAD_TARGET~;
	}
	if (match.len == 0) return tree.copy_str(mem);

	DString kept;
	kept.init(mem, 1024);
	defer kept.free();
	@pool()
	{
		String lower = match.to_lower_tcopy();
		foreach (line : tree.str_view().tsplit("\n"))
		{
			if (line.to_lower_tcopy().contains(lower)) kept.appendf("%s\n", line.trim_left());
		}
	};
	return kept.copy_str(mem);
}

<*
 Where `obj` points: its id, its text, or its x,y in screenshot pixels.
*>
fn cui::DriveTarget? tool_ui_target(cui::Ui* ui, Object* obj, float scale, int* matches, DString* detail) @local
{
	if (try id = obj.get_string("id"))
	{
		if (try t = ui.target_id(id)) return t;
		detail.appendf("no element has the id '%s'", id)!!;
		return TOOL_BAD_TARGET~;
	}
	if (try text = obj.get_string("text"))
	{
		if (try t = ui.find_text(text, matches)) return t;
		detail.appendf("nothing visible says '%s'; ui_tree lists what does", text)!!;
		return TOOL_BAD_TARGET~;
	}
	double? x = obj.get_float("x");
	double? y = obj.get_float("y");
	if (try px = x)
	{
		if (try py = y)
		{
			Vec2 p = { (float)px / scale, (float)py / scale };
			return { .min = p, .max = p };
		}
	}
	return TOOL_BAD_TARGET~;
}

fn String? tool_ui_input(Object* args, void* user_data, DString* detail)
{
	ToolHost* host = (ToolHost*)user_data;
	UiLayer* layer = tool_ui(host, detail)!;
	cui::Ui* ui = layer.ui;
	float scale = tool_ui_scale(host);
	if (args == null)
	{
		detail.append_string("name an action and a target");
		return TOOL_BAD_TARGET~;
	}

	String action = args.get_string("action") ?? "click";
	String keys = args.get_string("keys") ?? "";
	bool with_image = args.get_bool("image") ?? true;

	DString report;
	report.init(mem, 512);
	defer report.free();
	DString hit_line;
	hit_line.init(mem);
	defer hit_line.free();

	// Not inside an @pool: widgets rebuilt by the synthetic frames may keep temp
	// memory until the next frame, as they do under the real loop.
	{
		// Modifiers held through a pointer action, or the chords of `keys`.
		cui::Key[8] held_buf;
		cui::Key[] held;
		if (action != "keys" && keys.len)
		{
			cui::Key[]? parsed = cui::keys_from_chord(keys, &held_buf);
			if (catch parsed)
			{
				detail.appendf("unknown key in '%s'", keys)!!;
				return TOOL_BAD_ACTION~;
			}
			held = parsed;
		}

		int matches = 0;
		bool has_target = args.has_key("id") || args.has_key("text") || args.has_key("x");
		cui::DriveTarget target;
		if (has_target)
		{
			target = tool_ui_target(ui, args, scale, &matches, detail)!;
		}
		else if (action != "type" && action != "keys")
		{
			detail.append_string("name a target with id, text or x,y");
			return TOOL_BAD_TARGET~;
		}
		Vec2 at = target.center();

		// Described before acting: the action may rebuild the element away.
		if (has_target)
		{
			cui::Element* hit = target.element ? target.element : ui.named_at(at);
			if (hit) hit.describe_line(&hit_line, scale);
		}

		switch (action)
		{
			case "click": layer.@drive(; u) { u.click(at, held: held); };
			case "double_click": layer.@drive(; u) { u.click(at, count: 2, held: held); };
			case "right_click": layer.@drive(; u) { u.click(at, RIGHT, held: held); };
			case "middle_click": layer.@drive(; u) { u.click(at, MIDDLE, held: held); };
			case "hover":
				float seconds = (float)(args.get_float("seconds") ?? 1.0);
				layer.@drive(; u) { u.hover(at, math::clamp(seconds, 0.0f, 10.0f)); };
			case "scroll":
				float dy = (float)(args.get_float("dy") ?? 1.0);
				float dx = (float)(args.get_float("dx") ?? 0.0);
				layer.@drive(; u) { u.wheel(at, dy, dx, held); };
			case "drag":
				Object* to = args.get("to") ?? null;
				if (to == null || !to.is_map())
				{
					detail.append_string("drag needs to: {id|text|x,y}");
					return TOOL_BAD_TARGET~;
				}
				Vec2 end = tool_ui_target(ui, to, scale, null, detail)!.center();
				layer.@drive(; u) { u.drag(at, end, held: held); };
			case "type":
				if (has_target) layer.@drive(; u) { u.click(at); };
				String text = args.get_string("type") ?? "";
				layer.@drive(; u) { u.type_text(text); };
			case "keys":
				if (has_target) layer.@drive(; u) { u.click(at); };
				foreach (chord : keys.tsplit(" ", skip_empty: true))
				{
					cui::Key[8] buf;
					cui::Key[]? chord_keys = cui::keys_from_chord(chord, &buf);
					if (catch chord_keys)
					{
						detail.appendf("unknown key in '%s'", chord)!!;
						return TOOL_BAD_ACTION~;
					}
					layer.@drive(; u) { u.press_keys(chord_keys); };
				}
			default:
				detail.appendf("unknown action '%s'", action)!!;
				return TOOL_BAD_ACTION~;
		}
		// Whatever a script's handlers asked for while cui was dispatching.
		if (host.runtime != null) host.runtime.flush_ui();

		report.appendf(`{"action":"%s"`, action)!!;
		if (has_target)
		{
			report.appendf(`,"at":[%d,%d]`, (int)(at.x * scale), (int)(at.y * scale))!!;
			if (matches > 1) report.appendf(`,"matches":%d`, matches)!!;
			report.append_string(`,"hit":`);
			append_json_string(&report, hit_line.str_view());
		}
		if (ui.focused)
		{
			hit_line.clear();
			ui.focused.describe_line(&hit_line, scale);
			report.append_string(`,"focused":`);
			append_json_string(&report, hit_line.str_view());
		}
	}
	return content_with_frame(host, &report, with_image);
}
