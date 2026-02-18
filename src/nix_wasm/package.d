/**
D implementation for WASM support in Determinate Nix.

Provides value types, a bump allocator, and host-imported function
wrappers for building Nix builtins that compile to WebAssembly.

See_Also:
    $(LINK2 https://github.com/DeterminateSystems/nix-src/blob/main/doc/manual/source/protocols/wasm.md,
    Nix WASM protocol specification)
*/
module nix_wasm;

import ldc.attributes;

/// Opaque handle identifying a Nix value managed by the host evaluator.
alias ValueId = uint;

/**
Nix value type tags corresponding to the host evaluator's type system.

See_Also:
    $(LINK2 https://nix.dev/manual/nix/latest/language/types, Nix language data types)
*/
enum Type : uint
{
    /// [Nix Integer](https://nix.dev/manual/nix/latest/language/types#type-int) —
    /// a 64-bit signed integer.
    integer = 1,
    /// [Nix Float](https://nix.dev/manual/nix/latest/language/types#type-float) —
    /// a 64-bit IEEE 754 floating-point number.
    float_ = 2,
    /// [Nix Boolean](https://nix.dev/manual/nix/latest/language/types#type-bool) —
    /// `true` or `false`.
    boolean = 3,
    /// [Nix String](https://nix.dev/manual/nix/latest/language/types#type-string) —
    /// an immutable byte sequence with optional string context.
    string = 4,
    /// [Nix Path](https://nix.dev/manual/nix/latest/language/types#type-path) —
    /// a POSIX-style canonical file system path starting with `/`.
    path = 5,
    /// [Nix Null](https://nix.dev/manual/nix/latest/language/types#type-null) —
    /// the singleton null value.
    null_ = 6,
    /// [Nix Attribute Set](https://nix.dev/manual/nix/latest/language/types#type-attrs) —
    /// a mapping from names to values.
    attrs = 7,
    /// [Nix List](https://nix.dev/manual/nix/latest/language/types#type-list) —
    /// an ordered list of values.
    list = 8,
    /// [Nix Function](https://nix.dev/manual/nix/latest/language/types#type-function) —
    /// a lambda or partial application.
    function_ = 9,
}

// Host-imported functions
private extern (C) @llvmAttr("wasm-import-module", "env")
{
    Type get_type(ValueId value);
    Value make_int(long value);
    long get_int(ValueId value);
    Value make_float(double value);
    double get_float(ValueId value);
    Value make_string(const(char)* ptr, size_t len);
    size_t copy_string(ValueId value, char* ptr, size_t max_len);
    Value make_path(ValueId base, const(char)* ptr, size_t len);
    size_t copy_path(ValueId value, char* ptr, size_t max_len);
    Value make_bool(int b);
    int get_bool(ValueId value);
    Value make_null();
    Value make_list(const(Value)* ptr, size_t len);
    size_t copy_list(ValueId value, Value* ptr, size_t max_len);
    Value make_attrset(const(AttrInput)* ptr, size_t len);
    size_t copy_attrset(ValueId value, AttrOutput* ptr, size_t max_len);
    void copy_attrname(ValueId value, size_t attr_idx, char* ptr, size_t len);
    ValueId get_attr(ValueId value, const(char)* ptr, size_t len);
    Value call_function(ValueId fun, const(Value)* ptr, size_t len);
    Value make_app(ValueId fun, const(Value)* ptr, size_t len);
    size_t read_file(ValueId value, char* ptr, size_t max_len);
    void panic(const(char)* ptr, size_t len);
    void warn(const(char)* ptr, size_t len);
}

/// A name-value pair used to construct Nix attribute sets.
struct AttrEntry
{
    const(char)[] name;
    Value value;
}

/// Wire format for passing attribute set entries to the host.
struct AttrInput
{
    uint name_ptr;
    uint name_len;
    ValueId value_id;
}

/// Wire format for receiving attribute set entries from the host.
struct AttrOutput
{
    ValueId value_id;
    uint name_len;
}

/**
Allocates a `T[]` of `count` elements from the region, panicking on failure.

Modelled after
$(LINK2 https://dlang.org/phobos/std_experimental_allocator.html#.makeArray,
`std.experimental.allocator.makeArray`) with an OOM-panic policy.

Params:
    a     = the region to allocate from
    count = number of elements

Returns: A `T[]` slice backed by the region.
*/
T[] makeArrayOrPanic(T)(ref WasmAllocator a, size_t count)
{
    if (count == 0)
        return null;
    T[] result = a.makeArray!T(count);
    if (result.ptr is null)
        nixPanic("out of memory");
    return result;
}

