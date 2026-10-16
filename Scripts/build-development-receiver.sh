#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${HARKLIGHT_PHYSICAL_DEVICE_ID:?Set the registered physical device ID.}"
: "${HARKLIGHT_DEVELOPMENT_PROFILE:?Set the verified co.clicketyclacks.Harklight development profile name.}"

cd "$ROOT"
xcodegen generate
exec xcodebuild \
    -project AttentionClientDuoPrototype.xcodeproj \
    -scheme AttentionClientDuoPrototype \
    -configuration Debug \
    -destination "platform=iOS,id=$HARKLIGHT_PHYSICAL_DEVICE_ID" \
    -derivedDataPath "$ROOT/DerivedData-ReceiverDevelopment" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM=Z7R59J7QV8 \
    PRODUCT_BUNDLE_IDENTIFIER=co.clicketyclacks.Harklight \
    CODE_SIGN_ENTITLEMENTS=Signing/ReceiverDevelopment.entitlements \
    PROVISIONING_PROFILE_SPECIFIER="$HARKLIGHT_DEVELOPMENT_PROFILE" \
    build
