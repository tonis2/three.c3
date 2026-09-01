<*
 The Slang compile, kept between runs.

 A compile is about 17 ms and a session about 55 ms. `gpu/pipeline.c3`'s cache
 removes the second and later compiles *within* a process; it cannot remove the
 first, and the first is the whole cost of starting — every run of the CLI, every
 `c3c test`, every MCP session pays 17 ms per distinct shader before anything is
 on screen.

 This sits at the *compile* level rather than under `PipelineCache`, so anything
 that compiles Slang shares it: the mesh pipeline, an agent's `ShaderMaterial`,
 the post pass. `compile_slang_cached` has `compile_slang`'s signature with one
 extra out-parameter.

 ## The hash is a filter; the file is the check

 A 64-bit content hash names a *candidate*; identity decides. The file carries
 the full argument list and the full source, and a hash hit whose bytes differ
 from the request is not a hit — it is `invalid++`, a recompile, and an
 overwrite. Sources are a few kilobytes; a collision would hand a pipeline
 somebody else's shader, which renders something plausible and wrong.

 Nothing here is trusted, including this process's own past. The loader
 bounds-checks every read, re-checks the SPIR-V magic number and word alignment
 that `compile_slang` checks on Slang's own output, and treats any disagreement
 as a miss. A truncated file — a torn write, a full disk, a killed process —
 costs one recompile and is overwritten. It must never be a crash: the file is on
 disk between runs, so a bad one would otherwise be permanent.

 ## The compiler is in the key

 `slang::build_tag()` — `spGetBuildTagString`, the release tag baked into
 libslang at its own build — is hashed into the filename *and* written into the
 file as checked identity. So a Slang upgrade does not leave the cache holding
 modules built by a compiler that is gone: every key moves, every old file is
 unreachable, and a hash collision onto one of them fails the identity check the
 same way. That costs one call to a function returning static storage; hashing
 the compiler itself would mean re-reading tens of megabytes per process, and
 now that Slang is linked in there is no separate file to hash anyway.

 A build with no tag is still a key. Slang reports something like `unknown` for a
 compiler built from an untagged checkout, and two such builds are then
 indistinguishable here. The lever for that is the format version below.

 The *device* is deliberately not in the key: SPIR-V is portable, and
 `MeshPipeline.init` re-validates every loaded layout through `check_push_block`
 against the limits of the device actually present.

 ## The file

 Little-endian throughout, every variable-length field prefixed with its `u32`
 length. `blob` below means "`u32` length, then that many bytes".

 bytes  field
 -----  ------------------------------------------------------------------
 4  magic — 'T3SC' as the four bytes T, 3, S, C
 4  SHADER_CACHE_FORMAT_VERSION
 blob  compiler — slang::build_tag()                  (identity, checked)
 blob  arguments — SLANG_ARGUMENTS joined with '\0'   (identity, checked)
 4  entry count
 per entry:
 blob        name
 4        stage (slang::STAGE_*)
 blob  source                                         (identity, checked)
 blob  spirv                                          (magic + %4 rechecked)
 blob  diagnostic
 4  layout.push_size
 4  layout.stages
 4  layout.set_count
 4  binding count
 per binding:
 blob        name
 4        set
 4        binding
 4        count
 4        type   (vk::DescriptorType)
 4        stages (vk::ShaderStageFlags)
 4  push field count
 per field:
 blob        name
 4        offset
 4        size
 4        indirect (0 or 1 — a field of the table buffer)

 Trailing bytes past the last field are ignored rather than refused. A torn write
 is short, not long, and everything the module is made of has been read and
 checked by then.
*>
module three;

import std::io::file;
import std::io::path;
import std::collections::list;
import vk;
import slang;

// 'T3SC', read back as a little-endian u32. Named so a file dumped with `xxd`
// says what it is on its first line.
const uint SHADER_CACHE_MAGIC = 0x4353_3354;

