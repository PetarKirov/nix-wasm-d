/**
String manipulation builtins for Nix WASM.

Implements string concatenation, joining, replacement, and
replication as WASM-exported functions for the Nix evaluator.
*/
module nix_wasm.builtins.strings;

import nix_wasm;

// Export the init function
export extern (C) void nix_wasm_init_v1()
{
    nixWarn("hello from nix-wasm-d");
    nixWarn("strings wasm module");
}

/// Validates that every element in the list is a Nix string.
private void validateStringList(Value[] items)
{
    foreach (ref item; items)
    {
        if (item.getType() != Type.string)
        {
            nixPanic("Expected a list of strings");
        }
    }
}

/// Concatenates string values with an optional separator and trailing flag.
private Value concatWithSeparator(ref WasmAllocator allocator, const(char)[] sep,
        Value[] strings, bool trailing)
{
    // Get all string values
    size_t totalLen = 0;
    const(char)[][] strSlices = makeArrayOrPanic!(const(char)[])(allocator, strings.length);

    foreach (i, ref s; strings)
    {
        strSlices[i] = s.getString(allocator);
        totalLen += strSlices[i].length;
    }

    if (strings.length > 1)
    {
        totalLen += sep.length * (strings.length - 1);
    }

    if (trailing)
    {
        totalLen += sep.length;
    }

    ubyte[] result = makeArrayOrPanic!ubyte(allocator, totalLen);

    size_t pos = 0;
    foreach (i; 0 .. strings.length)
    {
        if (i > 0)
        {
            result[pos .. pos + sep.length] = cast(const(ubyte)[]) sep;
            pos += sep.length;
        }
        const(char)[] s = strSlices[i];
        result[pos .. pos + s.length] = cast(const(ubyte)[]) s;
        pos += s.length;
    }

    if (trailing)
    {
        result[pos .. pos + sep.length] = cast(const(ubyte)[]) sep;
    }

    return Value.makeString(cast(const(char)[]) result);
}

/// Performs substring replacement on the input string.
private Value replaceStringsImpl(ref WasmAllocator allocator, const(char)[] input,
        Value[] from, Value[] to)
{
    if (from.length == 0 && to.length == 0)
    {
        return Value.makeString(input);
    }

    if (from.length != to.length)
    {
        nixPanic("from and to lists must have the same length");
    }

    validateStringList(from);
    validateStringList(to);

    // Get from strings
    const(char)[][] fromStrs = makeArrayOrPanic!(const(char)[])(allocator, from.length);
    foreach (i, ref v; from)
    {
        fromStrs[i] = v.getString(allocator);
    }

    // Get to strings
    const(char)[][] toStrs = makeArrayOrPanic!(const(char)[])(allocator, to.length);
    foreach (i, ref v; to)
    {
        toStrs[i] = v.getString(allocator);
    }

    // Build result using a dynamic buffer in the arena
    size_t resultCap = input.length * 2;
    if (resultCap < 256)
        resultCap = 256;
    ubyte[] resultBuf = makeArrayOrPanic!ubyte(allocator, resultCap);
    size_t resultLen = 0;

    void appendSlice(const(char)[] s)
    {
        if (resultLen + s.length > resultCap)
        {
            // Grow
            size_t newCap = resultCap * 2;
            while (newCap < resultLen + s.length)
                newCap *= 2;
            ubyte[] newBuf = makeArrayOrPanic!ubyte(allocator, newCap);
            newBuf[0 .. resultLen] = resultBuf[0 .. resultLen];
            resultBuf = newBuf;
            resultCap = newCap;
        }
        resultBuf[resultLen .. resultLen + s.length] = cast(const(ubyte)[]) s;
        resultLen += s.length;
    }

    size_t pos = 0;
    size_t unmatchedStart = 0;

    while (pos <= input.length)
    {
        bool matched = false;

        foreach (idx; 0 .. from.length)
        {
            const(char)[] f = fromStrs[idx];
            const(char)[] t = toStrs[idx];

            if (f.length > 0 && pos + f.length <= input.length && input[pos .. pos + f.length] == f)
            {
                if (unmatchedStart < pos)
                {
                    appendSlice(input[unmatchedStart .. pos]);
                }
                appendSlice(t);
                pos += f.length;
                unmatchedStart = pos;
                matched = true;
                break;
            }
            else if (f.length == 0)
            {
                if (unmatchedStart < pos)
                {
                    appendSlice(input[unmatchedStart .. pos]);
                }
                appendSlice(t);
                if (pos < input.length)
                {
                    appendSlice(input[pos .. pos + 1]);
                }
                pos++;
                unmatchedStart = pos;
                matched = true;
                break;
            }
        }

        if (!matched)
        {
            if (pos < input.length)
            {
                pos++;
            }
            else
            {
                break;
            }
        }
    }

    if (unmatchedStart < pos)
    {
        appendSlice(input[unmatchedStart .. pos]);
    }

    return Value.makeString(cast(const(char)[]) resultBuf[0 .. resultLen]);
}

