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
    */api/tags*)
        if [[ "${HF_MODEL:-0}" == 1 ]]; then
            echo '{"models":[{"name":"hf.co/org/repo-GGUF:q4_K_M"}]}'
        else
            echo '{"models":[{"name":"custom:latest"},{"name":"base:latest"}]}'
        fi ;;
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
        echo "$request" >> "$TEST_DIR/requests"
        case "${REGISTRY_STATUS:-200}" in
            200) printf '{"layers":[{"mediaType":"application/vnd.ollama.image.model","digest":"sha256:%s"}]}\n200' "${MANIFEST_DIGEST:-bbbb}" ;;
            401) printf '%s\n401' '{"errors":[{"code":"UNAUTHORIZED","message":"authentication required"}]}' ;;
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
grep -q '^create custom ' "$test_dir/actions"
if grep -q '^pull ' "$test_dir/actions"; then
    echo 'Unexpected base pull for a stale custom model' >&2
    exit 1
fi
grep -q 'rebuild needed from base' "$test_dir/output"

# Missing manifests are expected skips; server failures remain errors.
export REGISTRY_STATUS=404
run_check 0
grep -q 'not in registry' "$test_dir/output"
export REGISTRY_STATUS=500
run_check 2
grep -q 'registry_http_500' "$test_dir/output"
unset REGISTRY_STATUS

# API errors must never be mistaken for different weight digests.
export SHOW_ERROR=1
run_check 2 --update
test ! -s "$test_dir/actions"
unset SHOW_ERROR

# A malformed filename or failed rebuild must not abort other rebuilds.
echo 'FROM base:latest' > "$test_dir/models/Modelfile-bad:name:tag"
run_check 2 --update
grep -q 'invalid model name in Modelfile filename' "$test_dir/output"
grep -q '^create custom ' "$test_dir/actions"
export CREATE_FAIL=1
run_check 2 --update
grep -q 'rebuild failed' "$test_dir/output"
unset CREATE_FAIL

# Local file bases are skipped instead of being passed to /api/show.
echo 'FROM /models/local.gguf' > "$test_dir/models/Modelfile-custom"
run_check 0
grep -q 'custom: local file base' "$test_dir/output"

# Hugging Face models are checked against huggingface.co manifests.
export HF_MODEL=1
: > "$test_dir/requests"
run_check 0
grep -q 'https://huggingface.co/v2/org/repo-GGUF/manifests/q4_K_M' "$test_dir/requests"
grep -q '^OK *hf.co/org/repo-GGUF:q4_K_M' "$test_dir/output"
export MANIFEST_DIGEST=cccc
run_check 1
grep -q '^UPDATE *hf.co/org/repo-GGUF:q4_K_M' "$test_dir/output"
unset MANIFEST_DIGEST

# Hugging Face answers 401 for missing, private and gated repos: skip it.
export REGISTRY_STATUS=401
run_check 0
grep -q 'not in registry, or private/gated' "$test_dir/output"
unset HF_MODEL

# A 401 from the Ollama registry is still an error.
run_check 2
grep -q 'registry_http_401' "$test_dir/output"
unset REGISTRY_STATUS
echo 'Regression checks passed.'
