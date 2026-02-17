/// JSON builtins for Nix WASM
module nix_wasm.builtins.json;

import nix_wasm;

// Export the init function
export extern (C) void nix_wasm_init_v1()
{
    nixWarn("hello from nix-wasm-d");
    nixWarn("json wasm module");
}

private void jsonToNix(ref WasmAllocator allocator, const(char)[] json,
        ref size_t pos, out Value result)
{
    skipWhitespace(json, pos);
    if (pos >= json.length)
        nixPanic("fromJSON: unexpected end of input");

    char c = json[pos];

    if (c == '"')
    {
        result = parseJsonString(allocator, json, pos);
    }
    else if (c == '{')
    {
        result = parseJsonObject(allocator, json, pos);
    }
    else if (c == '[')
    {
        result = parseJsonArray(allocator, json, pos);
    }
    else if (c == 't')
    {
        if (pos + 4 <= json.length && json[pos .. pos + 4] == "true")
        {
            pos += 4;
            result = Value.makeBool(true);
        }
        else
        {
            nixPanic("fromJSON: invalid token");
        }
    }
    else if (c == 'f')
    {
        if (pos + 5 <= json.length && json[pos .. pos + 5] == "false")
        {
            pos += 5;
            result = Value.makeBool(false);
        }
        else
        {
            nixPanic("fromJSON: invalid token");
        }
    }
    else if (c == 'n')
    {
        if (pos + 4 <= json.length && json[pos .. pos + 4] == "null")
        {
            pos += 4;
            result = Value.makeNull();
        }
        else
        {
            nixPanic("fromJSON: invalid token");
        }
    }
    else if (c == '-' || (c >= '0' && c <= '9'))
    {
        result = parseJsonNumber(allocator, json, pos);
    }
    else
    {
        nixPanic("fromJSON: unexpected character");
    }
}

private void skipWhitespace(const(char)[] json, ref size_t pos)
{
    while (pos < json.length && (json[pos] == ' ' || json[pos] == '\t'
            || json[pos] == '\n' || json[pos] == '\r'))
    {
        pos++;
    }
}

private Value parseJsonString(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    pos++; // skip opening quote
    size_t start = pos;

    // First check if we need to handle escapes
    bool hasEscapes = false;
    size_t scanPos = pos;
    while (scanPos < json.length && json[scanPos] != '"')
    {
        if (json[scanPos] == '\\')
        {
            hasEscapes = true;
            scanPos += 2;
        }
        else
        {
            scanPos++;
        }
    }

    if (!hasEscapes)
    {
        const(char)[] s = json[start .. scanPos];
        pos = scanPos + 1; // skip closing quote
        return Value.makeString(s);
    }

    // Handle escapes - build into arena
    size_t maxLen = scanPos - start;
    ubyte* buf = allocator.alloc(maxLen);
    if (buf is null)
        nixPanic("out of memory");
    size_t outPos = 0;

    while (pos < json.length && json[pos] != '"')
    {
        if (json[pos] == '\\')
        {
            pos++;
            if (pos >= json.length)
                nixPanic("fromJSON: unterminated string escape");
            switch (json[pos])
            {
            case '"':
                buf[outPos++] = '"';
                break;
            case '\\':
                buf[outPos++] = '\\';
                break;
            case '/':
                buf[outPos++] = '/';
                break;
            case 'b':
                buf[outPos++] = '\b';
                break;
            case 'f':
                buf[outPos++] = '\f';
                break;
            case 'n':
                buf[outPos++] = '\n';
                break;
            case 'r':
                buf[outPos++] = '\r';
                break;
            case 't':
                buf[outPos++] = '\t';
                break;
            default:
                buf[outPos++] = json[pos];
                break;
            }
            pos++;
        }
        else
        {
            buf[outPos++] = cast(ubyte) json[pos];
            pos++;
        }
    }
    pos++; // skip closing quote
    return Value.makeString(cast(const(char)[]) buf[0 .. outPos]);
}

