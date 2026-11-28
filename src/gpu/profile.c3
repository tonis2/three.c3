<*
 Performance and rendering policy per platform preset: Desktop, PCVR, and Quest.

 Separates GPU tuning policy from both OS host code (`main.c3` / `android/entry.c3`)
 and display presentation (flat `Viewer` vs OpenXR `XrHost`). Every knob can be
 overridden with the same canonical key name from PC CLI (`--tune key=value`),
 environment variables (`THREE_<KEY>`), Android properties (`debug.three.<key>`),
 and live JS setters where safe.
*>
module three;

import std::io;
import std::math;
import std::os::env;
import vk;

<* Named platform presets selecting sensible defaults for each hardware class. *>
enum RenderPreset : char (String name)
{
	DESKTOP { "desktop" },
	PCVR    { "pcvr" },
	QUEST   { "quest" },
}

<* Shadow PCF mode: 4-tap receiver-plane PCF vs 1-tap hardware 2x2 PCF (`SKIP_RECEIVER_PLANE`). *>
enum ShadowFilter : char (String name)
{
	FOUR_TAP { "4tap" },
	ONE_TAP  { "1tap" },
}

<*
 Whether a multiview XR frame renders and tones directly into eye swapchain images
 instead of going through the HDR post chain and tonemap pass.

 `AUTO` is the zero value so default-constructed renderers behave sensibly:
 on a tiler with foveation active and 1x MSAA, big tiles reduce foveation's win so
 `AUTO` uses the HDR tonemap pass; otherwise it writes eye images directly whenever
 no script post pass or overlay UI sits in front of them.
*>
enum DirectEyesMode : char (String name)
{
	AUTO   { "auto" },
	ALWAYS { "always" },
	NEVER  { "never" },
}

<* Compositor filtering for XR eye layers (`XR_FB_composition_layer_settings`). *>
enum XrLayerFilter : char (String name)
{
	NONE    { "none" },
	SHARPEN { "sharpen" },
	SUPER   { "super" },
	AUTO    { "auto" },
}

<*
 Complete render policy for a run. Plain value struct with nothing to free.
 `configured` distinguishes an explicit profile from a zero-initialized struct
 inside tests (which resolves to `DESKTOP`).
*>
struct RenderProfile
{
	bool configured;
	RenderPreset preset;
	// 1 for flat desktop/headless, 2 for stereo XR multiview.
	uint views;
	// Requested MSAA samples for the scene: 1, 2, or 4.
	uint msaa;
	// Fraction of the XR runtime's recommended eye resolution (0.4..1.5).
	float xr_render_scale;
	XrLayerFilter xr_layer_filter;
	bool depth_prepass;
	ShadowFilter shadow_filter;
	DirectEyesMode direct_eyes;
	// Whether identical desktop frames may be skipped via `picture_key`.
	bool frame_skip;
	// Whether unchanged scene pixels may be preserved between submitted frames.
	bool scene_cache;
	// Whether per-pass GPU timestamp queries are created.
	bool gpu_timestamps;
	// Defer allocating HDR post images, tonemap pipeline, and `target.color`
	// until a frame actually takes the HDR chain or capture path.
	bool lazy_post_images;
	// Request `VK_EXT_fragment_density_map` and build a foveation map when available.
	bool foveation;
	Foveation foveation_level;
	// Desktop `--quest` emulation: pixels per unit view tangent; 0 when off.
	float headset_density;
}

<* Canonical override keys accepted by `--tune`, `THREE_*`, and Android `debug.three.*`. *>
const String[*] PROFILE_OVERRIDE_KEYS = {
	"profile",
	"msaa",
	"xr_scale",
	"xr_filter",
	"direct_eyes",
	"prepass",
	"shadow_filter",
	"foveation",
	"scene_cache",
	"frame_skip",
	"timestamps",
	"lazy_post",
};

<*
 Default profile for a target hardware preset.

 @param preset : "Hardware/display tier"
 @return "A fully populated RenderProfile"
