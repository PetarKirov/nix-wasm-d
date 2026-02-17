# nix-wasm-d

D implementation for [WASM plugin support](https://github.com/DeterminateSystems/nix-src/blob/main/doc/manual/source/protocols/wasm.md) in [Determinate Nix 3.16.0](https://github.com/DeterminateSystems/nix-src/tree/v3.16.0), compiled to WebAssembly with [LDC](https://wiki.dlang.org/LDC).

This project is a port of [**nix-wasm-zig**](https://github.com/moni-dz/nix-wasm-zig) by [@moni-dz](https://github.com/moni-dz). The original Zig implementation provided the architecture, API bindings, and builtin modules that this D version faithfully follows. Thank you for the excellent groundwork!

## Overview

Nix's WASM builtin protocol lets you extend the Nix evaluator with custom functions implemented as WebAssembly modules. This project provides:

- **`nix_wasm`** — a core D package with types, host FFI bindings, and a bump allocator for the WASM environment
- **Builtin modules** — each compiled to a standalone `.wasm` file that Nix can load directly

### Included builtins

| Module | Functions | Description |
|---|---|---|
| `strings.wasm` | `concatStrings`, `concatStringsSep`, `concatLines`, `join`, `replaceStrings`, `intersperse`, `replicate` | String manipulation |
| `json.wasm` | `fromJSON`, `toJSON` | JSON parsing and serialization |

## Prerequisites

- [Nix](https://nixos.org/) with flake support

All build tools (LDC, dub, lld, wabt) and [Determinate Nix](https://github.com/DeterminateSystems/nix-src) ≥ 3.16.0 are provided by the Nix dev shell — no manual installation needed.

## Quick start

```bash
# Enter the dev shell
direnv allow
# or:
nix develop

# Build all WASM modules
dub build :json
dub build :strings

# Try it out!
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "replicate" { n = 3; s = "na"; }'
# => "nanana"
```

## Examples

### String builtins

```bash
# concatStrings — concatenate a list of strings
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "concatStrings" ["foo" "bar" "baz"]'
# => "foobarbaz"

# concatStringsSep — join strings with a separator
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "concatStringsSep" { sep = "/"; list = ["usr" "local" "bin"]; }'
# => "usr/local/bin"

# concatLines — join strings with newlines (trailing newline included)
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "concatLines" ["foo" "bar"]'
# => "foo\nbar\n"

# join — alias for concatStringsSep
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "join" { sep = ", "; list = ["foo" "bar"]; }'
# => "foo, bar"

# replaceStrings — substitute substrings
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "replaceStrings" { from = ["Hello" "world"]; to = ["Goodbye" "Nix"]; s = "Hello, world!"; }'
# => "Goodbye, Nix!"

# intersperse — interleave a separator between list elements
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "intersperse" { sep = "/"; list = ["usr" "local" "bin"]; }'
# => [ "usr" "/" "local" "/" "bin" ]

# replicate — repeat a string N times
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/strings.wasm "replicate" { n = 3; s = "v"; }'
# => "vvv"
```

### JSON builtins

```bash
# fromJSON — parse a JSON string into a Nix value
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/json.wasm "fromJSON" "{\"x\": [1, 2, 3], \"y\": null}"'
# => { x = [ 1 2 3 ]; y = null; }

# toJSON — serialize a Nix value to a JSON string
nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/json.wasm "toJSON" { x = [1 2 3]; y = null; }'
# => "{\"x\":[1,2,3],\"y\":null}"
```

## Project structure

```
.
├── src/nix_wasm/
│   ├── package.d              # Core package: types, host FFI, allocator
│   └── builtins/
│       ├── json.d             # fromJSON / toJSON
│       └── strings.d          # String manipulation builtins
├── script/
│   └── test.sh               # Test runner
├── build/                     # Compiled .wasm output (generated)
├── dub.sdl                    # Package definition with :json and :strings subpackages
└── flake.nix                  # Nix dev shell
```

## How it works

Each builtin module in `src/nix_wasm/builtins/` is compiled to a standalone `.wasm` file using LDC's `wasm32-unknown-unknown-wasm` target with `-betterC` (no D runtime/GC). The core package (`src/nix_wasm/package.d`) provides:

- **Host FFI bindings** — `extern(C)` declarations with `@llvmAttr("wasm-import-module", "env")` for the [Nix WASM protocol](https://github.com/DeterminateSystems/nix-src/blob/main/doc/manual/source/protocols/wasm.md)
- **`Value` struct** — wraps a `ValueId` (u32) with methods for creating/reading Nix values (ints, floats, strings, lists, attrsets, etc.)
- **`WasmAllocator`** — a simple bump allocator (1 MB static arena) for temporary allocations within a single builtin call
- **C runtime stubs** — `memcpy`, `memset`, `memmove`, `memcmp` implementations since `-betterC` WASM has no libc

## Adding a new builtin

1. Create a new file in `src/nix_wasm/builtins/`, e.g. `src/nix_wasm/builtins/math.d`:

```d
module nix_wasm.builtins.math;

import nix_wasm;

export extern(C) void nix_wasm_init_v1() {
    nixWarn("hello from nix-wasm-d");
    nixWarn("math wasm module");
}

/// add { a = 1; b = 2; }  =>  3
export extern(C) Value add(Value args) {
    WasmAllocator allocator;
    allocator.init();

    Value aVal = args.getAttr("a");
    if (aVal.id == 0) nixPanic("missing 'a' argument");

    Value bVal = args.getAttr("b");
    if (bVal.id == 0) nixPanic("missing 'b' argument");

    return Value.makeInt(aVal.getInt() + bVal.getInt());
}
```

2. Add a subpackage to `dub.sdl`:

```sdl
subPackage {
    name "math"
    targetType "executable"
    targetName "math"
    targetPath "build"
    sourcePaths
    sourceFiles "src/nix_wasm/builtins/math.d" "src/nix_wasm/package.d"

    buildOptions "betterC"
    dflags "-fvisibility=hidden" platform="ldc"
    lflags "-allow-undefined" "--no-entry" "--export-dynamic" platform="ldc"
}
```

3. Build and test:

```bash
dub build --compiler=ldc2 --arch=wasm32-unknown-unknown-wasm :math

nix eval --impure --extra-experimental-features wasm-builtin \
  --expr 'builtins.wasm ./build/math.wasm "add" { a = 40; b = 2; }'
# => 42
```

## Acknowledgments

This project is a D port of [**nix-wasm-zig**](https://github.com/moni-dz/nix-wasm-zig) by [Lythe Marvin Lacre (moni-dz)](https://github.com/moni-dz), which pioneered the approach of using a systems language to compile Nix WASM builtins. The API design, module structure, and builtin implementations follow the original closely.

## License

MIT