private Value parseJsonNumber(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    size_t start = pos;
    bool isFloat = false;

    if (pos < json.length && json[pos] == '-')
        pos++;

    while (pos < json.length && json[pos] >= '0' && json[pos] <= '9')
        pos++;

    if (pos < json.length && json[pos] == '.')
    {
        isFloat = true;
        pos++;
        while (pos < json.length && json[pos] >= '0' && json[pos] <= '9')
            pos++;
    }

    if (pos < json.length && (json[pos] == 'e' || json[pos] == 'E'))
    {
        isFloat = true;
        pos++;
        if (pos < json.length && (json[pos] == '+' || json[pos] == '-'))
            pos++;
        while (pos < json.length && json[pos] >= '0' && json[pos] <= '9')
            pos++;
    }

    const(char)[] numStr = json[start .. pos];

    if (isFloat)
    {
        return Value.makeFloat(parseDouble(numStr));
    }
    else
    {
        return Value.makeInt(parseLong(numStr));
    }
}

private long parseLong(const(char)[] s)
{
    if (s.length == 0)
        return 0;
    bool negative = false;
    size_t i = 0;
    if (s[0] == '-')
    {
        negative = true;
        i = 1;
    }
    long result = 0;
    while (i < s.length)
    {
        if (s[i] < '0' || s[i] > '9')
            break;
        result = result * 10 + (s[i] - '0');
        i++;
    }
    return negative ? -result : result;
}

private double parseDouble(const(char)[] s)
{
    // Simple double parser
    if (s.length == 0)
        return 0.0;
    bool negative = false;
    size_t i = 0;
    if (s[0] == '-')
    {
        negative = true;
        i = 1;
    }

    double intPart = 0.0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        intPart = intPart * 10.0 + cast(double)(s[i] - '0');
        i++;
    }

    double fracPart = 0.0;
    if (i < s.length && s[i] == '.')
    {
        i++;
        double divisor = 10.0;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            fracPart += cast(double)(s[i] - '0') / divisor;
            divisor *= 10.0;
            i++;
        }
    }

    double result = intPart + fracPart;

    if (i < s.length && (s[i] == 'e' || s[i] == 'E'))
    {
        i++;
        bool expNeg = false;
        if (i < s.length && s[i] == '-')
        {
            expNeg = true;
            i++;
        }
        else if (i < s.length && s[i] == '+')
        {
            i++;
        }
        int exp = 0;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            exp = exp * 10 + (s[i] - '0');
            i++;
        }
        double multiplier = 1.0;
        foreach (_; 0 .. exp)
            multiplier *= 10.0;
        if (expNeg)
            result /= multiplier;
        else
            result *= multiplier;
    }

    return negative ? -result : result;
}

private Value parseJsonArray(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    pos++; // skip '['
    skipWhitespace(json, pos);

    // Collect items into arena
    enum MAX_ITEMS = 4096;
    Value* items = cast(Value*) allocator.alloc(MAX_ITEMS * Value.sizeof);
    if (items is null)
        nixPanic("out of memory");
    size_t count = 0;

    if (pos < json.length && json[pos] == ']')
    {
        pos++;
        return Value.makeList((cast(Value*) null)[0 .. 0]);
    }

    while (pos < json.length)
    {
        if (count >= MAX_ITEMS)
            nixPanic("fromJSON: array too large");
        Value val;
        jsonToNix(allocator, json, pos, val);
        items[count++] = val;

        skipWhitespace(json, pos);
        if (pos < json.length && json[pos] == ',')
        {
            pos++;
            skipWhitespace(json, pos);
        }
        else
        {
            break;
        }
    }

    if (pos >= json.length || json[pos] != ']')
        nixPanic("fromJSON: expected ']'");
    pos++;

    return Value.makeList(items[0 .. count]);
}