/// Copies variable-length data from the host into the arena.
///
/// Uses a stack buffer for the initial probe; falls back to an
/// arena allocation when the data exceeds the stack buffer.
private const(char)[] copyToArena(alias copyFn, size_t stackSize = 256)(ValueId id,
        ref WasmAllocator a)
{
    char[stackSize] stackBuf = void;
    size_t len = copyFn(id, stackBuf.ptr, stackBuf.length);

    if (len > stackBuf.length)
    {
        char[] buf = makeArrayOrPanic!char(a, len);
        size_t len2 = copyFn(id, buf.ptr, len);
        if (len2 != len)
            nixPanic("length mismatch");
        return buf[0 .. len];
    }

    char[] result = makeArrayOrPanic!char(a, len);
    result[0 .. len] = stackBuf[0 .. len];
    return result[0 .. len];
}

/// Copies a variable-length array of `Value` from the host into the arena.
private Value[] copyValuesToArena(alias copyFn, size_t stackCount = 64)(ValueId id,
        ref WasmAllocator a)
{
    Value[stackCount] stackBuf = void;
    size_t len = copyFn(id, stackBuf.ptr, stackBuf.length);

    if (len > stackBuf.length)
    {
        Value[] buf = makeArrayOrPanic!Value(a, len);
        size_t len2 = copyFn(id, buf.ptr, len);
        if (len2 != len)
            nixPanic("length mismatch");
        return buf[0 .. len];
    }

    Value[] result = makeArrayOrPanic!Value(a, len);
    result[0 .. len] = stackBuf[0 .. len];
    return result[0 .. len];
}

/**
Wrapper around a host-managed Nix value identifier.

Provides typed accessors and constructors that delegate to
host-imported functions. Values are identified by opaque
$(LREF ValueId) handles; the host owns the underlying storage.
*/
struct Value
{
    ValueId id;

    /// Returns the Nix type tag for this value.
    Type getType() => get_type(id);

    /// Constructs a Nix integer value.
    static Value makeInt(long n) => make_int(n);

    /// Returns the integer payload of this value.
    long getInt() => get_int(id);

    /// Constructs a Nix float value.
    static Value makeFloat(double f) => make_float(f);

    /// Returns the float payload of this value.
    double getFloat() => get_float(id);

    /// Constructs a Nix string value from a D character slice.
    static Value makeString(const(char)[] s) => make_string(s.ptr, s.length);

    /// Returns the string content of this value as an arena-backed slice.
    const(char)[] getString(ref WasmAllocator a) => copyToArena!copy_string(id, a);

    /// Constructs a Nix path value relative to this base path.
    Value makePath(const(char)[] rel) => make_path(id, rel.ptr, rel.length);

    /// Returns the path string of this value as an arena-backed slice.
    const(char)[] getPath(ref WasmAllocator a) => copyToArena!copy_path(id, a);

    /// Constructs a Nix boolean value.
    static Value makeBool(bool b) => make_bool(b ? 1 : 0);

    /// Returns the boolean payload of this value.
    bool getBool() => get_bool(id) != 0;

    /// Constructs a Nix null value.
    static Value makeNull() => make_null();

    /// Constructs a Nix list from a slice of values.
    static Value makeList(const(Value)[] items) => make_list(items.ptr, items.length);

    /// Returns the list elements as an arena-backed slice.
    Value[] getList(ref WasmAllocator a) => copyValuesToArena!copy_list(id, a);

    /// Constructs a Nix attribute set from name-value pairs.
    static Value makeAttrset(ref WasmAllocator allocator, const(AttrEntry)[] attrs)
    {
        AttrInput[] pairs = makeArrayOrPanic!AttrInput(allocator, attrs.length);

        foreach (i, ref attr; attrs)
        {
            pairs[i] = AttrInput(cast(uint) cast(size_t) cast(const(void)*) attr.name.ptr,
                    cast(uint) attr.name.length, attr.value.id,);
        }

        return make_attrset(pairs.ptr, attrs.length);
    }

    /// Returns parallel arrays of attribute names and values.
    void getAttrset(ref WasmAllocator allocator, out const(char)[][] names,
            out Value[] values, out size_t count)
    {
        AttrOutput[32] stackBuf = void;
        size_t len = copy_attrset(id, stackBuf.ptr, stackBuf.length);

        AttrOutput[] attrsBuf;
        if (len > stackBuf.length)
        {
            attrsBuf = makeArrayOrPanic!AttrOutput(allocator, len);
            size_t len2 = copy_attrset(id, attrsBuf.ptr, len);
            if (len2 != len)
                nixPanic("length mismatch");
        }
        else
        {
            attrsBuf = stackBuf[0 .. len];
        }

        const(char)[][] nameSlices = makeArrayOrPanic!(const(char)[])(allocator, len);
        Value[] valSlices = makeArrayOrPanic!Value(allocator, len);

        foreach (i, ref entry; attrsBuf)
        {
            char[] nameBuf = makeArrayOrPanic!char(allocator, entry.name_len);
            copy_attrname(id, i, nameBuf.ptr, entry.name_len);
            nameSlices[i] = nameBuf;
            valSlices[i] = Value(entry.value_id);
        }

        names = nameSlices;
        values = valSlices;
        count = len;
    }