/**
Concatenates a list of strings with a separator.

Params:
    args = an attrset with `sep` (string) and `list` (list of strings)

Returns: A single Nix string with elements joined by the separator.
*/
export extern (C) Value concatStringsSep(Value args)
{
    WasmAllocator allocator = newWasmAllocator();

    Value sepVal = args.getAttr("sep");
    if (sepVal.id == 0)
        nixPanic("missing 'sep' argument");
    const(char)[] sep = sepVal.getString(allocator);

    Value listVal = args.getAttr("list");
    if (listVal.id == 0)
        nixPanic("missing 'list' argument");
    Value[] list = listVal.getList(allocator);

    validateStringList(list);
    return concatWithSeparator(allocator, sep, list, false);
}

/**
Concatenates a list of strings without any separator.

Params:
    arg = a Nix list of strings

Returns: A single Nix string with all elements concatenated.
*/
export extern (C) Value concatStrings(Value arg)
{
    WasmAllocator allocator = newWasmAllocator();

    Value[] list = arg.getList(allocator);
    validateStringList(list);
    return concatWithSeparator(allocator, "", list, false);
}

/**
Joins a list of strings with a separator.

Alias for $(LREF concatStringsSep).

Params:
    args = an attrset with `sep` (string) and `list` (list of strings)

Returns: A single Nix string with elements joined by the separator.
*/
export extern (C) Value join(Value args)
{
    return concatStringsSep(args);
}

/**
Concatenates strings with newline separators, including a trailing newline.

Params:
    arg = a Nix list of strings

Returns: A Nix string with elements separated and terminated by newlines.
*/
export extern (C) Value concatLines(Value arg)
{
    WasmAllocator allocator = newWasmAllocator();

    Value[] list = arg.getList(allocator);
    validateStringList(list);
    return concatWithSeparator(allocator, "\n", list, true);
}

/**
Replaces occurrences of substrings in a string.

Params:
    args = an attrset with `from` (list of patterns),
        `to` (list of replacements), and `s` (the input string)

Returns: The input string with all replacements applied left-to-right.
*/
export extern (C) Value replaceStrings(Value args)
{
    WasmAllocator allocator = newWasmAllocator();

    Value fromVal = args.getAttr("from");
    if (fromVal.id == 0)
        nixPanic("missing 'from' argument");
    Value[] from = fromVal.getList(allocator);

    Value toVal = args.getAttr("to");
    if (toVal.id == 0)
        nixPanic("missing 'to' argument");
    Value[] to = toVal.getList(allocator);

    Value sVal = args.getAttr("s");
    if (sVal.id == 0)
        nixPanic("missing 's' argument");
    const(char)[] input = sVal.getString(allocator);

    return replaceStringsImpl(allocator, input, from, to);
}

/**
Intersperses a separator value between list elements.

Params:
    args = an attrset with `sep` (separator string) and `list` (list of strings)

Returns: A Nix list with the separator inserted between each pair of elements.
*/
export extern (C) Value intersperse(Value args)
{
    WasmAllocator allocator = newWasmAllocator();

    Value sepVal = args.getAttr("sep");
    if (sepVal.id == 0)
        nixPanic("missing 'sep' argument");
    const(char)[] sep = sepVal.getString(allocator);

    Value listVal = args.getAttr("list");
    if (listVal.id == 0)
        nixPanic("missing 'list' argument");
    Value[] strings = listVal.getList(allocator);

    validateStringList(strings);

    if (strings.length == 0)
    {
        return Value.makeList((cast(Value*) null)[0 .. 0]);
    }

    size_t resultLen = strings.length * 2 - 1;
    Value[] result = makeArrayOrPanic!Value(allocator, resultLen);

    Value sepValue = Value.makeString(sep);

    foreach (i; 0 .. strings.length)
    {
        if (i > 0)
        {
            result[i * 2 - 1] = sepValue;
        }
        result[i * 2] = strings[i];
    }

    return Value.makeList(result);
}

/**
Repeats a string a given number of times.

Params:
    args = an attrset with `n` (non-negative integer) and `s` (the string to repeat)

Returns: A Nix string containing `s` repeated `n` times.
*/
export extern (C) Value replicate(Value args)
{
    WasmAllocator allocator = newWasmAllocator();

    Value nVal = args.getAttr("n");
    if (nVal.id == 0)
        nixPanic("missing 'n' argument");
    long n = nVal.getInt();

    if (n < 0)
    {
        nixPanic("'n' must be a non-negative integer");
    }

    Value sVal = args.getAttr("s");
    if (sVal.id == 0)
        nixPanic("missing 's' argument");
    const(char)[] s = sVal.getString(allocator);

    size_t count = cast(size_t) n;
    ubyte[] result = makeArrayOrPanic!ubyte(allocator, s.length * count);

    foreach (i; 0 .. count)
    {
        result[i * s.length .. (i + 1) * s.length] = cast(const(ubyte)[]) s;
    }

    return Value.makeString(cast(const(char)[]) result);
}