<*
 Bumped whenever anything above the source bytes changes meaning.

 It is in the *key* as well as in the file, so a bump does not merely reject old
 entries — it moves every module to a new filename and leaves the old ones to be
 deleted with the directory. It is also the lever for the one case
 `slang::build_tag()` cannot see: two untagged compiler builds reporting the same
 string.

 2 added the compiler tag, above the arguments. 3 added `indirect` to a push
 field, which tells a uniform in the table buffer from one in the block — a
 stored module without it comes back with every field looking pushed, and a
 spilled table's uniforms then have no names at all.
*>
const uint SHADER_CACHE_FORMAT_VERSION = 3;

<*
 Where modules are kept when nothing says otherwise.

 Relative to the working directory, for `shader/load.c3`'s reason: `c3c run`, a
 shell at the project root and `c3c test` all start there. `build/` is
 gitignored, so a warm cache never becomes a diff, and deleting it is the whole
 of "clear the cache".

 It is the default and no longer the whole answer: `main.c3` calls
 `resolve_cache_dir` at boot, which keeps this one for a checkout and picks the
 user's cache directory for anything else. `paths.c3` argues the order.
*>
const String SHADER_CACHE_DEFAULT_DIR = "build/shader-cache";

// The directory is held in a fixed buffer rather than an allocation, because it
// is process-global state with no owner — and a heap copy nothing ever frees is
// a leak in a leak-tracked test run.
const usz SHADER_CACHE_DIR_MAX = 512;

char[SHADER_CACHE_DIR_MAX] cache_dir_storage @local;
String cache_dir @local = SHADER_CACHE_DEFAULT_DIR;
// The prebake, in the same fixed-buffer shape and for the same reason. Empty
// until something points it somewhere, which is every run but a bundled one.
char[SHADER_CACHE_DIR_MAX] read_dir_storage @local;
String read_dir @local;
ShaderCacheStats cache_counters @local;

<*
 What the cache did, since the process started or since the last reset.

 Counters rather than logging: "the same module came back" would also be true of
 a cache that recompiled and threw the result away, so the tests assert on these.
*>
struct ShaderCacheStats
{
	// Modules answered from disk. Slang did not run.
	uint loads;
	// Modules written. Only successful compiles are stored, so this is not
	// `misses` after the fact — a broken shader is a miss and no store.
	uint stores;
	// Lookups with no file to read.
	uint misses;
	// Files that were read and refused: bad magic, an unknown format version, a
	// short read, or a hash hit whose stored arguments or source are not the ones
	// asked for. Each is a recompile and an overwrite, never an error.
	uint invalid;
}

<*
 Points the cache somewhere else, or turns it off.

 @param dir : `The directory to keep modules in. Empty disables the cache entirely — every compile goes to Slang and nothing is read or written.`
*>
fn void shader_cache_set_dir(String dir)
{
	if (dir.len == 0)
	{
		cache_dir = "";
		return;
	}
	if (dir.len > SHADER_CACHE_DIR_MAX)
	{
		@advise("shader cache: '%s' is longer than %d bytes; cache disabled", dir, SHADER_CACHE_DIR_MAX);
		cache_dir = "";
		return;
	}
	mem::copy(&cache_dir_storage[0], dir.ptr, (sz)dir.len);
	cache_dir = (String)cache_dir_storage[:dir.len];
}

<*
 A second directory to read from and never write to.

 What a bundle ships warm. A `.slangmod` is keyed on the source and the compiler
 tag and on nothing about the machine, so the modules a release was built with
 are the modules any machine running that release would compile for itself —
 measured on this desk, 3.5s of Slang against 1.6s with them present.

 Read-only is the whole point rather than a caution: an install directory is not
 writable everywhere, and the thing that *is* per-machine — the driver's pipeline
 blob — is written by `gpu/driver_cache.c3` into the writable directory beside
 it. Two destinations, and neither has to know about the other.

 @param dir : `Where a bundle put its modules. Empty turns the second lookup off, which is the default.`
*>
fn void shader_cache_set_read_dir(String dir)
{
	if (dir.len == 0 || dir.len > SHADER_CACHE_DIR_MAX)
	{
		read_dir = "";
		return;
	}
	mem::copy(&read_dir_storage[0], dir.ptr, (sz)dir.len);
	read_dir = (String)read_dir_storage[:dir.len];
}

