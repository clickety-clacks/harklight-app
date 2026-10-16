#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURES="$ROOT/Tests/Fixtures"
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/harklight-test-tls.XXXXXX")
trap 'rm -rf "$TEMP_DIR"' EXIT HUP INT TERM

cat > "$TEMP_DIR/ca.cnf" <<'EOF'
[req]
distinguished_name = name
x509_extensions = ca
prompt = no
[name]
CN = Harklight loopback test CA
[ca]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF
cat > "$TEMP_DIR/server.cnf" <<'EOF'
[req]
distinguished_name = name
prompt = no
[name]
CN = localhost
[server]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:localhost,IP:127.0.0.1
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
    -config "$TEMP_DIR/ca.cnf" -keyout "$TEMP_DIR/ca.key" \
    -out "$TEMP_DIR/ca.pem" 2> "$TEMP_DIR/openssl.log"
openssl req -new -newkey rsa:2048 -nodes -sha256 \
    -config "$TEMP_DIR/server.cnf" -keyout "$TEMP_DIR/server.key" \
    -out "$TEMP_DIR/server.csr" 2>> "$TEMP_DIR/openssl.log"
openssl x509 -req -in "$TEMP_DIR/server.csr" -CA "$TEMP_DIR/ca.pem" \
    -CAkey "$TEMP_DIR/ca.key" -CAcreateserial -days 2 -sha256 \
    -extfile "$TEMP_DIR/server.cnf" -extensions server \
    -out "$TEMP_DIR/server.pem" 2>> "$TEMP_DIR/openssl.log"
openssl pkcs12 -export -inkey "$TEMP_DIR/server.key" -in "$TEMP_DIR/server.pem" \
    -certfile "$TEMP_DIR/ca.pem" -name "Harklight loopback test" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout pass:public-fixture-only -out "$TEMP_DIR/guided-local-tls.p12"
mkdir -p "$FIXTURES"
cp "$TEMP_DIR/ca.pem" "$FIXTURES/guided-local-tls.pem"
cp "$TEMP_DIR/guided-local-tls.p12" "$FIXTURES/guided-local-tls.p12"