*>
fn RenderProfile render_profile(RenderPreset preset)
{
	switch (preset)
	{
		case DESKTOP:
			return {
				.configured = true,
				.preset = DESKTOP,
				.views = 1,
				.msaa = 1,
				.xr_render_scale = XR_RENDER_SCALE,
				.xr_layer_filter = NONE,
				.depth_prepass = true,
				.shadow_filter = FOUR_TAP,
				.direct_eyes = AUTO,
				.frame_skip = true,
				.scene_cache = true,
				.gpu_timestamps = true,
				.lazy_post_images = false,
				.foveation = false,
				.foveation_level = OFF,
			};
		case PCVR:
			return {
				.configured = true,
				.preset = PCVR,
				.views = 2,
				.msaa = XR_MSAA,
				.xr_render_scale = XR_RENDER_SCALE,
				.xr_layer_filter = NONE,
				.depth_prepass = false,
				.shadow_filter = FOUR_TAP,
				.direct_eyes = AUTO,
				.frame_skip = false,
				.scene_cache = false,
				.gpu_timestamps = true,
				.lazy_post_images = true,
				.foveation = false,
				.foveation_level = OFF,
			};
		case QUEST:
			return {
				.configured = true,
				.preset = QUEST,
				.views = 2,
				.msaa = XR_MSAA,
				.xr_render_scale = XR_RENDER_SCALE,
				.xr_layer_filter = SUPER,
				.depth_prepass = false,
				.shadow_filter = ONE_TAP,
				.direct_eyes = AUTO,
				.frame_skip = false,
				.scene_cache = false,
				.gpu_timestamps = true,
				.lazy_post_images = true,
				.foveation = true,
				.foveation_level = MEDIUM,
			};
	}
}

<*
 Parses a preset name (`desktop`, `pcvr`, `quest`).

 @return? BAD_ARGUMENT
*>
fn RenderPreset? parse_render_preset(String name)
{
	String s = name.trim();
	foreach (preset : RenderPreset::values)
	{
		if (s == preset.name) return preset;
	}
	return BAD_ARGUMENT~;
}

fn bool? parse_bool_override(String value) @local
{
	switch (value)
	{
		case "1":
		case "true":
		case "on":
		case "yes":
			return true;
		case "0":
		case "false":
		case "off":
		case "no":
			return false;
		default:
			return BAD_ARGUMENT~;
	}
}

<*
 Applies a single `key=value` tuning override onto `self`.
 Invalid values are logged and ignored so a typo never aborts startup.

 @param key : "Canonical key from PROFILE_OVERRIDE_KEYS"
 @param raw_value : "String value to parse"
 @return "True if the override was valid and applied"
*>
fn bool RenderProfile.apply_override(&self, String key, String raw_value)
{
	String k = key.trim();
	String v = raw_value.trim();
	if (v.len == 0) return false;

	switch (k)
	{
		case "profile":
			if (try preset = parse_render_preset(v))
			{
				float density = self.headset_density;
				*self = render_profile(preset);
				self.headset_density = density;
				return true;
			}
			io::eprintfn("profile: unknown preset '%s' (expected desktop, pcvr, or quest)", v);
			return false;

		case "msaa":
			switch (v)
			{
				case "1": self.msaa = 1; return true;
				case "2": self.msaa = 2; return true;
				case "4": self.msaa = 4; return true;
				default:
					io::eprintfn("profile: msaa=%s is invalid (expected 1, 2, or 4)", v);
					return false;
			}

		case "xr_scale":
			if (try scale = v.to_float())
			{
				if (math::is_finite(scale) && scale >= 0.4f && scale <= 1.5f)
				{
					self.xr_render_scale = scale;
					return true;
				}
			}
			io::eprintfn("profile: xr_scale=%s is invalid (expected 0.4 to 1.5)", v);
			return false;

		case "xr_filter":
			foreach (f : XrLayerFilter::values)
			{
				if (v == f.name)
				{
					self.xr_layer_filter = f;
					return true;
				}
			}
			io::eprintfn("profile: xr_filter=%s is invalid (expected none, sharpen, super, or auto)", v);
			return false;

		case "direct_eyes":
			switch (v)
			{
				case "auto": self.direct_eyes = AUTO; return true;
				case "1":
				case "always":
				case "true":
				case "on":
					self.direct_eyes = ALWAYS;
					return true;
				case "0":
				case "never":
				case "false":
				case "off":
					self.direct_eyes = NEVER;
					return true;
				default:
					io::eprintfn("profile: direct_eyes=%s is invalid (expected auto, 1/always, or 0/never)", v);
					return false;
			}

		case "prepass":
			if (try on = parse_bool_override(v))
			{
				self.depth_prepass = on;
				return true;
			}
			io::eprintfn("profile: prepass=%s is invalid (expected 0 or 1)", v);
			return false;

		case "shadow_filter":
			switch (v)
			{
				case "1tap":
				case "1":
					self.shadow_filter = ONE_TAP;
					return true;
				case "4tap":
				case "4":
					self.shadow_filter = FOUR_TAP;
					return true;
				default:
					io::eprintfn("profile: shadow_filter=%s is invalid (expected 1tap or 4tap)", v);
					return false;
			}

		case "foveation":
			foreach (level : Foveation::values)
			{
				if (v == level.name)
				{
					self.foveation = level != OFF;
					self.foveation_level = level;
					return true;
				}
			}
			io::eprintfn("profile: foveation=%s is invalid (expected off, low, medium, or high)", v);
			return false;

		case "scene_cache":
			if (try on = parse_bool_override(v))
			{
				self.scene_cache = on;
				return true;
			}
			io::eprintfn("profile: scene_cache=%s is invalid (expected 0 or 1)", v);
			return false;

		case "frame_skip":
			if (try on = parse_bool_override(v))
			{
				self.frame_skip = on;
				return true;
			}
			io::eprintfn("profile: frame_skip=%s is invalid (expected 0 or 1)", v);
			return false;

		case "timestamps":
			if (try on = parse_bool_override(v))
			{
				self.gpu_timestamps = on;
				return true;
			}
			io::eprintfn("profile: timestamps=%s is invalid (expected 0 or 1)", v);
			return false;

		case "lazy_post":
			if (try on = parse_bool_override(v))
			{
				self.lazy_post_images = on;
				return true;
			}
			io::eprintfn("profile: lazy_post=%s is invalid (expected 0 or 1)", v);
			return false;

		default:
			io::eprintfn("profile: unknown tuning key '%s'", k);
			return false;
	}
}

