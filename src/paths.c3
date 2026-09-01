<*
 The directories a run may write to that are not the working one.

 A checkout writes into `build/`, which is gitignored, and that is right for a
 developer and wrong for everybody else. A shipped game is started by a launcher
 from whatever directory the launcher felt like, so a cache under the working
 directory follows the *launcher* around rather than the machine: it lands in a
 home folder, or in a read-only install directory, and the next launch from
 somewhere else compiles every shader again.

 Three roots, answered here rather than at each call site:

 - **cache** — what the process can rebuild. Compiled shader modules and the
 driver's pipeline blob. `~/Library/Caches`, `%LOCALAPPDATA%`, `$XDG_CACHE_HOME`.
 - **state** — what it cannot. A game's saves. `~/Library/Application Support`,
 `%AppData%`, `$XDG_CONFIG_HOME`. A different root from the cache on every
 platform and deliberately so: a disk cleaner may empty a cache, and a save is
 not a thing anyone should lose to one.
 - **the executable's own directory** — what a bundle ships beside the binary
 and never writes to. The prebaked shader cache is read from there.

 Each of the first two is `three.c3/` under the platform's root, so everything
 this engine leaves on a machine is one directory per root, deletable by name.

 Separators are written `/` throughout, including on Windows, where every API
 that takes a path accepts it. A `\` would have to be conditional and would then
 be the only conditional thing in a path this file builds.
*>
module three;

import std::io::path;
import std::os::env;
import libc;

faultdef NO_USER_DIR;

// One name under every root, so `three.c3/` is the whole footprint and a person
// who wants it gone has one directory to delete per root.
const String USER_DIR = "three.c3";

<*
 `GetModuleFileNameA`, declared rather than imported.

 `std::os::win32` is `@feat(WIN32)` and importing it does not compile anywhere
 else, so the one symbol wanted from it is spelled out here under the same
 condition.
*>
extern fn uint get_module_file_name(void* mod, char* buf, uint size) @cname("GetModuleFileNameA") @feat(WIN32);

<*
 Where rebuildable things go.

 @return ? NO_USER_DIR : `No home directory and no cache variable — a service account, or an environment stripped of both. The caller falls back rather than failing.`
 @return `An absolute directory, which may not exist yet, allocated in the given allocator.`
*>
fn String? user_cache_dir(Allocator allocator) => @pool()
{
	String base;
	$switch:
	$case env::WIN32:
		String? local = env::tget_var("LOCALAPPDATA");
		if (try local && local.len > 0)
		{
			base = local;
		}
		else
		{
			base = env::tget_var("AppData")!;
		}
	$case env::DARWIN:
		base = string::tformat("%s/Library/Caches", env::tget_var("HOME")!);
	$default:
		String? xdg = env::tget_var("XDG_CACHE_HOME");
		if (try xdg && xdg.len > 0)
		{
			base = xdg;
		}
		else
		{
			base = string::tformat("%s/.cache", env::tget_var("HOME")!);
		}
	$endswitch
	if (base.len == 0) return NO_USER_DIR~;
	return string::format(allocator, "%s/%s", base, USER_DIR);
}

<*
 Where things that cannot be rebuilt go — saves, and nothing else so far.

 `env::get_config_dir` already answers the platform question; this adds the one
 directory name and hands back a String, because everything downstream of it
 formats paths rather than composing them.

 @return ? NO_USER_DIR : `No home directory. The caller says so rather than writing somewhere else.`
*>
fn String? user_state_dir(Allocator allocator) => @pool()
{
	String base = (String)env::get_config_dir(tmem)!;
	if (base.len == 0) return NO_USER_DIR~;
	return string::format(allocator, "%s/%s", base, USER_DIR);
}

<*
 The directory holding this process's executable.

 For what a bundle ships beside the binary. The stdlib answers this on Darwin
 only, so Linux and Windows are done here — `/proc/self/exe` and
 `GetModuleFileNameA`.

 @return ? NO_USER_DIR : `The platform would not say. Nothing is read from beside the binary, which is a bundle running slightly colder and not an error.`
 @return `The directory, with no trailing separator, allocated in the given allocator.`
*>
fn String? executable_dir(Allocator allocator) => @pool()
{
	String full;
	$switch:
	$case env::DARWIN:
		full = env::executable_path()!;
	$case env::WIN32:
		char[4096] buf;
		uint written = get_module_file_name(null, &buf[0], (uint)buf.len - 1);
		if (written == 0 || written >= (uint)buf.len - 1) return NO_USER_DIR~;
		full = ((String)buf[:(usz)written]).tcopy();
	$default:
		char[4096] buf;
		sz written = libc::readlink("/proc/self/exe", &buf[0], (int)buf.len - 1);
		if (written <= 0) return NO_USER_DIR~;
		full = ((String)buf[:(usz)written]).tcopy();
	$endswitch

	usz cut = full.len;
	while (cut > 0 && full[cut - 1] != '/' && full[cut - 1] != '\\') cut--;
	if (cut == 0) return NO_USER_DIR~;
	return full[:cut - 1].copy(allocator);
}

<*
 Where compiled shader modules and the pipeline blob are kept, decided once.

 The order, and why each step is where it is:

 1. **`--cache-dir`**, which is a developer's flag. An empty string is a
 decision too — it turns the cache off — so it is answered before anything
 else and never falls through.
 2. **`THREE_CACHE_DIR`**, for a CI job or a launcher that would rather not
 rewrite an argument list.
 3. **`build/`, if there already is one.** This is what keeps a checkout and
 the test suite exactly as they were: `build/` is where c3c puts the binary,
 it is gitignored, and a warm cache under it never becomes a diff. It is also
 the case that reads a `build/shader-cache` a bundle shipped warm.
 4. **The user cache directory.** A shipped game, started from anywhere.

 There is no step for "give up": with no home directory to be found the answer
 is the old default, which either works or reports that it cannot in the one
 line `disk_cache.c3` already prints.

 @param flag : `--cache-dir as written, or an empty string when the flag was absent. A NAMED empty value is handled by the caller, which is the only thing that can tell one from the other.`
 @return `A directory, which may not exist yet, allocated in the given allocator.`
*>
fn String resolve_cache_dir(String flag, Allocator allocator)
{
	if (flag.len > 0) return flag.copy(allocator);

	@pool()
	{
		String? from_env = env::tget_var("THREE_CACHE_DIR");
		if (try from_env && from_env.len > 0) return from_env.copy(allocator);
	};

	if (path::is_dir((Path)"build")) return SHADER_CACHE_DEFAULT_DIR.copy(allocator);

	@pool()
	{
		String? user = user_cache_dir(tmem);
		if (try user) return string::format(allocator, "%s/shader-cache", user);
	};

	return SHADER_CACHE_DEFAULT_DIR.copy(allocator);
}
