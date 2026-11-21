#!/bin/bash
set -euo pipefail
umask 077

server=$1
release=$2
expected=1dc7ecbe0fa6e8239d9aef659116bc8e942ec164
git init -q "$server"
git -C "$server" fetch --quiet --depth=1 --no-tags https://github.com/clickety-clacks/harklight-server.git "$expected"
git -C "$server" checkout -q --detach FETCH_HEAD
[[ $(git -C "$server" rev-parse HEAD) == "$expected" ]]
cd "$server"

export MIX_ENV=prod
mix local.hex --force
mix local.rebar --force
mix deps.get --only prod
mix release attention_server --path "$release"
install -m 755 scripts/bootstrap.sh "$release/bin/harklight-bootstrap"
install -m 755 scripts/harklight "$release/bin/harklight"
