/// D implementation for WASM support in Determinate Nix
/// https://github.com/DeterminateSystems/nix-src/blob/main/doc/manual/source/protocols/wasm.md
module nix_wasm;

import ldc.attributes;

alias ValueId = uint;

enum Type : uint {
    Int = 1,
    Float = 2,
    Bool = 3,
    String = 4,
    Path = 5,
    Null = 6,
    Attrs = 7,
    List = 8,
    Function = 9,
}

// Host-imported functions
@llvmAttr("wasm-import-module", "env") private extern(C) {
    Type get_type(ValueId value);
    Value make_int(long value);
    long get_int(ValueId value);
    Value make_float(double value);
    double get_float(ValueId value);
    Value make_string(const(ubyte)* ptr, size_t len);
    size_t copy_string(ValueId value, ubyte* ptr, size_t max_len);
    Value make_path(ValueId base, const(ubyte)* ptr, size_t len);
    size_t copy_path(ValueId value, ubyte* ptr, size_t max_len);
    Value make_bool(int b);
    int get_bool(ValueId value);
    Value make_null();
    Value make_list(const(Value)* ptr, size_t len);
    size_t copy_list(ValueId value, Value* ptr, size_t max_len);
    Value make_attrset(const(AttrInput)* ptr, size_t len);
    size_t copy_attrset(ValueId value, AttrOutput* ptr, size_t max_len);
    void copy_attrname(ValueId value, size_t attr_idx, ubyte* ptr, size_t len);
    ValueId get_attr(ValueId value, const(ubyte)* ptr, size_t len);
    Value call_function(ValueId fun, const(Value)* ptr, size_t len);
    Value make_app(ValueId fun, const(Value)* ptr, size_t len);
    size_t read_file(ValueId value, ubyte* ptr, size_t max_len);
    void panic(const(ubyte)* ptr, size_t len);
    void warn(const(ubyte)* ptr, size_t len);
}

struct AttrEntry {
    const(char)[] name;
    Value value;
}

struct AttrInput {
    uint name_ptr;
    uint name_len;
    ValueId value_id;
}

struct AttrOutput {
    ValueId value_id;
    uint name_len;
}

struct Value {
    ValueId id;

    Type getType() {
        return get_type(id);
    }

    static Value makeInt(long n) {
        return make_int(n);
    }

    long getInt() {
        return get_int(id);
    }

    static Value makeFloat(double f) {
        return make_float(f);
    }

    double getFloat() {
        return get_float(id);
    }

    static Value makeString(const(char)[] s) {
        return make_string(cast(const(ubyte)*) s.ptr, s.length);
    }

    /// Returns a slice into the arena. Caller must not free.
    const(char)[] getString(ref WasmAllocator allocator) {
        ubyte[256] buf = void;
        size_t len = copy_string(id, buf.ptr, buf.length);

        if (len > buf.length) {
            ubyte* larger_buf = allocator.alloc(len);
            if (larger_buf is null) nixPanic("out of memory");
            size_t len2 = copy_string(id, larger_buf, len);
            if (len2 != len) nixPanic("length mismatch");
            return cast(const(char)[]) larger_buf[0 .. len];
        } else {
            ubyte* result = allocator.alloc(len);
            if (result is null) nixPanic("out of memory");
            result[0 .. len] = buf[0 .. len];
            return cast(const(char)[]) result[0 .. len];
        }
    }

    Value makePath(const(char)[] rel) {
        return make_path(id, cast(const(ubyte)*) rel.ptr, rel.length);
    }

