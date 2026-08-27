<*
 The other half of a shader's startup cost: the driver turning SPIR-V into a
 `VkPipeline`.

 `shader/disk_cache.c3` keeps the seventeen-millisecond half, the Slang compile.
 This keeps the remaining millisecond per pipeline, by handing
 `createGraphicsPipelines` a `VkPipelineCache` warmed with the blob the driver
 produced last time.

 ## Why a second format rather than a field in the first

 The two caches are keyed on different things and invalidated by different
 events. A shader module is portable — SPIR-V is the same bytes on every device,
 which is why `disk_cache.c3` keeps the device *out* of its key. A pipeline blob
 is the opposite: opaque driver memory whose only documented validity rule is the
 device's own `pipelineCacheUUID`, and a driver update invalidates every byte of
 it with no error and no version bump this side can see.

 ## The blob is not trusted

 `vkCreatePipelineCache` says a driver handed data that is not its own may do
 anything at all. The header fields exist for the driver to check and most do,
 but undefined behaviour is the contract and a corrupted blob is not required to
 be detected. Believing a bad shader-cache file costs a wrong shader; believing a
 bad blob costs whatever the driver decides.

 So the payload is wrapped in a header this side writes and checks, and the
 driver is only handed bytes that came back from *this* device, *this* driver
 version and *this* `pipelineCacheUUID`. A file failing any of those is a miss:
 not opened, not repaired, not deleted — just overwritten by the next save.

 ## What it is worth here: nothing, measured

 On this machine, with the Slang half already warm either way:

	                          examples/chain.js   examples/village.js
	warm (blob on disk)       0.21 s              0.61-0.68 s
	cold (blob deleted)       0.21-0.22 s         0.62-0.64 s

 Five runs and three runs; the difference is inside the noise. MoltenVK does not
 pay for pipeline creation the way a desktop driver does — it is a Metal pipeline
 built from MSL that Slang's SPIR-V has already been turned into, and the
 expensive part of that is upstream, in the half `shader/disk_cache.c3` keeps.

 Kept anyway: the mechanism is where a desktop driver would need it, it is
 correct, and it costs one read at startup and usually no write at all. The
 measurement is recorded here because "we added a cache" and "the cache helped"
 are different claims and only the first is true on this machine.

 ## The file

 Little-endian throughout.

	bytes  field
	-----  ------------------------------------------------------------------
	    4  magic — 'T3PC' as the four bytes T, 3, P, C
	    4  DRIVER_CACHE_FORMAT_VERSION
	    4  vendorID                                       (identity, checked)
	    4  deviceID                                       (identity, checked)
	    4  driverVersion                                  (identity, checked)
	   16  pipelineCacheUUID                              (identity, checked)
	    4  payload length
	    N  payload — whatever vkGetPipelineCacheData returned

 Trailing bytes past the payload are ignored, and a payload shorter than its
 length is a miss. A torn write is short, not long.
*>
module three;

import std::io;
import std::io::file;
import std::io::path;
import vk;

// 'T3PC', read back as a little-endian u32.
const uint DRIVER_CACHE_MAGIC = 0x4350_3354;

<*
 Bumped whenever anything above the payload changes meaning.

 It is in the identity *and* in the filename hash, so a bump moves every blob to
 a new name rather than merely rejecting the old one.
*>
const uint DRIVER_CACHE_FORMAT_VERSION = 1;

<*
 The driver's own cache, and what it was created from.

 One per `Gpu`, because its validity is a property of the device. Zero-valued
 until `open`, and every method is safe on a zero one: a runtime with no device
 has no pipelines to cache and must not be made to care.
*>
struct DriverCache
{
	vk::PipelineCache handle;
	// Everything the blob's validity depends on, kept so `save` writes the same
	// identity `open` checked without asking the physical device twice.
	uint vendor;
	uint device;
	uint driver_version;
	char[vk::UUID_SIZE] uuid;
	// How many bytes this was created from, and whether there were any. `save`
	// writes only when the driver's blob has grown past this.
	usz loaded_size;
	bool warmed;
	// False when there is nowhere to write — `shader_cache_set_dir("")`, or a
	// directory that could not be made. The handle is still created: a cache
	// that cannot be persisted is still worth having *within* a process, since
	// the mesh pipeline's two sides and a material's variants are several
	// pipelines off one module.
	bool persisted;
}

<*
 What the driver cache did this process.

 Counters rather than logging: a line saying "it loaded" would be true of a cache
 that loaded and then ignored what it read.
