#!/usr/bin/env bash
set -euo pipefail

SDK=/home/user/android-sdk
BT="$SDK/build-tools/34.0.0"
AJ="$SDK/platforms/android-34/android.jar"
cd "$(dirname "$0")"

rm -rf build dist
mkdir -p build/classes build/dex dist

echo "==> aapt2 compile"
"$BT/aapt2" compile --dir res -o build/res.zip

echo "==> aapt2 link"
"$BT/aapt2" link -o build/base.apk \
  -I "$AJ" \
  --manifest AndroidManifest.xml \
  -R build/res.zip \
  --auto-add-overlay \
  -A assets \
  --min-sdk-version 24 \
  --target-sdk-version 34

echo "==> javac"
find java -name '*.java' > build/srcs.txt
javac -encoding UTF-8 -source 11 -target 11 -nowarn -classpath "$AJ" -d build/classes @build/srcs.txt

echo "==> d8"
find build/classes -name '*.class' > build/classes.txt
"$BT/d8" --lib "$AJ" --min-api 24 --release --output build/dex @build/classes.txt

echo "==> package"
cp build/base.apk build/unsigned.apk
(cd build/dex && zip -q -X ../unsigned.apk classes.dex)

echo "==> zipalign"
"$BT/zipalign" -f -p 4 build/unsigned.apk build/aligned.apk

if [ ! -f iris-release.jks ]; then
  echo "==> keystore"
  keytool -genkeypair -v -keystore iris-release.jks -alias iris \
    -keyalg RSA -keysize 2048 -validity 10950 \
    -storepass iris2026 -keypass iris2026 \
    -dname "CN=Iris Palette, OU=Mobile, O=Iris, L=Qingyuan, ST=Guangdong, C=CN" >/dev/null 2>&1
fi

echo "==> sign"
"$BT/apksigner" sign \
  --ks iris-release.jks --ks-pass pass:iris2026 --key-pass pass:iris2026 \
  --v2-signing-enabled true --v3-signing-enabled true \
  --out "dist/Iris_1.0.4.apk" build/aligned.apk

echo "==> verify"
"$BT/apksigner" verify "dist/Iris_1.0.4.apk" && echo "signature ok"
ls -lh "dist/Iris_1.0.4.apk"