    const(char)[] getPath(ref WasmAllocator allocator) {
        ubyte[256] buf = void;
        size_t len = copy_path(id, buf.ptr, buf.length);

        if (len > buf.length) {
            ubyte* larger_buf = allocator.alloc(len);
            if (larger_buf is null) nixPanic("out of memory");
            size_t len2 = copy_path(id, larger_buf, len);
            if (len2 != len) nixPanic("length mismatch");
            return cast(const(char)[]) larger_buf[0 .. len];
        } else {
            ubyte* result = allocator.alloc(len);
            if (result is null) nixPanic("out of memory");
            result[0 .. len] = buf[0 .. len];
            return cast(const(char)[]) result[0 .. len];
        }
    }

    static Value makeBool(bool b) {
        return make_bool(b ? 1 : 0);
    }

    bool getBool() {
        return get_bool(id) != 0;
    }

    static Value makeNull() {
        return make_null();
    }

    static Value makeList(const(Value)[] list) {
        return make_list(list.ptr, list.length);
    }

    Value[] getList(ref WasmAllocator allocator) {
        Value[64] buf = void;
        size_t len = copy_list(id, buf.ptr, buf.length);

        if (len > buf.length) {
            Value* larger_buf = cast(Value*) allocator.alloc(len * Value.sizeof);
            if (larger_buf is null) nixPanic("out of memory");
            size_t len2 = copy_list(id, larger_buf, len);
            if (len2 != len) nixPanic("length mismatch");
            return larger_buf[0 .. len];
        } else {
            Value* result = cast(Value*) allocator.alloc(len * Value.sizeof);
            if (result is null) nixPanic("out of memory");
            result[0 .. len] = buf[0 .. len];
            return result[0 .. len];
        }
    }

    static Value makeAttrset(ref WasmAllocator allocator, const(AttrEntry)[] attrs) {
        AttrInput* pairs = cast(AttrInput*) allocator.alloc(attrs.length * AttrInput.sizeof);
        if (pairs is null) nixPanic("out of memory");

        foreach (i, ref attr; attrs) {
            pairs[i] = AttrInput(
                cast(uint) cast(size_t) cast(const(void)*) attr.name.ptr,
                cast(uint) attr.name.length,
                attr.value.id,
            );
        }

        return make_attrset(pairs, attrs.length);
    }

    /// Returns parallel arrays of names and values. Caller uses arena.
    void getAttrset(ref WasmAllocator allocator, out const(char)[][] names, out Value[] values, out size_t count) {
        AttrOutput[32] buf = void;
        size_t len = copy_attrset(id, buf.ptr, buf.length);

        AttrOutput[] attrs_buf;
        if (len > buf.length) {
            AttrOutput* larger_buf = cast(AttrOutput*) allocator.alloc(len * AttrOutput.sizeof);
            if (larger_buf is null) nixPanic("out of memory");
            size_t len2 = copy_attrset(id, larger_buf, len);
            if (len2 != len) nixPanic("length mismatch");
            attrs_buf = larger_buf[0 .. len];
        } else {
            attrs_buf = buf[0 .. len];
        }

        auto name_ptrs = cast(const(char)[]*) allocator.alloc(len * (const(char)[]).sizeof);
        auto val_ptrs = cast(Value*) allocator.alloc(len * Value.sizeof);
        if (name_ptrs is null || val_ptrs is null) nixPanic("out of memory");

        foreach (i, ref entry; attrs_buf) {
            ubyte* name_buf = allocator.alloc(entry.name_len);
            if (name_buf is null) nixPanic("out of memory");
            copy_attrname(id, i, name_buf, entry.name_len);
            name_ptrs[i] = cast(const(char)[]) name_buf[0 .. entry.name_len];
            val_ptrs[i] = Value(entry.value_id);
        }

        names = name_ptrs[0 .. len];
        values = val_ptrs[0 .. len];
        count = len;
    }

    Value getAttr(const(char)[] attr_name) {
        ValueId value_id = get_attr(id, cast(const(ubyte)*) attr_name.ptr, attr_name.length);
        if (value_id == 0)
            return Value(0);
        return Value(value_id);
    }

    bool hasAttr(const(char)[] attr_name) {
        return get_attr(id, cast(const(ubyte)*) attr_name.ptr, attr_name.length) != 0;
    }

