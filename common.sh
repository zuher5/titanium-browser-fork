export SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

replace() {
    export org="$2" new="$3"
    find "$1" -type f -exec sed -i 's@'"$org"'@'"$new"'@g' {} +
}

set_keys() {
    mkdir -p "$SCRIPT_DIR/keys"
    echo "${LOCAL_TEST_JKS:-}" | base64 -d > "$SCRIPT_DIR/keys/local.properties" 2>/dev/null || true
    echo "${STORE_TEST_JKS:-}" | base64 -d > "$SCRIPT_DIR/keys/test.jks" 2>/dev/null || true
    unset LOCAL_TEST_JKS
    unset STORE_TEST_JKS
}

sign_apk() {
    local input_apk="$1"
    local output_apk="$2"
    export apksigner=$(find "${ANDROID_HOME:-}/build-tools" -name apksigner 2>/dev/null | sort | tail -n 1)
    if [[ -z "${apksigner:-}" || ! -x "$apksigner" ]]; then
        echo "Error: apksigner not found under ${ANDROID_HOME:-}/build-tools" >&2
        return 1
    fi
    if [[ ! -s "$SCRIPT_DIR/keys/local.properties" || ! -s "$SCRIPT_DIR/keys/test.jks" ]]; then
        echo "Error: Signing keys not found in $SCRIPT_DIR/keys" >&2
        return 1
    fi
    source "$SCRIPT_DIR/keys/local.properties"
    "$apksigner" sign -verbose \
        -ks "$SCRIPT_DIR/keys/test.jks" \
        --ks-pass "pass:${storePassword:-}" \
        --key-pass "pass:${keyPassword:-}" \
        --ks-key-alias "${keyAlias:-}" \
        --out "$output_apk" "$input_apk"
}

version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}
