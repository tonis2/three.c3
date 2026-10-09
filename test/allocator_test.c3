<*
 The device-memory allocator: pages handed back, reused, and never pinned.

 `c3c test --test-filter three_tests::allocator`

 Each check makes its own `vk::MemoryAllocator` on the shared device, with 1 MB
 pages, so what it counts is its own and an allocation bigger than 1 MB takes a
 dedicated page without costing the suite real VRAM.
*>
module three_tests::allocator;

import three;
import three_tests::device;
import vk;
import std::core::test;

const sz PAGE = 1 << 20;
const sz MB = 1 << 20;

macro @with_allocator(; @body(vk::MemoryAllocator* a))
{
	three::Renderer* renderer = device::borrow(with_pass: false);
	defer device::release();
	vk::MemoryAllocator* shared = &renderer.gpu.allocator;
	vk::MemoryAllocator a = {
		.device = shared.device,
		.pdevice = shared.pdevice,
		.queue = shared.queue,
		.default_page_size = PAGE,
	};
	a.init()!!;
	defer a.free();

	@body(&a);
}

fn vk::Memory make(vk::MemoryAllocator* a, sz size)
{
	return vk::new_buffer(
		a,
		usage: vk::BufferUsageFlagBits.BUFFER_USAGE_STORAGE_BUFFER_BIT,
		properties: vk::MemoryPropertyFlagBits.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
		data_size: size
	)!!;
}

<*
 A freed big buffer's page does not stay under the next, bigger one.

 The leak a long-running process hit: every size it ever asked for kept its own
 page, freed or not, because a page only went back on a call nobody made. A
 generation at a new size then allocated on top of the last one's.
*>
fn void a_freed_page_does_not_stay_under_a_bigger_one() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory first = make(a, 4 * MB);
		first.free();
		test::@check(a.stats().idle_pages == 1, "the freed page was not idle: %d idle", a.stats().idle_pages);

		vk::Memory second = make(a, 8 * MB);
		defer second.free();
		vk::MemoryStats s = a.stats();
		test::@check(s.pages == 1, "the idle 4 MB page stayed beside the 8 MB one: %d pages", s.pages);
		test::@check(s.allocated < 9 * MB, "%d bytes held for one 8 MB buffer", s.allocated);
	};
}

// The same buffer made again at the same size takes the page it left.
fn void a_buffer_made_again_reuses_its_page() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory first = make(a, 4 * MB);
		vk::MemoryPage* page = first.page;
		first.free();

		vk::Memory again = make(a, 4 * MB);
		defer again.free();
		test::@check(again.page == page, "the same size made a new page");
		test::@check(a.stats().pages == 1, "%d pages for one buffer", a.stats().pages);
	};
}

<*
 A small allocation never lands in a big idle page.

 First fit over every page used to put it in whatever freed hole came first -
 a 1 KB buffer in a 4 MB page kept all 4 MB from ever going back.
*>
fn void a_small_buffer_does_not_pin_a_big_page() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory big = make(a, 4 * MB);
		big.free();

		vk::Memory small = make(a, 1024);
		defer small.free();
		test::@check(!small.page.dedicated, "a 1 KB buffer was put in the 4 MB page");
		test::@check(a.stats().allocated <= PAGE, "%d bytes held for a 1 KB buffer", a.stats().allocated);
	};
}

<*
 A shared page freed out of order comes back whole.

 The old test for an empty page was its holes merging back into exactly
 `[0, used)`, and alignment padding never went on the free list - so a page
 that had been reused could stay "in use" with nothing in it, forever.
*>
fn void a_shared_page_freed_out_of_order_comes_back_whole() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory[6] held;
		sz[6] sizes = { 1000, 70_000, 300, 4096, 129_000, 17 };
		foreach (i, size : sizes) held[i] = make(a, size);
		vk::MemoryPage* page = held[0].page;
		foreach (m : held) test::@check(m.page == page, "six small buffers did not share a page");

		int[6] order = { 3, 0, 5, 1, 4, 2 };
		foreach (k, i : order)
		{
			held[i].free();
			if (k < 5)
			{
				sz live;
				foreach (j, m : held) if (m.size > 0) live += m.size + m.padding;
				test::@check(page.used_size == live, "after %d frees the page says %d used, %d live", k + 1, page.used_size, live);
			}
		}
		test::@check(page.idle(), "the page still counts %d allocations", page.live);
		test::@check(page.used_size == 0, "an empty page says %d bytes used", page.used_size);
		test::@check(page.free_blocks.len() == 1 && page.free_blocks[0].size == page.size, "an empty page is not one free block");
	};
}

// `trim()` gives back every page holding nothing, and only those.
fn void trim_gives_back_idle_pages_only() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory kept = make(a, 2 * MB);
		defer kept.free();
		vk::Memory gone = make(a, 1024);
		gone.free();

		sz released = a.trim();
		test::@check(released == PAGE, "trim gave back %d bytes, expected the one idle page", released);
		test::@check(a.stats().pages == 1 && a.stats().idle_pages == 0, "trim took the live page or left the idle one");
	};
}

// A deferred delete holds its page until `sync()`, and gives it back after.
fn void a_deferred_delete_holds_its_page_until_sync() @test
{
	@with_allocator(; vk::MemoryAllocator* a)
	{
		vk::Memory later = make(a, 4 * MB);
		later.mark_deleted();
		test::@check(a.trim() == 0, "trim released a page with a pending delete in it");
		a.sync();
		test::@check(a.stats().idle_pages == 1, "sync did not give the block back");
		test::@check(a.trim() == 4 * MB, "the page did not go back after sync");
	};
}
