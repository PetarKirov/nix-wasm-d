#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

BUILD_DIR="${BUILD_DIR:-build}"

(
  set -x
  dub build :json
  dub build :strings
)

NIX_CMD=(nix eval --impure --extra-experimental-features wasm-builtin)

# Verify that `nix` supports the `wasm-builtin` experimental feature.
if ! "${NIX_CMD[@]}" --expr "builtins ? wasm" 2>/dev/null | grep -q "true"; then
  echo "Error: this version of nix does not support the 'wasm-builtin' experimental feature." >&2
  echo "  nix path:    $(which nix)" >&2
  echo "  nix version: $(nix --version)" >&2
  echo "  hint: use the patched nix from this project's devShell (nix develop)" >&2
  exit 1
fi

passed=0
failed=0
run_test() {
  local module="$1" func="$2" expr="$3" expected="$4"
  local nix_expr="builtins.wasm ./${BUILD_DIR}/${module} \"${func}\" ${expr}"
  result=$("${NIX_CMD[@]}" --expr "$nix_expr" 2>&1 | grep -v "^warning:" || true)
  if [ "$result" = "$expected" ]; then
    echo "✓ ${module}::${func}"
    passed=$((passed + 1))
  else
    echo "✗ ${module}::${func}"
    echo "  expected: ${expected}"
    echo "  got:      ${result}"
    echo "  command:  ${NIX_CMD[*]} --expr '${nix_expr}'"
    failed=$((failed + 1))
  fi
}

echo "--- strings.wasm ---"
run_test strings.wasm replicate '{ n = 3; s = "v"; }' '"vvv"'
run_test strings.wasm concatStrings '["foo" "bar" "baz"]' '"foobarbaz"'
run_test strings.wasm concatStringsSep '{ sep = "/"; list = ["usr" "local" "bin"]; }' '"usr/local/bin"'
run_test strings.wasm concatLines '["foo" "bar"]' "\"foo\nbar\n\""
run_test strings.wasm replaceStrings '{ from = ["Hello" "world"]; to = ["Goodbye" "Nix"]; s = "Hello, world!"; }' '"Goodbye, Nix!"'
run_test strings.wasm intersperse '{ sep = "/"; list = ["usr" "local" "bin"]; }' '[ "usr" "/" "local" "/" "bin" ]'
run_test strings.wasm join '{ sep = ", "; list = ["foo" "bar"]; }' '"foo, bar"'

echo
echo "--- json.wasm ---"
run_test json.wasm fromJSON '"{ \"x\": 42 }"' '{ x = 42; }'
run_test json.wasm fromJSON '"{ \"a\": [1, 2, 3], \"b\": null }"' '{ a = [ 1 2 3 ]; b = null; }'
run_test json.wasm toJSON '{ x = [1 2 3]; y = null; }' '"{\"x\":[1,2,3],\"y\":null}"'

echo
echo "--- results ---"
echo "${passed} passed, ${failed} failed"

if [ "$failed" -gt 0 ]; then
  exit 1
fi