<*
 Where modules are kept, or empty when the cache is off.

 `gpu/driver_cache.c3` puts its blob in the same directory: two formats, two
 identity rules, one thing to delete.
*>
fn String shader_cache_dir() => cache_dir;

fn ShaderCacheStats shader_cache_stats() => cache_counters;

fn void shader_cache_reset_stats()
{
	cache_counters = { };
}

// ============================================================================
// Writing
// ============================================================================

fn void cache_put_u32(DString* out, uint value) @local
{
	out.append_char((char)value);
	out.append_char((char)(value >> 8));
	out.append_char((char)(value >> 16));
	out.append_char((char)(value >> 24));
}

fn void cache_put_blob(DString* out, String bytes) @local
{
	cache_put_u32(out, (uint)bytes.len);
	out.append_string(bytes);
}

<*
 `SLANG_ARGUMENTS` as one blob, joined with a byte that cannot occur in a flag.

 Joined rather than length-prefixed one by one because this is compared whole:
 the question the loader asks is "were these the flags", not "which flag
 differs". The separator matters — concatenating without one makes
 `-target spirv` and `-targetspirv` the same blob.

 @return `Allocated from tmem; valid until the enclosing pool is released.`
*>
fn String cache_argument_blob() @local
{
	DString out;
	out.tinit(256);
	foreach (i, argument : SLANG_ARGUMENTS)
	{
		if (i > 0) out.append_char('\0');
		out.append_string(argument);
	}
	return out.str_view();
}

<*
 The filename key: everything that decides what Slang would emit.

 Not a checksum of the file — a hash of the *request*, so a lookup can be one
 `open` rather than a directory walk. It covers what the loader then verifies,
 plus the entry points.

 @param compiler : `slang::build_tag(). In the key so that an SDK upgrade moves every module rather than shadowing it.`
*>
fn ulong cache_key(String compiler, String args, String source, ShaderEntry[] entries) @local
{
	DString key;
	key.tinit(source.len + args.len + compiler.len + 128);
	cache_put_u32(&key, SHADER_CACHE_FORMAT_VERSION);
	// Length-prefixed rather than joined with the arguments, so a tag ending in a
	// flag-shaped suffix cannot spell the same bytes as a different tag and a
	// different first argument.
	cache_put_blob(&key, compiler);
	key.append_string(args);
	foreach (entry : entries)
	{
		key.append_string(entry.name);
		key.append_char('\0');
		cache_put_u32(&key, entry.stage);
	}
	key.append_string(source);
	// FNV-1a, from `gpu/texture.c3`. Not cryptographic and does not need to be: a
	// collision costs one identity check and one recompile.
	return content_hash((char[])key.str_view());
}

fn String cache_path(String dir, ulong key) @local => string::tformat("%s/%016x.slangmod", dir, key);

<*
 Writes one module out.

 Only ever called with `mod.ok`. A cached failure would be handed to the next
 caller as though it were a shader, and the next caller is usually the agent
 having just fixed the typo — on disk, they would be handed it tomorrow as well.

 The diagnostic is stored even so, which is not the same thing: a successful
 compile can warn, and a warning that only appears on the run that compiled is a
 warning the agent stops seeing the moment the cache starts working.

 Nothing here throws. A directory that cannot be created or a file that cannot be
 written costs one stderr line and 17 ms per run, and must not cost a render.