private Value parseJsonObject(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    pos++; // skip '{'
    skipWhitespace(json, pos);

    enum MAX_ATTRS = 4096;
    AttrEntry* entries = cast(AttrEntry*) allocator.alloc(MAX_ATTRS * AttrEntry.sizeof);
    if (entries is null)
        nixPanic("out of memory");
    size_t count = 0;

    if (pos < json.length && json[pos] == '}')
    {
        pos++;
        return Value.makeAttrset(allocator, (cast(AttrEntry*) null)[0 .. 0]);
    }

    while (pos < json.length)
    {
        if (count >= MAX_ATTRS)
            nixPanic("fromJSON: object too large");

        skipWhitespace(json, pos);
        if (pos >= json.length || json[pos] != '"')
            nixPanic("fromJSON: expected string key");

        // Parse key as a string - get the raw chars
        pos++; // skip opening quote
        size_t keyStart = pos;
        while (pos < json.length && json[pos] != '"')
        {
            if (json[pos] == '\\')
                pos += 2;
            else
                pos++;
        }
        const(char)[] key = json[keyStart .. pos];
        pos++; // skip closing quote

        skipWhitespace(json, pos);
        if (pos >= json.length || json[pos] != ':')
            nixPanic("fromJSON: expected ':'");
        pos++;

        Value val;
        jsonToNix(allocator, json, pos, val);

        entries[count++] = AttrEntry(key, val);

        skipWhitespace(json, pos);
        if (pos < json.length && json[pos] == ',')
        {
            pos++;
        }
        else
        {
            break;
        }
    }

    if (pos >= json.length || json[pos] != '}')
        nixPanic("fromJSON: expected '}'");
    pos++;

    return Value.makeAttrset(allocator, entries[0 .. count]);
}

private void nixToJson(ref WasmAllocator allocator, ref JsonWriter writer, Value value)
{
    final switch (value.getType())
    {
    case Type.Null:
        writer.writeRaw("null");
        break;
    case Type.Bool:
        writer.writeRaw(value.getBool() ? "true" : "false");
        break;
    case Type.Int:
        writeLong(writer, value.getInt());
        break;
    case Type.Float:
        writeDouble(writer, value.getFloat());
        break;
    case Type.String:
        const(char)[] s = value.getString(allocator);
        writeJsonString(writer, s);
        break;
    case Type.Path:
        const(char)[] p = value.getPath(allocator);
        writeJsonString(writer, p);
        break;
    case Type.List:
        Value[] items = value.getList(allocator);
        writer.writeRaw("[");
        foreach (i, item; items)
        {
            if (i > 0)
                writer.writeRaw(",");
            nixToJson(allocator, writer, item);
        }
        writer.writeRaw("]");
        break;
    case Type.Attrs:
        const(char)[][] names;
        Value[] values;
        size_t count;
        value.getAttrset(allocator, names, values, count);
        writer.writeRaw("{");
        foreach (i; 0 .. count)
        {
            if (i > 0)
                writer.writeRaw(",");
            writeJsonString(writer, names[i]);
            writer.writeRaw(":");
            nixToJson(allocator, writer, values[i]);
        }
        writer.writeRaw("}");
        break;
    case Type.Function:
        nixPanic("cannot convert a function to JSON");
    }
}

private struct JsonWriter
{
    ubyte* buf;
    size_t len;
    size_t capacity;
    WasmAllocator* allocator;

    void init(ref WasmAllocator alloc)
    {
        allocator = &alloc;
        capacity = 4096;
        buf = alloc.alloc(capacity);
        if (buf is null)
            nixPanic("out of memory");
        len = 0;
    }

    void writeRaw(const(char)[] s)
    {
        foreach (c; s)
        {
            writeByte(cast(ubyte) c);
        }
    }

