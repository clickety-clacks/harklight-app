#!/bin/bash
set -euo pipefail
umask 077

action=$1
work=$2
release="$work/release"
state="$work/state"
cli="$release/bin/harklight"
export ATTENTION_SERVER_FEATURE_FLAGS_PATH="$work/flags.json"
export ATTENTION_SERVER_UPLOAD_CAP_BYTES=67108864

if [[ $action == bootstrap ]]; then
    printf '%s\n' '{"client_api_v2":true}' > "$ATTENTION_SERVER_FEATURE_FLAGS_PATH"
    "$release/bin/harklight-bootstrap" "$state" localhost > "$work/bootstrap.log" 2>&1
    exit
fi

if [[ $action == start ]]; then
    source "$state/server.env"
    exec "$release/bin/attention_server" start
fi

owner=(--connect 127.0.0.1 --name localhost --port 18445 --ca "$state/tls/ca.pem"
       --cert "$state/owner/identity.pem" --key "$state/owner/identity.key" --person "$(cat "$state/person-id")")

case $action in
    seed)
        curl_cmd=(curl --http1.1 --silent --show-error --connect-timeout 2 --max-time 5
                  --resolve localhost:18444:127.0.0.1 --cacert "$state/tls/ca.pem")
        ready=''
        for ((i=0; i<25; i++)); do
            if "${curl_cmd[@]}" https://localhost:18444/ -o /dev/null 2>/dev/null; then
                ready=1
                break
            fi
            sleep 1
        done
        [[ $ready == 1 ]]
        "$cli" enroll start --directory "$work/sender" --connect 127.0.0.1 --name localhost \
            --port 18444 --ca "$state/tls/ca.pem" --label 'B3 synthetic sender'
        code=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["approval_code"])' "$work/sender/pending.json")
        printf 'APPROVE\n' | "$cli" owner approve "${owner[@]}" --code "$code" --senders app:b3
        python3 - <<'PY' > "$work/seed.json"
import json, time, uuid
print(json.dumps({"sender": "app:b3", "session": str(uuid.uuid4()),
                  "message": {"title": "B3 fixture request", "created_at": int(time.time() * 1000),
                              "message_type": "request",
                              "answer_ui": {"schema": "attention-client.actions/1",
                                            "actions": [{"id": "reply", "label": "Reply", "kind": "text"}]}}}))
PY
        curl --http1.1 --silent --show-error --fail --max-time 15 --resolve localhost:18443:127.0.0.1 \
            --cacert "$state/tls/ca.pem" --cert "$work/sender/identity.pem" --key "$work/sender/identity.key" \
            --header 'Content-Type: application/json' --header "Idempotency-Key: $(python3 -c 'import uuid; print(uuid.uuid4())')" \
            --data-binary "@$work/seed.json" -o "$work/seed-response.json" https://localhost:18443/v2/agent/messages
        python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["message"]["item_id"]' "$work/seed-response.json"
        ;;
    invite)
        "$cli" owner invite "${owner[@]}" --output "$work/invitation.json"
        ;;
    approve)
        code=$3
        [[ $code =~ ^[A-Za-z0-9\ -]{4,64}$ ]]
        printf 'APPROVE\n' | "$cli" owner approve "${owner[@]}" --code "$code"
        ;;
    *)
        exit 2
        ;;
esac