    Value call(const(Value)[] args) {
        return call_function(id, args.ptr, args.length);
    }

    Value lazyCall(const(Value)[] args) {
        return make_app(id, args.ptr, args.length);
    }

    const(char)[] readFile(ref WasmAllocator allocator) {
        ubyte[1024] buf = void;
        size_t len = read_file(id, buf.ptr, buf.length);

        if (len > buf.length) {
            ubyte* larger_buf = allocator.alloc(len);
            if (larger_buf is null) nixPanic("out of memory");
            size_t len2 = read_file(id, larger_buf, len);
            if (len2 != len) nixPanic("length mismatch");
            return cast(const(char)[]) larger_buf[0 .. len];
        } else {
            ubyte* result = allocator.alloc(len);
            if (result is null) nixPanic("out of memory");
            result[0 .. len] = buf[0 .. len];
            return cast(const(char)[]) result[0 .. len];
        }
    }
}

/// Simple bump allocator for WASM (no GC in betterC).
/// Uses a static buffer to avoid needing memory.grow intrinsics.
struct WasmAllocator {
    enum ARENA_SIZE = 1024 * 1024; // 1 MB
    private static ubyte[ARENA_SIZE] arena;
    private size_t offset;

    void init() {
        offset = 0;
    }

    ubyte* alloc(size_t len) {
        // Align to 8 bytes
        size_t aligned = (len + 7) & ~cast(size_t) 7;
        if (offset + aligned > ARENA_SIZE) {
            return null;
        }
        ubyte* result = arena.ptr + offset;
        offset += aligned;
        return result;
    }

    void reset() {
        offset = 0;
    }
}

// Provide D/C runtime functions that LDC emits calls to in -betterC WASM.

// D runtime array slice copy (5-arg version: dst, dstLen, src, srcLen, elemSize)
extern(C) void _d_array_slice_copy(void* dst, size_t dstLen, const(void)* src, size_t srcLen, size_t elemSize) {
    auto d = cast(ubyte*) dst;
    auto s = cast(const(ubyte)*) src;
    auto totalBytes = dstLen * elemSize;
    foreach (i; 0 .. totalBytes)
        d[i] = s[i];
}

// D betterC assert handler
extern(C) void __assert(const(char)* msg, const(char)* file, int line) {
    panic(cast(const(ubyte)*) "assertion failure".ptr, "assertion failure".length);
    while (true) {}
}

extern(C) int memcmp(const(void)* s1, const(void)* s2, size_t n) {
    auto a = cast(const(ubyte)*) s1;
    auto b = cast(const(ubyte)*) s2;
    foreach (i; 0 .. n) {
        if (a[i] != b[i])
            return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

extern(C) void* memcpy(void* dest, const(void)* src, size_t n) {
    auto d = cast(ubyte*) dest;
    auto s = cast(const(ubyte)*) src;
    foreach (i; 0 .. n)
        d[i] = s[i];
    return dest;
}

extern(C) void* memset(void* dest, int c, size_t n) {
    auto d = cast(ubyte*) dest;
    foreach (i; 0 .. n)
        d[i] = cast(ubyte) c;
    return dest;
}

extern(C) void* memmove(void* dest, const(void)* src, size_t n) {
    auto d = cast(ubyte*) dest;
    auto s = cast(const(ubyte)*) src;
    if (d < s) {
        foreach (i; 0 .. n)
            d[i] = s[i];
    } else {
        foreach_reverse (i; 0 .. n)
            d[i] = s[i];
    }
    return dest;
}

void nixPanic(string msg) {
    panic(cast(const(ubyte)*) msg.ptr, msg.length);
    while (true) {} // panic is noreturn but D doesn't know that
}

void nixWarn(string msg) {
    warn(cast(const(ubyte)*) msg.ptr, msg.length);
}
