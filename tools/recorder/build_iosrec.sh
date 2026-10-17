#!/bin/bash
# 탈옥 아이폰용 녹음기 빌드 (Mac Xcode iPhoneOS SDK + ldid). 결과: tools/recorder/iosrec
cd "$(dirname "$0")" || exit 1
xcrun -sdk iphoneos swiftc -O -target arm64-apple-ios15.0 -o iosrec iosrec.swift || exit 1
ldid -Siosrec.entitlements iosrec && echo "iosrec 빌드 완료"