*>
struct DriverCacheStats
{
	// Blobs handed to `vkCreatePipelineCache`. At most one per device.
	uint loads;
	// Lookups with no file to read.
	uint misses;
	// Files read that were not this device's, or were not a file this wrote.
	uint invalid;
	// Blobs written back because the driver had added something.
	uint stores;
	// Saves that found nothing new in the blob and wrote nothing. The common
	// case on the second and every later run.
	uint unchanged;
}

DriverCacheStats driver_cache_counters @local;

fn DriverCacheStats driver_cache_stats() => driver_cache_counters;

fn void driver_cache_reset_stats()
{
	driver_cache_counters = {};
}

<*
 The filename: a hash of the identity, formatted like the shader cache's.

 A *filter*. Two devices on one machine get two files without either being asked
 to check the other, and a driver update writes a new name and abandons the old
 one — so "clear the cache" is still "delete the directory".

 @return `Allocated from tmem; valid until the enclosing pool is released.`
*>
fn String driver_cache_path(DriverCache* cache) @local
{
	char[32] identity;
	identity[0] = (char)DRIVER_CACHE_FORMAT_VERSION;
	identity[1] = (char)(DRIVER_CACHE_FORMAT_VERSION >> 8);
	identity[2] = (char)(DRIVER_CACHE_FORMAT_VERSION >> 16);
	identity[3] = (char)(DRIVER_CACHE_FORMAT_VERSION >> 24);
	uint[3] numbers = { cache.vendor, cache.device, cache.driver_version };
	foreach (i, number : numbers)
	{
		identity[4 + i * 4] = (char)number;
		identity[5 + i * 4] = (char)(number >> 8);
		identity[6 + i * 4] = (char)(number >> 16);
		identity[7 + i * 4] = (char)(number >> 24);
	}
	identity[16..31] = cache.uuid[0..15];
	return string::tformat("%s/%016x.vkpipe", shader_cache_dir(), content_hash(identity[..]));
}

<*
 Does this file's header say it is ours, and this device's?

 Every read is bounds-checked against the length actually on disk: this payload
 is handed to a driver, and a driver handed bytes that are not its own is
 entitled to do anything at all.

 @return `The payload, or an empty slice if anything at all disagrees.`
*>
fn char[] driver_cache_payload(char[] bytes, DriverCache* cache) @local
{
	if (bytes.len < 40) return {};

	uint magic = driver_read_u32(bytes, 0);
	uint version = driver_read_u32(bytes, 4);
	if (magic != DRIVER_CACHE_MAGIC) return {};
	if (version != DRIVER_CACHE_FORMAT_VERSION) return {};

	if (driver_read_u32(bytes, 8) != cache.vendor) return {};
	if (driver_read_u32(bytes, 12) != cache.device) return {};
	if (driver_read_u32(bytes, 16) != cache.driver_version) return {};
	// The one the spec actually names. Checked byte by byte rather than by
	// comparing two slices, so a shorter file cannot reach past its end.
	for (usz i = 0; i < vk::UUID_SIZE; i++)
	{
		if (bytes[20 + i] != cache.uuid[i]) return {};
	}

	usz length = (usz)driver_read_u32(bytes, 36);
	if (length == 0) return {};
	if (40 + length > bytes.len) return {};
	return bytes[40 : length];
}

fn void driver_put_u32(DString* out, uint value) @local
{
	out.append_char((char)value);
	out.append_char((char)(value >> 8));
	out.append_char((char)(value >> 16));
	out.append_char((char)(value >> 24));
}

fn uint driver_read_u32(char[] bytes, usz at) @local
{
	return (uint)bytes[at]
		| ((uint)bytes[at + 1] << 8)
		| ((uint)bytes[at + 2] << 16)
		| ((uint)bytes[at + 3] << 24);
}

<*
 Creates the driver's cache for this device, warm if there is a blob to warm it
 with.

 Nothing here throws. A cache is an optimisation: a file that cannot be read
 costs a millisecond a pipeline, and a `vkCreatePipelineCache` that fails costs
 the same and leaves a null handle that every `.build` call is already allowed to
 be given. Neither may cost a render.

 @param properties : `The device's, already queried by Gpu.init — asking again would be a second call whose answer could not differ.`