*>
fn void cache_store(String path, String compiler, String args, String source, ShaderModule* mod) @local
{
	@pool()
	{
		DString out;
		out.tinit((sz)(mod.spirv.len + source.len + compiler.len + 1024));

		cache_put_u32(&out, SHADER_CACHE_MAGIC);
		cache_put_u32(&out, SHADER_CACHE_FORMAT_VERSION);
		cache_put_blob(&out, compiler);
		cache_put_blob(&out, args);

		cache_put_u32(&out, (uint)mod.entries.len());
		foreach (entry : mod.entries)
		{
			cache_put_blob(&out, entry.name);
			cache_put_u32(&out, entry.stage);
		}

		cache_put_blob(&out, source);
		cache_put_blob(&out, (String)mod.spirv);
		cache_put_blob(&out, mod.diagnostic);

		cache_put_u32(&out, mod.layout.push_size);
		cache_put_u32(&out, (uint)mod.layout.stages);
		cache_put_u32(&out, mod.layout.set_count);

		cache_put_u32(&out, (uint)mod.layout.bindings.len());
		foreach (binding : mod.layout.bindings)
		{
			cache_put_blob(&out, binding.name);
			cache_put_u32(&out, binding.set);
			cache_put_u32(&out, binding.binding);
			cache_put_u32(&out, binding.count);
			cache_put_u32(&out, (uint)binding.type);
			cache_put_u32(&out, (uint)binding.stages);
		}

		cache_put_u32(&out, (uint)mod.layout.push_fields.len());
		foreach (field : mod.layout.push_fields)
		{
			cache_put_blob(&out, field.name);
			cache_put_u32(&out, field.offset);
			cache_put_u32(&out, field.size);
			cache_put_u32(&out, field.indirect ? 1 : 0);
		}

		// Lazily, on the first store: a process that only ever reads never creates
		// the directory, and one that never compiles never touches the filesystem.
		if (catch err = path::mkdir(cache_dir, recursive: true))
		{
			@advise("shader cache: cannot create %s (%s); compiling every run", cache_dir, err);
			return;
		}
		// One write of the whole file rather than a stream of fields. A crash
		// halfway through leaves a short file, which the loader already refuses and
		// overwrites; a half-written file that *parses* is the failure this avoids
		// being able to produce.
		if (catch err = file::save(path, (char[])out.str_view()))
		{
			@advise("shader cache: cannot write %s (%s); compiling every run", path, err);
			return;
		}
		cache_counters.stores++;
	};
}

// ============================================================================
// Reading
// ============================================================================

<*
 A bounds-checked cursor over a file that is not trusted.

 `bad` latches: once a read has run off the end, every later read returns zero
 without touching memory, so a caller can do a run of reads and check once. That
 is why this is a struct rather than index arithmetic — the alternative is a
 bounds check per field, at every call site, correct every time, in a file that
 exists specifically to consume bytes somebody else wrote.
*>
struct CacheReader @local
{
	char[] bytes;
	usz at;
	bool bad;
}

fn uint CacheReader.u32(&self)
{
	if (self.bad || self.at + 4 > self.bytes.len)
	{
		self.bad = true;
		return 0;
	}
	uint value = (uint)self.bytes[self.at] | ((uint)self.bytes[self.at + 1] << 8)
		| ((uint)self.bytes[self.at + 2] << 16)
		| ((uint)self.bytes[self.at + 3] << 24);
	self.at += 4;
	return value;
}

<*
 @return `A view into the file, not a copy. Empty, with bad set, if the length runs past the end.`
*>
fn String CacheReader.blob(&self)
{
	uint len = self.u32();
	if (self.bad) return "";
	if ((usz)len > self.bytes.len - self.at)
	{
		self.bad = true;
		return "";
	}
	String out = (String)self.bytes[self.at:(usz)len];
	self.at += len;
	return out;
}

<*
 Could `count` items of at least `each` bytes still fit?

 Asked after every count is read, before the loop that consumes it. Without it a
 corrupt count of four billion is four billion iterations of a latched-bad reader
 — correct, and seconds long. `each` is the *minimum* an item can occupy: a blob
 is at least its own four-byte length.
*>
fn bool CacheReader.room_for(&self, uint count, usz each)
{
	if (self.bad) return false;
	return (usz)count * each <= self.bytes.len - self.at;
}

fn bool cache_reject() @local
{
	cache_counters.invalid++;
	return false;
}

<*
 Reads one module back, or says why not.

 Every failure is the same answer to the caller — recompile and overwrite — so
 this returns a bool rather than a fault, and records which kind it was in the
 counters. `misses` is "there was no file"; `invalid` is "there was one and it
 could not be believed", and the tests need to tell those apart.

 The module is built only once every byte has been read and checked, so there is
 no half-allocated module to unwind. What it allocates and how is
 `compile_slang`'s answer exactly — `mem` for the SPIR-V, `.copy(mem)` for every
 string, `.init(mem, n)` for both lists — because `ShaderModule.free` is the only
 free either kind of module ever gets.

 @param [out] out : `Filled only on true. Untouched otherwise.`
 @return `True if out now holds a module Slang did not have to produce.`