    /// Looks up an attribute by name, returning a zero-id value if not found.
    Value getAttr(const(char)[] attrName)
    {
        ValueId vid = get_attr(id, attrName.ptr, attrName.length);
        if (vid == 0)
            return Value(0);
        return Value(vid);
    }

    /// Returns whether this attribute set contains the given key.
    bool hasAttr(const(char)[] attrName) => get_attr(id,
            attrName.ptr, attrName.length) != 0;

    /// Eagerly calls this value as a function with the given arguments.
    Value call(const(Value)[] args) => call_function(id, args.ptr, args.length);

    /// Lazily applies this function to the given arguments.
    Value lazyCall(const(Value)[] args) => make_app(id, args.ptr, args.length);

    /// Reads the file at this path value, returning an arena-backed slice.
    const(char)[] readFile(ref WasmAllocator a) => copyToArena!(read_file, 1024)(id, a);
}

/**
Bump-pointer region allocator for WASM, modelled after
$(LINK2 https://dlang.org/phobos/std_experimental_allocator_building_blocks_region.html,
`std.experimental.allocator.building_blocks.region.InSituRegion`).

A `Region` manages a caller-supplied contiguous block of memory as a
simple bump-the-pointer allocator. Individual deallocations are not
supported; instead the entire region is released at once via
$(LREF deallocateAll).

Unlike the previous `WasmAllocator`, the backing storage is *not*
embedded as a `static` member. A module-level `__gshared` arena
($(LREF wasmArena)) lives in WASM linear memory, and each `Region`
is a lightweight handle into that arena.

Params:
    minAlign = minimum alignment for all returned allocations;
        must be a positive power of two

See_Also:
    $(LREF wasmArena), $(LREF WasmAllocator)
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

/// Module-level arena in WASM linear memory (1 MB).
private __gshared ubyte[1024 * 1024] wasmArena;

/**
Creates a fresh `WasmAllocator` backed by the global $(LREF wasmArena).

Each exported builtin should call this at entry to obtain a
reset allocator handle. Because the arena is shared, only one
export may be active at a time (WASM is single-threaded).

Returns: An initialised `WasmAllocator` ready for use.
*/
WasmAllocator newWasmAllocator() nothrow @nogc
{
    WasmAllocator a = void;
    a.initialize(wasmArena[]);
    return a;
}

// Provide D/C runtime functions that LDC emits calls to in -betterC WASM.

// D runtime array slice copy (5-arg version: dst, dstLen, src, srcLen, elemSize)
extern (C) void _d_array_slice_copy(void* dst, size_t dstLen, const(void)* src,
        size_t srcLen, size_t elemSize)
{
    auto d = cast(ubyte*) dst;
    auto s = cast(const(ubyte)*) src;
    auto totalBytes = dstLen * elemSize;
    foreach (i; 0 .. totalBytes)
        d[i] = s[i];
}

// D betterC assert handler
extern (C) void __assert(const(char)* msg, const(char)* file, int line)
{
    panic("assertion failure".ptr, "assertion failure".length);
    while (true)
    {
    }
}

extern (C) int memcmp(const(void)* s1, const(void)* s2, size_t n)
{
    auto a = cast(const(ubyte)*) s1;
    auto b = cast(const(ubyte)*) s2;
    foreach (i; 0 .. n)
    {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

extern (C) void* memcpy(void* dest, const(void)* src, size_t n)
{
    auto d = cast(ubyte*) dest;
    auto s = cast(const(ubyte)*) src;
    foreach (i; 0 .. n)
        d[i] = s[i];
    return dest;
}

extern (C) void* memset(void* dest, int c, size_t n)
{
    auto d = cast(ubyte*) dest;
    foreach (i; 0 .. n)
        d[i] = cast(ubyte) c;
    return dest;
}

extern (C) void* memmove(void* dest, const(void)* src, size_t n)
{
    auto d = cast(ubyte*) dest;
    auto s = cast(const(ubyte)*) src;
    if (d < s)
    {
        foreach (i; 0 .. n)
            d[i] = s[i];
    }
    else
    {
        foreach_reverse (i; 0 .. n)
            d[i] = s[i];
    }
    return dest;
}

/// Aborts execution with a message sent to the Nix host.
void nixPanic(string msg)
{
    panic(msg.ptr, msg.length);
    while (true)
    {
    } // panic is noreturn but D doesn't know that
}

/// Sends a warning message to the Nix host.
void nixWarn(string msg)
{
    warn(msg.ptr, msg.length);
}