*>
fn void DriverCache.open(&self, Gpu* gpu, vk::PhysicalDeviceProperties* properties)
{
	*self = {
		.vendor = properties.vendorID,
		.device = properties.deviceID,
		.driver_version = properties.driverVersion,
	};
	self.uuid[0..15] = properties.pipelineCacheUUID[0..15];
	self.persisted = shader_cache_dir().len > 0;

	if (gpu.handle == null) return;

	@pool()
	{
		char[] payload = {};
		if (self.persisted)
		{
			String where = driver_cache_path(self);
			char[]? bytes = file::load(tmem, where);
			if (catch bytes)
			{
				driver_cache_counters.misses++;
			}
			else
			{
				payload = driver_cache_payload(bytes, self);
				if (payload.len == 0)
				{
					driver_cache_counters.invalid++;
					@debug_log("driver cache: %s is not this device's", where);
				}
			}
		}

		vk::PipelineCacheCreateInfo info = vk::pipelineCacheCreateInfo()
			.setInitialDataSize((sz)payload.len)
			.setInitialData(payload.len > 0 ? (void*)payload.ptr : null);

		vk::PipelineCache? made = info.build(gpu.handle);
		if (catch err = made)
		{
			@advise("driver cache: cannot create (%s); every pipeline is built from scratch", err);
			self.handle = (vk::PipelineCache)null;
			self.persisted = false;
			return;
		}
		self.handle = made;

		if (payload.len > 0)
		{
			self.loaded_size = payload.len;
			self.warmed = true;
			driver_cache_counters.loads++;
			@debug_log("driver cache: warmed with %d bytes", (int)payload.len);
		}
	};
}

<*
 Writes the blob back, if the driver added anything to it.

 Called from `Gpu.free` after the device has gone idle. Two
 `vkGetPipelineCacheData` calls, as the spec's size-then-data pattern requires.

 A run that was never warmed writes. A run that was writes only if the blob came
 back *larger* than it went in — growth rather than difference, because
 MoltenVK's serialization is not byte-stable and difference is true on every run,
 which would rewrite 300 KB forever.

 What growth gives up is a driver that rewrites its blob smaller while adding
 something (an eviction, a re-pack). That entry is not kept, and one pipeline is
 built the slow way next run. It is the right side to lose on, and it converges:
 this machine loads 301352, produces 301356, writes it; the next run loads
 301356, produces 301352, and stops.
*>
fn void DriverCache.save(&self, Gpu* gpu)
{
	if (!self.persisted || self.handle == null || gpu.handle == null) return;

	@pool()
	{
		sz size = 0;
		if (catch vk::getPipelineCacheData(gpu.handle, self.handle, &size, null)) return;
		if (size <= 0) return;

		char[] payload = alloc::new_array(tmem, char, (sz)size);
		if (catch vk::getPipelineCacheData(gpu.handle, self.handle, &size, payload.ptr)) return;
		// The driver may report a *smaller* size on the second call — the spec
		// allows it, and a blob written at the length it was asked for rather
		// than the length it came back with would carry whatever was in the tail.
		if ((usz)size < payload.len) payload = payload[:(usz)size];

		if (self.warmed && payload.len <= self.loaded_size)
		{
			driver_cache_counters.unchanged++;
			return;
		}

		if (catch err = path::mkdir(shader_cache_dir(), recursive: true))
		{
			@advise("driver cache: cannot create %s (%s); every run builds its own pipelines",
				shader_cache_dir(), err);
			return;
		}

		DString out;
		out.tinit(payload.len + 64);
		driver_put_u32(&out, DRIVER_CACHE_MAGIC);
		driver_put_u32(&out, DRIVER_CACHE_FORMAT_VERSION);
		driver_put_u32(&out, self.vendor);
		driver_put_u32(&out, self.device);
		driver_put_u32(&out, self.driver_version);
		foreach (byte : self.uuid) out.append_char(byte);
		driver_put_u32(&out, (uint)payload.len);
		out.append_string((String)payload);

		String where = driver_cache_path(self);
		if (catch err = file::save(where, (char[])out.str_view()))
		{
			@advise("driver cache: cannot write %s (%s)", where, err);
			return;
		}
		driver_cache_counters.stores++;
		@debug_log("driver cache: wrote %d bytes to %s", (int)payload.len, where);
	};
}

<*
 Destroys the handle. `save` first — `Gpu.free` does both, in that order.
*>
fn void DriverCache.free(&self, Gpu* gpu)
{
	if (self.handle != null && gpu.handle != null)
	{
		vk::destroyPipelineCache(gpu.handle, self.handle, null);
	}
	*self = {};
}