    void writeByte(ubyte b)
    {
        if (len >= capacity)
        {
            // Grow - allocate new buffer in arena
            size_t newCap = capacity * 2;
            ubyte* newBuf = allocator.alloc(newCap);
            if (newBuf is null)
                nixPanic("out of memory");
            newBuf[0 .. len] = buf[0 .. len];
            buf = newBuf;
            capacity = newCap;
        }
        buf[len++] = b;
    }

    const(char)[] result()
    {
        return cast(const(char)[]) buf[0 .. len];
    }
}

private void writeJsonString(ref JsonWriter w, const(char)[] s)
{
    w.writeByte('"');
    foreach (c; s)
    {
        switch (c)
        {
        case '"':
            w.writeRaw("\\\"");
            break;
        case '\\':
            w.writeRaw("\\\\");
            break;
        case '\b':
            w.writeRaw("\\b");
            break;
        case '\f':
            w.writeRaw("\\f");
            break;
        case '\n':
            w.writeRaw("\\n");
            break;
        case '\r':
            w.writeRaw("\\r");
            break;
        case '\t':
            w.writeRaw("\\t");
            break;
        default:
            if (cast(ubyte) c < 0x20)
            {
                w.writeRaw("\\u00");
                w.writeByte(hexDigit((cast(ubyte) c >> 4) & 0xF));
                w.writeByte(hexDigit(cast(ubyte) c & 0xF));
            }
            else
            {
                w.writeByte(cast(ubyte) c);
            }
            break;
        }
    }
    w.writeByte('"');
}

private ubyte hexDigit(ubyte n)
{
    return cast(ubyte)(n < 10 ? '0' + n : 'a' + n - 10);
}

private void writeLong(ref JsonWriter w, long n)
{
    if (n < 0)
    {
        w.writeByte('-');
        // Handle min value
        if (n == long.min)
        {
            w.writeRaw("9223372036854775808");
            return;
        }
        n = -n;
    }
    if (n == 0)
    {
        w.writeByte('0');
        return;
    }
    char[20] digits = void;
    int count = 0;
    while (n > 0)
    {
        digits[count++] = cast(char)('0' + cast(int)(n % 10));
        n /= 10;
    }
    // Reverse
    foreach_reverse (i; 0 .. count)
    {
        w.writeByte(cast(ubyte) digits[i]);
    }
}

private void writeDouble(ref JsonWriter w, double val)
{
    // Handle special cases
    if (val != val)
    {
        w.writeRaw("null");
        return;
    } // NaN
    if (val == double.infinity)
    {
        w.writeRaw("1e308");
        return;
    }
    if (val == -double.infinity)
    {
        w.writeRaw("-1e308");
        return;
    }

    if (val < 0)
    {
        w.writeByte('-');
        val = -val;
    }

    // Integer part
    long intPart = cast(long) val;
    double fracPart = val - cast(double) intPart;

    writeLong(w, intPart);

    // Always write fractional part for floats
    w.writeByte('.');
    // Write 6 decimal places
    foreach (_; 0 .. 6)
    {
        fracPart *= 10.0;
        int digit = cast(int) fracPart;
        w.writeByte(cast(ubyte)('0' + digit));
        fracPart -= cast(double) digit;
    }
}

/// fromJSON ''{"x": [1, 2, 3], "y": null}''
/// => { x = [ 1 2 3 ]; y = null; }
export extern (C) Value fromJSON(Value arg)
{
    WasmAllocator allocator;
    allocator.init();

    const(char)[] json_str = arg.getString(allocator);
    size_t pos = 0;
    Value result;
    jsonToNix(allocator, json_str, pos, result);
    return result;
}

/// toJSON { x = [ 1 2 3 ]; y = null; }
/// => {"x": [1, 2, 3], "y": null}
export extern (C) Value toJSON(Value arg)
{
    WasmAllocator allocator;
    allocator.init();

    JsonWriter writer;
    writer.init(allocator);

    nixToJson(allocator, writer, arg);

    return Value.makeString(writer.result());
}
