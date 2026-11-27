<*
 `three.loadAsync`'s worker: `Assets.load` with the file read, the parse and the
 texture transcode moved off the main thread.

 The split is `read_asset` and `Assets.adopt`. The first touches nothing shared
 and runs on a thread of its own; the second builds the physics proxies, which
 upload, and files the asset in the table, so it runs on the main thread when
 the runtime finds the worker done — `JsRuntime.step_load`.

 Nothing here is on `Assets` until `finish_load`, so `unload_unused` cannot free
 a load under its worker: there is nothing in the table to free.

 A load nobody wants any more is dropped, not abandoned. `drop` asks the worker
 to stop at its next step, waits for it, and frees what it read, so a script
 that ends mid-load waits for at most the step in progress.
*>
module three;

import std::thread;

excuse ASSET_LOAD_CANCELLED;

// The worker's temp arena. It grows on demand; this is only the first block.
const sz LOAD_POOL_BYTES = 1024 * 1024;

<*
 One file on its way through a worker thread.

 Owned by whoever called `start_load`, until it goes to `finish_load` or `drop`,
 both of which free it.
*>
struct AssetLoad
{
	// As resolved, which is what the table is keyed on. Owned.
	String path;
	// `basis_targets`' answer, asked on the main thread.
	BasisTargets targets;
	// The main thread's heap. A spawned thread's `mem` is libc's directly, and
	// everything this reads is freed on the main thread — under `c3c test` that
	// is the leak tracker, which panics on a pointer it never saw.
	Allocator allocator;
	Thread thread;
	bool spawned;
	// Atomics: `done` is the worker's to set, `cancelled` the main thread's.
	int done;
	int cancelled;
	// What the worker answered: `asset` when `failure` is empty.
	Asset asset;
	fault failure;
}

<*
 Start reading a file on a worker thread.

 If the thread will not start, the file is read here instead, so the load still
 finishes; it is only slower to give the frame back.

 @param path : `Resolved, as Assets.load takes it. Copied.`
 @return `The load. Pass it to finish_load or drop.`
*>
fn AssetLoad* Assets.start_load(&self, Gpu* gpu, String path)
{
	if (!self.started) self.init();

	AssetLoad* load = mem::new(AssetLoad);
	*load = { .path = path.copy(mem), .targets = basis_targets(gpu), .allocator = mem };
	if (catch load.thread.create(&load_main, load))
	{
		load.run();
		return load;
	}
	load.spawned = true;
	return load;
}

fn int load_main(void* arg) @local
{
	AssetLoad* load = (AssetLoad*)arg;
	mem::@scoped(load.allocator)
	{
		// The standard library will not make a temp arena on a spawned thread
		// by itself, and the parse and the transcoder both use one.
		@pool_init(mem, LOAD_POOL_BYTES)
		{
			load.run();
		};
	};
	return 0;
}

fn void AssetLoad.run(&self)
{
	Asset? read = read_asset(self.path, self.targets, ahead: true, cancelled: &self.cancelled);
	if (catch err = read)
	{
		self.failure = err;
	}
	else
	{
		self.asset = read;
	}
	@atomic_store(self.done, 1);
}

// Whether the worker has finished, so `finish_load` will not wait.
fn bool AssetLoad.ready(&self) => @atomic_load(self.done) != 0;

fn void AssetLoad.join(&self)
{
	if (!self.spawned) return;
	(void)self.thread.join();
	self.spawned = false;
}

fn void AssetLoad.free(&self)
{
	self.path.free(mem);
	mem::free(self);
}

<*
 Wait for the worker, file what it read, and free the load.

 If a synchronous `three.load` filed the same path while this was reading, that
 asset is the answer and what this read is freed: the table holds a path once.

 @param [&inout] load : "From start_load. Freed here"
 @return? read_asset!
*>
fn AssetId? Assets.finish_load(&self, Gpu* gpu, AssetLoad* load)
{
	load.join();
	defer load.free();
	if (load.failure) return load.failure~;

	AssetId loaded = self.find_loaded(load.path);
	if (loaded.is_set())
	{
		free_asset_memory(null, &load.asset);
		return loaded;
	}
	return self.adopt(gpu, load.asset);
}

<*
 Stop a load nobody wants, wait for its worker, and free everything.

 The worker stops at its next step rather than at once, so this waits for at
 most the step in progress.

 @param [&inout] self : "From start_load. Freed here"
*>
fn void AssetLoad.drop(&self)
{
	@atomic_store(self.cancelled, 1);
	self.join();
	// Nothing here was uploaded, so there is no device to give anything back to.
	if (!self.failure) free_asset_memory(null, &self.asset);
	self.free();
}