*>
fn bool cache_load(String path, String compiler, String args, String source, ShaderModule* out, bool count_miss = true) @local
{
	@pool()
	{
		char[]? bytes = file::load(tmem, path);
		if (catch bytes)
		{
			if (count_miss) cache_counters.misses++;
			return false;
		}

		CacheReader reader = { .bytes = bytes };

		if (reader.u32() != SHADER_CACHE_MAGIC) return cache_reject();
		if (reader.u32() != SHADER_CACHE_FORMAT_VERSION) return cache_reject();

		// Identity, not the hash. See the header.
		String stored_compiler = reader.blob();
		String stored_args     = reader.blob();
		if (reader.bad) return cache_reject();
		if (stored_compiler != compiler) return cache_reject();
		if (stored_args != args) return cache_reject();

		uint entry_count = reader.u32();
		if (!reader.room_for(entry_count, 8)) return cache_reject();
		List{ShaderEntry} entries;
		entries.tinit(entry_count > 0 ? entry_count : 1);
		for (uint i = 0; i < entry_count; i++)
		{
			ShaderEntry entry;
			entry.name = reader.blob();
			entry.stage = reader.u32();
			if (reader.bad) return cache_reject();
			entries.push(entry);
		}

		String stored_source = reader.blob();
		String spirv         = reader.blob();
		String diagnostic    = reader.blob();
		if (reader.bad) return cache_reject();

		// The second half of the identity check, and the expensive-looking one: a
		// few kilobytes compared per lookup against 17 ms of Slang.
		if (stored_source != source) return cache_reject();

		// Both of `compile_slang`'s checks on Slang's own output, asked again of a
		// file that has been sitting on disk. Byte-wise rather than through a
		// `uint*` because this pointer is at whatever offset the source length left
		// it at.
		if (spirv.len < 4 || spirv.len % 4 != 0) return cache_reject();
		uint spirv_magic = (uint)spirv[0] | ((uint)spirv[1] << 8) | ((uint)spirv[2] << 16) | ((uint)spirv[3] << 24);
		if (spirv_magic != SPIRV_MAGIC) return cache_reject();

		uint push_size = reader.u32();
		uint stages    = reader.u32();
		uint set_count = reader.u32();

		uint binding_count = reader.u32();
		// A blob plus five numbers: twenty-four bytes at the very least.
		if (!reader.room_for(binding_count, 24)) return cache_reject();
		List{ShaderBinding} bindings;
		bindings.tinit(binding_count > 0 ? binding_count : 1);
		for (uint i = 0; i < binding_count; i++)
		{
			ShaderBinding binding;
			binding.name = reader.blob();
			binding.set = reader.u32();
			binding.binding = reader.u32();
			binding.count = reader.u32();
			binding.type = (vk::DescriptorType)reader.u32();
			binding.stages = (vk::ShaderStageFlags)reader.u32();
			if (reader.bad) return cache_reject();
			bindings.push(binding);
		}

		uint field_count = reader.u32();
		// A blob plus three numbers.
		if (!reader.room_for(field_count, 16)) return cache_reject();
		List{ShaderField} fields;
		fields.tinit(field_count > 0 ? field_count : 1);
		for (uint i = 0; i < field_count; i++)
		{
			ShaderField field;
			field.name = reader.blob();
			field.offset = reader.u32();
			field.size = reader.u32();
			field.indirect = reader.u32() != 0;
			if (reader.bad) return cache_reject();
			fields.push(field);
		}

		ShaderModule loaded;
		// A module that was stored is a module that compiled — nothing else is
		// written. See `cache_store`.
		loaded.ok = true;

		loaded.spirv = alloc::new_array(mem, char, spirv.len);
		loaded.spirv[..] = ((char[])spirv)[..];
		loaded.diagnostic = diagnostic.copy(mem);

		loaded.entries.init(mem, entries.len() > 0 ? entries.len() : 1);
		foreach (entry : entries)
		{
			loaded.entries.push({ .name = entry.name.copy(mem), .stage = entry.stage });
		}

		loaded.layout.push_size = push_size;
		loaded.layout.stages = (vk::ShaderStageFlags)stages;
		loaded.layout.set_count = set_count;
		loaded.layout.bindings.init(mem, bindings.len() > 0 ? bindings.len() : 1);
		foreach (binding : bindings)
		{
			ShaderBinding copied = binding;
			copied.name = binding.name.copy(mem);
			loaded.layout.bindings.push(copied);
		}
		loaded.layout.push_fields.init(mem, fields.len() > 0 ? fields.len() : 1);
		foreach (field : fields)
		{
			ShaderField copied = field;
			copied.name = field.name.copy(mem);
			loaded.layout.push_fields.push(copied);
		}

		*out = loaded;
		cache_counters.loads++;
		return true;
	};
}

