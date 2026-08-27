<*
 What the renderer noticed, kept where the agent driving it can read.

 ## The problem this exists for

 Every diagnostic in this project used to be an `io::eprintfn`, and stderr is a
 file descriptor. A person at the terminal reads it; an agent driving `--mcp`
 over HTTP cannot, and never could. So the heuristics that watch for a leak —
 live scenes, live materials, a shader that would not compile — were writing
 correct advice into a place the one reader who needed it has no way to open.

 `@advise` writes to both. The terminal keeps exactly what it had, and
 `run_script` answers with a `warnings` array beside `log`, which is what makes
 the advice reach the caller who caused it.

 ## Beside `log`, not inside it

 A warning is advice and `console.log` is the script's own output. Folding one
 into the other means an agent cannot tell which of the two it is reading, and an
 agent that cannot tell advice from its own printing stops believing either.
 `JsRuntime.collect_validation` made the same split for the validation layer and
 for the same reason.

 ## One message is one line

 Messages are stored end to end and separated by newlines, so a message that
 carries newlines of its own — a Slang diagnostic is several lines — is flattened
 to spaces on the way in. That keeps "split on newline" a correct way to get the
 array back, which is what `mcp/server.c3` does.

 ## Fixed storage, no allocator

 A global with no `init` and no `free`, for `material_message`'s reason: this is
 read on paths that have no allocator in scope and no owned value to release. The
 storage is small because the advice is: every one of these is a sentence, they
 are deduplicated, and the ones that could repeat per frame already double their
 own threshold. What does not fit is counted rather than dropped silently.

 ## Not thread safe, and does not need to be

 `ValidationSink`'s argument exactly: the scene, the JS context and the device
 are single-threaded, `Listener.pump` runs the handlers on the loop's own thread,
 and every writer here is on that thread.
*>
module three;

import std::io;

// Room for the advice one run can produce. Every message is a sentence and they
// are deduplicated, so this is far above the count any real run reaches — the
// bound is here so that a diagnostic that repeats cannot grow without one.
const usz ADVICE_BYTES = 4096;
const usz ADVICE_MAX = 16;

char[ADVICE_BYTES] advice_storage @local;
usz advice_used @local;
// Where each message ends in `advice_storage`. The starts are the previous
// ends, which is what makes a message a slice rather than a copy.
usz[ADVICE_MAX] advice_ends @local;
usz advice_held @local;
usz advice_lost @local;

<*
 Says something to the terminal and to whoever is driving the process.

 The replacement for `io::eprintfn` at every site that was diagnosing something
 about the *script* rather than about the build. Takes printf arguments and
 evaluates them unconditionally — unlike `@debug_log`, this is advice a release
 build has to give.
*>
macro @advise(format, ...)
{
	three::advise_note(string::tformat(format, ...$vaarg));
}

<*
 Records one message, and prints it.

 Printed whatever happens, including when the sink is full: the terminal is the
 reader that was never in doubt, and losing a line there to a bound that exists
 for the other reader would be the fix breaking what it was extending.

 Deduplicated against everything the sink already holds. The messages that can
 repeat are the ones that fire from a frame — a shader that will not compile
 says the same sentence sixty times a second — and a `warnings` array with sixty
 identical entries is a worse answer than one entry.
*>
fn void advise_note(String message)
{
	io::eprintn(message);
	if (message.len == 0) return;

	for (usz i = 0; i < advice_held; i++)
	{
		if (advice_line(i) == message) return;
	}

	// The message and the newline that separates it from the next one. Counted
	// before the copy rather than after, because a message that does not fit is
	// a message not written at all — half of one is worse than none.
	usz needed = (usz)message.len + 1;
	if (advice_held == ADVICE_MAX || advice_used + needed > ADVICE_BYTES)
	{
		advice_lost++;
		return;
	}

	foreach (i, c : message)
	{
		// One message is one line — see the header. The newline is the separator,
		// so a message carrying its own would split into two.
		advice_storage[advice_used + (usz)i] = (c == '\n' || c == '\r') ? ' ' : c;
	}
	advice_used += (usz)message.len;
	advice_ends[advice_held] = advice_used;
	advice_held++;
	advice_storage[advice_used] = '\n';
	advice_used++;
}

// How many messages the sink is holding.
fn usz advice_count() => advice_held;

// How many were refused for want of room. Reported rather than hidden: a count
// that silently stopped rising would read as advice that stopped being given.
fn usz advice_dropped() => advice_lost;

<*
 One message, with no newline on it.

 @require index < advice_held : "no message there"
 @return `A view into the sink, valid until the next advice_clear.`
*>
fn String advice_line(usz index)
{
	// The previous message's end, plus the newline that follows it.
	usz from = index == 0 ? 0 : advice_ends[index - 1] + 1;
	usz to = advice_ends[index];
	return (String)advice_storage[from:to - from];
}

<*
 Everything held, newline separated, and empty when there is nothing.

 The shape `RunResult.warnings` carries, for the one reason the array is not
 built here: this file has no allocator and the caller does. No trailing
 newline, so splitting on one gives the messages and nothing else.

 @return `A view into the sink, valid until the next advice_clear.`
*>
fn String advice_all()
{
	if (advice_held == 0) return "";
	return (String)advice_storage[:advice_used - 1];
}

// Forgets everything. Called once a run has folded the sink into its answer —
// `JsRuntime.collect_advice` has which run, and why it is not every run.
fn void advice_clear()
{
	advice_used = 0;
	advice_held = 0;
	advice_lost = 0;
}
