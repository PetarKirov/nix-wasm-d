/**
JSON serialization and deserialization builtins for Nix WASM.

Implements `fromJSON` and `toJSON` as WASM-exported functions
for the Nix evaluator.
*/
module nix_wasm.builtins.json;

import nix_wasm;

// Export the init function
export extern (C) void nix_wasm_init_v1()
{
    nixWarn("hello from nix-wasm-d");
    nixWarn("json wasm module");
}

/// Recursively converts a JSON value at the current position to a Nix value.
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

/// Advances past JSON whitespace characters.
private void skipWhitespace(const(char)[] json, ref size_t pos)
{
    while (pos < json.length && (json[pos] == ' ' || json[pos] == '\t'
            || json[pos] == '\n' || json[pos] == '\r'))
    {
        pos++;
    }
}

/// Parses a JSON string literal, handling escape sequences.
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
    char[] buf = makeArrayOrPanic!char(allocator, maxLen);
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
            buf[outPos++] = json[pos];
            pos++;
        }
    }
    pos++; // skip closing quote
    return Value.makeString(buf[0 .. outPos]);
}

/// Parses a JSON number, returning either an int or float Nix value.
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

/// Parses a decimal integer from a character slice.
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

/// Parses a decimal floating-point number from a character slice.
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

/// Parses a JSON array into a Nix list.
private Value parseJsonArray(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    pos++; // skip '['
    skipWhitespace(json, pos);

    // Collect items into arena
    enum MAX_ITEMS = 4096;
    Value[] items = makeArrayOrPanic!Value(allocator, MAX_ITEMS);
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

/// Parses a JSON object into a Nix attribute set.
private Value parseJsonObject(ref WasmAllocator allocator, const(char)[] json, ref size_t pos)
{
    pos++; // skip '{'
    skipWhitespace(json, pos);

    enum MAX_ATTRS = 4096;
    AttrEntry[] entries = makeArrayOrPanic!AttrEntry(allocator, MAX_ATTRS);
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

/// Recursively serializes a Nix value to JSON.
private void nixToJson(ref WasmAllocator allocator, ref JsonWriter writer, Value value)
{
    final switch (value.getType())
    {
    case Type.null_:
        writer.writeRaw("null");
        break;
    case Type.boolean:
        writer.writeRaw(value.getBool() ? "true" : "false");
        break;
    case Type.integer:
        writeLong(writer, value.getInt());
        break;
    case Type.float_:
        writeDouble(writer, value.getFloat());
        break;
    case Type.string:
        const(char)[] s = value.getString(allocator);
        writeJsonString(writer, s);
        break;
    case Type.path:
        const(char)[] p = value.getPath(allocator);
        writeJsonString(writer, p);
        break;
    case Type.list:
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
    case Type.attrs:
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
    case Type.function_:
        nixPanic("cannot convert a function to JSON");
    }
}

/// Growable char buffer for building JSON output in the WASM arena.
private struct JsonWriter
{
    char* buf;
    size_t len;
    size_t capacity;
    WasmAllocator* allocator;

    void init(ref WasmAllocator alloc)
    {
        allocator = &alloc;
        capacity = 4096;
        auto initial = makeArrayOrPanic!char(*allocator, capacity);
        buf = initial.ptr;
        len = 0;
    }

    void writeRaw(const(char)[] s)
    {
        foreach (c; s)
        {
            writeChar(c);
        }
    }

    void writeChar(char c)
    {
        if (len >= capacity)
        {
            // Grow - allocate new buffer in arena
            size_t newCap = capacity * 2;
            auto grown = makeArrayOrPanic!char(*allocator, newCap);
            grown[0 .. len] = buf[0 .. len];
            buf = grown.ptr;
            capacity = newCap;
        }
        buf[len++] = c;
    }

    const(char)[] result() => buf[0 .. len];
}

/// Writes a JSON-escaped string with surrounding quotes.
private void writeJsonString(ref JsonWriter w, const(char)[] s)
{
    w.writeChar('"');
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
                w.writeChar(hexDigit((cast(ubyte) c >> 4) & 0xF));
                w.writeChar(hexDigit(cast(ubyte) c & 0xF));
            }
            else
            {
                w.writeChar(c);
            }
            break;
        }
    }
    w.writeChar('"');
}

/// Converts a nibble (0-15) to its lowercase hex ASCII character.
private char hexDigit(ubyte n) => cast(char)(n < 10 ? '0' + n : 'a' + n - 10);

/// Writes a decimal representation of a long integer.
private void writeLong(ref JsonWriter w, long n)
{
    if (n < 0)
    {
        w.writeChar('-');
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
        w.writeChar('0');
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
        w.writeChar(digits[i]);
    }
}

/// Writes a decimal representation of a double.
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
        w.writeChar('-');
        val = -val;
    }

    // Integer part
    long intPart = cast(long) val;
    double fracPart = val - cast(double) intPart;

    writeLong(w, intPart);

    // Always write fractional part for floats
    w.writeChar('.');
    // Write 6 decimal places
    foreach (_; 0 .. 6)
    {
        fracPart *= 10.0;
        int digit = cast(int) fracPart;
        w.writeChar(cast(char)('0' + digit));
        fracPart -= cast(double) digit;
    }
}

/**
Parses a JSON string into a Nix value.

Params:
    arg = a Nix string containing valid JSON

Returns: The corresponding Nix value.
*/
export extern (C) Value fromJSON(Value arg)
{
    WasmAllocator allocator = newWasmAllocator();

    const(char)[] jsonStr = arg.getString(allocator);
    size_t pos = 0;
    Value result;
    jsonToNix(allocator, jsonStr, pos, result);
    return result;
}

/**
Serializes a Nix value to a JSON string.

Params:
    arg = any Nix value except functions

Returns: A Nix string containing the JSON representation.
*/
export extern (C) Value toJSON(Value arg)
{
    WasmAllocator allocator = newWasmAllocator();

    JsonWriter writer;
    writer.init(allocator);

    nixToJson(allocator, writer, arg);

    return Value.makeString(writer.result());
}
