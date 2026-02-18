/**
Memory allocators for WASM builtins.

Provides a bump-pointer $(LREF Region) allocator modelled after
$(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html,
`std.experimental.allocator.building_blocks.region`).

See_Also:
    $(LREF WasmAllocator), $(LREF newWasmAllocator)
*/
module nix_wasm.memory;

/**
Bump-pointer region allocator for WASM, modelled after
$(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html,
`std.experimental.allocator.building_blocks.region.Region`).

A `Region` manages a caller-supplied contiguous block of memory as a
simple bump-the-pointer allocator. Individual deallocations are not
supported; instead the entire region is released at once via
$(LREF deallocateAll).

The backing storage is *not* embedded; the caller supplies a
contiguous block via $(LREF initialize).

Params:
    minAlign = minimum alignment for all returned allocations;
        must be a positive power of two

See_Also:
    $(LREF WasmAllocator), $(LREF newWasmAllocator)
*/
struct Region(uint minAlign = 8)
{
    static assert(minAlign > 0 && (minAlign & (minAlign - 1)) == 0,
            "minAlign must be a positive power of two");

    /// The alignment guarantee for all allocations.
    enum alignment = minAlign;

    private ubyte* base;
    private size_t cap;
    private size_t offset;

    /// Disable copying — the allocator is a unique handle.
    @disable this(this);

    /**
    Initialises this region to manage the buffer at `store`.

    Params:
        store = contiguous memory block to allocate from
    */
    void initialize(ubyte[] store) nothrow @nogc
    {
        base = store.ptr;
        cap = store.length;
        offset = 0;
    }

    /**
    Allocates `n` bytes with at least $(LREF alignment)-byte alignment.

    Params:
        n = number of bytes requested

    Returns:
        A slice of exactly `n` bytes, or a zero-length slice with
        `null` `.ptr` if the region cannot satisfy the request.
    */
    void[] allocate(size_t n) nothrow @nogc
    {
        if (n == 0)
            return (cast(void*) base)[0 .. 0];

        enum a = minAlign;
        size_t alignedOff = (offset + (a - 1)) & ~(cast(size_t)(a - 1));
        if (alignedOff + n > cap)
            return null;

        void[] result = (cast(void*)(base + alignedOff))[0 .. n];
        offset = alignedOff + n;
        return result;
    }

    /**
    Releases all allocations, resetting the region to empty.

    Returns: Always `true`.
    */
    bool deallocateAll() nothrow @nogc
    {
        offset = 0;
        return true;
    }

    /**
    Queries whether `b` was allocated from this region.

    Params:
        b = an arbitrary memory slice (`null` is allowed)

    Returns: `true` if `b` lies entirely within this region.
    */
    bool owns(const void[] b) const nothrow @nogc
    {
        auto p = cast(const(ubyte)*) b.ptr;
        return p >= base && (p + b.length) <= (base + cap);
    }

    /// Returns `true` if no allocations have been made.
    bool empty() const nothrow @nogc => offset == 0;

    /// Returns the number of bytes still available.
    size_t available() const nothrow @nogc => cap - offset;

    // -- High-level typed helpers, modelled after std.experimental.allocator --

    /**
    Allocates a typed array of `length` elements.

    Modelled after
    $(LINK2 https://dlang.org/phobos/std_experimental_allocator.html#.makeArray,
    `std.experimental.allocator.makeArray`), but avoids `void[]` → `T[]`
    array casts that pull in `core.lifetime` (unsupported on wasm32).

    Params:
        length = number of elements

    Returns:
        A `T[]` slice backed by this region, or `null` on failure.
    */
    T[] makeArray(T)(size_t length) nothrow @nogc
    {
        if (length == 0)
            return null;
        void[] m = allocate(length * T.sizeof);
        if (m.ptr is null)
            return null;
        return (cast(T*) m.ptr)[0 .. length];
    }

    /**
    Allocates a `ubyte[]` buffer of `n` bytes.

    Convenience shorthand for `makeArray!ubyte(n)`.

    Params:
        n = number of bytes

    Returns:
        A `ubyte[]` slice backed by this region, or `null` on failure.
    */
    ubyte[] makeOpaqueArray(size_t n) nothrow @nogc => makeArray!ubyte(n);
}

/// Default allocator type — 8-byte aligned bump region.
alias WasmAllocator = Region!8;

/**
Creates a fresh `WasmAllocator` backed by a function-local
static arena in WASM linear memory.

Each exported builtin should call this at entry to obtain a
reset allocator handle. Because the arena is shared, only one
export may be active at a time (WASM is single-threaded).

Params:
    arenaSize = size of the backing arena in bytes (default 1 MB)

Returns: An initialised `WasmAllocator` ready for use.
*/
WasmAllocator newWasmAllocator(size_t arenaSize = 1024 * 1024)() nothrow @nogc
{
    static ubyte[arenaSize] arena;
    WasmAllocator a = void;
    a.initialize(arena[]);
    return a;
}
