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
import ldc.intrinsics;

public import nix_wasm.memory;

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

/// Queries the host for the data length, allocates in the arena, and
/// copies in a single pass.  Works for any host copy function that
/// returns the actual length when called with `(id, null, 0)`.
private const(char)[] copyFromHost(alias copyFn)(ValueId id, ref WasmAllocator arena)
{
    size_t len = copyFn(id, null, 0);
    if (len == 0)
        return null;
    char[] buf = makeArrayOrPanic!char(arena, len);
    size_t len2 = copyFn(id, buf.ptr, len);
    if (len2 != len)
        nixPanic("length mismatch");
    return buf[0 .. len];
}

/// Queries the host for the element count, allocates in the arena, and
/// copies in a single pass.
private Value[] copyValuesFromHost(alias copyFn)(ValueId id, ref WasmAllocator arena)
{
    size_t len = copyFn(id, null, 0);
    if (len == 0)
        return null;
    Value[] buf = makeArrayOrPanic!Value(arena, len);
    size_t len2 = copyFn(id, buf.ptr, len);
    if (len2 != len)
        nixPanic("length mismatch");
    return buf[0 .. len];
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
    const(char)[] getString(ref WasmAllocator a) => copyFromHost!copy_string(id, a);

    /// Constructs a Nix path value relative to this base path.
    Value makePath(const(char)[] rel) => make_path(id, rel.ptr, rel.length);

    /// Returns the path string of this value as an arena-backed slice.
    const(char)[] getPath(ref WasmAllocator a) => copyFromHost!copy_path(id, a);

    /// Constructs a Nix boolean value.
    static Value makeBool(bool b) => make_bool(b ? 1 : 0);

    /// Returns the boolean payload of this value.
    bool getBool() => get_bool(id) != 0;

    /// Constructs a Nix null value.
    static Value makeNull() => make_null();

    /// Constructs a Nix list from a slice of values.
    static Value makeList(const(Value)[] items) => make_list(items.ptr, items.length);

    /// Returns the list elements as an arena-backed slice.
    Value[] getList(ref WasmAllocator a) => copyValuesFromHost!copy_list(id, a);

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
    const(char)[] readFile(ref WasmAllocator a) => copyFromHost!read_file(id, a);
}

// Provide D/C runtime functions that LDC emits calls to in -betterC WASM.
//
// With -mattr=+bulk-memory, LLVM lowers the intrinsic calls below to
// native WASM `memory.copy` and `memory.fill` instructions.

// D runtime array slice copy (5-arg version: dst, dstLen, src, srcLen, elemSize)
extern (C) void _d_array_slice_copy(void* dst, size_t dstLen, const(void)* src,
        size_t srcLen, size_t elemSize)
{
    llvm_memcpy!size_t(dst, src, dstLen * elemSize, false);
}

// D betterC assert handler
extern (C) noreturn __assert(const(char)* msg, const(char)* file, int line)
{
    panic("assertion failure".ptr, "assertion failure".length);
    assert(0);
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
    llvm_memcpy!size_t(dest, src, n, false);
    return dest;
}

extern (C) void* memset(void* dest, int c, size_t n)
{
    llvm_memset!size_t(dest, cast(ubyte) c, n, false);
    return dest;
}

extern (C) void* memmove(void* dest, const(void)* src, size_t n)
{
    llvm_memmove!size_t(dest, src, n, false);
    return dest;
}

/// Aborts execution with a message sent to the Nix host.
noreturn nixPanic(string msg)
{
    panic(msg.ptr, msg.length);
    assert(0);
}

/// Sends a warning message to the Nix host.
void nixWarn(string msg)
{
    warn(msg.ptr, msg.length);
}