// ============================================================================
// The entry point
// ============================================================================

<*
 `compile_slang`, with yesterday's answer if there is one.

 Identical to `compile_slang` in everything a caller can observe except time:
 same module, same layout, same entry points, same diagnostic, same ownership —
 the result is freed with `ShaderModule.free` whichever way it arrived. A cache
 that cannot be read, cannot be written, or does not agree byte for byte with
 what was asked for is invisible here.

 A failed compile is still not a fault and is still not stored. It comes back
 `ok: false` with the diagnostic attached.

 @param name : `What the source is called in diagnostics. Not a path, never opened, and not part of the key — two names over identical source are one module.`
 @param entries : `The entry points to compile. Part of the key.`
 @param [out] compiled : `Set true when Slang actually ran, false when the module came off disk. PipelineCache.compiles counts this, so a compile keeps meaning Slang ran.`
 @return ? SLANG_UNAVAILABLE : `The session would not start. Only reachable on a miss.`
 @return ? SHADER_NOT_SPIRV : `Slang reported success and returned something that is not a module. Only reachable on a miss — a stored module that fails the same check is a miss, not a fault.`
*>
fn ShaderModule? compile_slang_cached(String source, String name, ShaderEntry[] entries, bool* compiled = null)
{
	if (compiled != null) *compiled = false;

	if (cache_dir.len == 0)
	{
		if (compiled != null) *compiled = true;
		return compile_slang(source, name, entries);
	}

	@pool()
	{
		String compiler = slang::build_tag();
		String args     = cache_argument_blob();
		ulong key       = cache_key(compiler, args, source, entries);
		String path     = cache_path(cache_dir, key);

		// The writable directory first, and the miss counted only if there is
		// nowhere else to look — a lookup is one lookup however many directories
		// answer it, and `misses` is what the tests read as "Slang ran".
		ShaderModule loaded;
		if (cache_load(path, compiler, args, source, &loaded, count_miss: read_dir.len == 0))
		{
			@debug_log("shader cache: %s hit %s", name, path);
			return loaded;
		}

		// Then the prebake. Nothing is copied across on a hit: the file that
		// answered is as good where it is, and writing it into the user's cache
		// would double a bundle's modules on disk to save no work at all.
		if (read_dir.len > 0)
		{
			String bundled = cache_path(read_dir, key);
			if (cache_load(bundled, compiler, args, source, &loaded))
			{
				@debug_log("shader cache: %s hit %s (bundled)", name, bundled);
				return loaded;
			}
		}

		// The interesting half of the pair: a miss means Slang runs, which is the
		// difference between a startup measured in milliseconds and one measured in
		// tenths of a second, and it is invisible from the outside. `%s miss` on
		// every run is a key that is not stabilising.
		@debug_log("shader cache: %s miss %s", name, path);
		ShaderModule mod = compile_slang(source, name, entries)!;
		if (compiled != null) *compiled = true;
		// Overwrites whatever was there, which is the answer to every way a lookup
		// can fail: a truncated file, a file from a format that no longer exists,
		// and a hash collision all end here.
		if (mod.ok) cache_store(path, compiler, args, source, &mod);
		return mod;
	};
}