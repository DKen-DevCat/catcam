#!/bin/sh
# release ビルドして build/catcam.app に包む。
# ターミナルから素の実行ファイルを起動すると、ビデオエフェクト等の設定がターミナル.app のものになるため .app として起動する
set -eu
cd "$(dirname "$0")/.."
swift build -c release
app=build/catcam.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/CatCam "$app/Contents/MacOS/CatCam"
cp Support/Info.plist "$app/Contents/Info.plist"
plutil -insert CFBundleExecutable -string CatCam "$app/Contents/Info.plist"
plutil -insert CFBundlePackageType -string APPL "$app/Contents/Info.plist"
plutil -insert LSMinimumSystemVersion -string 14.0 "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
