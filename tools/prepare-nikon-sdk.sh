#!/bin/sh
set -eu

archive="${SRCROOT}/Dependencies/NikonRemoteSDK/2.1.0/S-SDKZ-210BF-ALLIN.zip"
stage="${DERIVED_FILE_DIR}/NikonRemoteSDK"
frameworks="${TARGET_BUILD_DIR}/${FRAMEWORKS_FOLDER_PATH}"
profiles="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/NikonProfiles"

if [ ! -f "$archive" ]; then
    echo "error: 请将尼康原包 S-SDKZ-210BF-ALLIN.zip 放在 $archive" >&2
    exit 1
fi
expected=a39b923c8d7409ad79f20d148621e02a1cae563e02d960dc7a3ba1f2c35f571c
digest=$(/usr/bin/shasum -a 256 "$archive")
if [ "${digest%% *}" != "$expected" ]; then
    echo "error: SDK 原包与项目使用的 Nikon Remote SDK 2.1.0 校验值不符。" >&2
    exit 1
fi

mkdir -p "$stage" "$frameworks" "$profiles"
/usr/bin/unzip -oq "$archive" 'Module/Mac/HeaderFile/*' Module/Mac/BinaryFile/TestApp.zip -d "$stage"
/usr/bin/unzip -oq "$stage/Module/Mac/BinaryFile/TestApp.zip" \
    'TestApp/TestApp/TypeCommon Module.bundle/*' 'TestApp/Frameworks/*' 'TestApp/TestApp/*.config' -d "$stage"
runtime="$stage/TestApp"
/usr/bin/ditto "$runtime/TestApp/TypeCommon Module.bundle" "$frameworks/TypeCommon Module.bundle"
/usr/bin/ditto "$runtime/Frameworks/Royalmile.framework" "$frameworks/Royalmile.framework"
/usr/bin/ditto "$runtime/Frameworks/libNkPTPDriver2.dylib" "$frameworks/libNkPTPDriver2.dylib"
for profile in DC_PTP_Config.config MaidLayer.config RangeValue.config; do
    /usr/bin/install -m 644 "$runtime/TestApp/$profile" "$profiles/$profile"
done