<*
 Parses `key=value` from a CLI `--tune` argument and applies it.

 @param spec : "String of the form key=value"
 @return "True when parsed and applied"
*>
fn bool RenderProfile.apply_tune(&self, String spec)
{
	sz? eq = spec.index_of_char('=');
	if (catch eq)
	{
		io::eprintfn("profile: --tune expects key=value, got '%s'", spec);
		return false;
	}
	return self.apply_override(spec[:eq], spec[eq + 1..]);
}

<*
 Reads optional `THREE_<KEY>` environment overrides (e.g. `THREE_MSAA=2`,
 `THREE_SHADOW_FILTER=1tap`) and applies them in order.
*>
fn void RenderProfile.apply_env(&self) => @pool()
{
	foreach (key : PROFILE_OVERRIDE_KEYS)
	{
		String upper = key.to_upper_tcopy();
		String name = string::tformat("THREE_%s", upper);
		if (try val = env::tget_var(name))
		{
			if (val.len > 0) self.apply_override(key, val);
		}
	}
}

<*
 Resolves whether a multiview XR frame with no post pass/UI should render directly
 into the eye swapchain images on `gpu` and `target`.
*>
fn bool RenderProfile.wants_direct_eyes(&self, Gpu* gpu, Target* target)
{
	switch (self.direct_eyes)
	{
		case ALWAYS: return true;
		case NEVER:  return false;
		case AUTO:
			// On a tiler with foveation active and 1x MSAA, 4-byte pixels make bins too
			// large for per-bin foveation; going through the HDR tonemap pass is faster.
			if (gpu.limits.is_tiler && target.foveation.exists() && target.samples == SAMPLE_COUNT_1_BIT)
			{
				return false;
			}
			return true;
	}
}

<*
 Logs a single concise summary of the active render profile and hardware class.
*>
fn void RenderProfile.report(&self, Gpu* gpu, Target* target)
{
	bool direct = self.wants_direct_eyes(gpu, target);
	io::printfn(
		"profile: %s (%s) | %d view(s), %dx msaa, prepass=%s, shadow=%s, direct_eyes=%s (%s), foveation=%s, cache=%s, skip=%s, lazy_post=%s",
		self.preset.name,
		gpu.limits.is_tiler ? "tiler" : "desktop-gpu",
		target.views,
		(uint)target.samples,
		self.depth_prepass ? "on" : "off",
		self.shadow_filter.name,
		self.direct_eyes.name,
		direct ? "direct" : "chain",
		target.foveation.exists() ? target.foveation.level.name : "off",
		self.scene_cache ? "on" : "off",
		self.frame_skip ? "on" : "off",
		self.lazy_post_images ? "on" : "off"
	);
}
