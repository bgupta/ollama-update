#!/usr/bin/env bash
# Isolated integration checks: no network or real model changes.
set -euo pipefail
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
mkdir -p "$test_dir/bin" "$test_dir/models"
export TEST_DIR="$test_dir"
export PATH="$test_dir/bin:$PATH"

cat > "$test_dir/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -eu
request="$*"
case "$request" in
    */api/tags*) echo '{"models":[{"name":"custom:latest"},{"name":"base:latest"}]}' ;;
    */api/ps*) echo '{"models":[]}' ;;
    */api/show*)
        if [[ "$request" == *'"name":"custom'* ]]; then
            if [[ "${SHOW_ERROR:-0}" == 1 ]]; then
                echo '{"error":"invalid model name"}'
            else
                echo '{"modelfile":"FROM /blobs/sha256-aaaa"}'
            fi
        else
            echo '{"modelfile":"FROM /blobs/sha256-bbbb"}'
        fi ;;
    */manifests/*)
        case "${REGISTRY_STATUS:-200}" in
            200) printf '%s\n200' '{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:bbbb"}]}' ;;
            404) printf '%s\n404' '{"errors":[{"code":"MANIFEST_UNKNOWN","message":"manifest unknown"}]}' ;;
            500) printf 'server error\n500' ;;
        esac ;;
    *) exit 1 ;;
esac
MOCK
cat > "$test_dir/bin/ollama" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "$TEST_DIR/actions"
[[ "${CREATE_FAIL:-0}" != 1 ]]
MOCK
chmod +x "$test_dir/bin/curl" "$test_dir/bin/ollama"
echo 'FROM base:latest' > "$test_dir/models/Modelfile-custom"

run_check() {
    local expected="$1" actual=0
    shift
    : > "$test_dir/actions"
    bash "$repo_dir/ollama-update" --config /dev/null \
        --modelfile-dir "$test_dir/models" "$@" > "$test_dir/output" 2>&1 || actual=$?
    if [[ "$actual" != "$expected" ]]; then
        cat "$test_dir/output"
        echo "Expected exit $expected, got $actual" >&2
        exit 1
    fi
}

# Stale custom weights trigger a rebuild without a redundant base pull.
run_check 0 --update
rg -q '^create custom ' "$test_dir/actions"
! rg -q '^pull ' "$test_dir/actions"
rg -q 'rebuild needed from base' "$test_dir/output"

# Missing manifests are expected skips; server failures remain errors.
export REGISTRY_STATUS=404
run_check 0
rg -q 'not in registry' "$test_dir/output"
export REGISTRY_STATUS=500
run_check 2
rg -q 'registry_http_500' "$test_dir/output"
unset REGISTRY_STATUS

# API errors must never be mistaken for different weight digests.
export SHOW_ERROR=1
run_check 2 --update
test ! -s "$test_dir/actions"
unset SHOW_ERROR

# A malformed filename or failed rebuild must not abort other rebuilds.
echo 'FROM base:latest' > "$test_dir/models/Modelfile-bad:name:tag"
run_check 2 --update
rg -q 'invalid model name in Modelfile filename' "$test_dir/output"
rg -q '^create custom ' "$test_dir/actions"
export CREATE_FAIL=1
run_check 2 --update
rg -q 'rebuild failed' "$test_dir/output"
unset CREATE_FAIL

# Local file bases are skipped instead of being passed to /api/show.
echo 'FROM /models/local.gguf' > "$test_dir/models/Modelfile-custom"
run_check 0
rg -q 'custom: local file base' "$test_dir/output"
echo 'Regression checks passed.'
