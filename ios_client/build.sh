#!/usr/bin/env bash
# snapclient를 탈옥 iOS(Dopamine, rootless, arm64)용 .deb로 빌드한다.
# 검증 환경: Ubuntu 24.04 x86_64, clang/lld 18, cmake 3.28 / macOS(Apple Silicon, Xcode clang, Homebrew cmake·ninja·pkgconf·dpkg)
# 필요: clang, lld(ld64.lld, Linux), cmake, ninja, pkg-config, llvm-strip, dpkg-deb, git, curl
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/build-snapclient-ios}"
SNAPCAST_REV=4fed179e177b251c67326e7b62a25c8d8fb2d1a9   # snapcast develop, 2026-06-12
SDK_NAME=iPhoneOS16.5.sdk                              # theos/sdks
BOOST=1.86.0
mkdir -p "$WORK" && cd "$WORK"

[ -d snapcast ] || git clone -q https://github.com/snapcast/snapcast.git
git -C snapcast checkout -q -f "$SNAPCAST_REV"
git -C snapcast apply "$HERE/snapcast-ios.patch"

if [ ! -d "sdks/$SDK_NAME" ]; then
  git clone -q --depth 1 --filter=blob:none --sparse https://github.com/theos/sdks.git
  git -C sdks sparse-checkout set "$SDK_NAME"
fi
if [ ! -d "boost-$BOOST" ]; then
  curl -sSL -o boost.tar.xz "https://github.com/boostorg/boost/releases/download/boost-$BOOST/boost-$BOOST-b2-nodocs.tar.xz"
  tar -xf boost.tar.xz
fi
if [ ! -x ldid ]; then
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64)  A=ldid_linux_x86_64 ;;
    Linux-aarch64) A=ldid_linux_aarch64 ;;
    Darwin-*)      A=ldid_macosx_$(uname -m) ;;
  esac
  curl -sSL -o ldid "https://github.com/ProcursusTeam/ldid/releases/download/v2.1.5-procursus7/$A" && chmod +x ldid
fi

# Linux에서는 Apple binutils 대신 LLVM 도구를 쓴다
find_llvm() {
  for n in "$1" "$1-18" "$1-19" "$1-17"; do command -v "$n" >/dev/null && { command -v "$n"; return; }; done
  ls /usr/lib/llvm-*/bin/"$1" 2>/dev/null | tail -1
}
TOOLS=""
if [ "$(uname -s)" = Linux ]; then
  TOOLS="set(CMAKE_EXE_LINKER_FLAGS_INIT \"-fuse-ld=lld\")
set(CMAKE_AR $(find_llvm llvm-ar) CACHE FILEPATH \"\")
set(CMAKE_RANLIB $(find_llvm llvm-ranlib) CACHE FILEPATH \"\")
set(CMAKE_INSTALL_NAME_TOOL $(find_llvm llvm-install-name-tool) CACHE FILEPATH \"\")"
fi

cat > toolchain-ios.cmake <<TC
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)
set(CMAKE_OSX_DEPLOYMENT_TARGET 15.0)
set(CMAKE_OSX_SYSROOT $WORK/sdks/$SDK_NAME)
set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_C_COMPILER_TARGET arm64-apple-ios15.0)
set(CMAKE_CXX_COMPILER_TARGET arm64-apple-ios15.0)
set(CMAKE_FIND_ROOT_PATH $WORK/sdks/$SDK_NAME)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE BOTH)
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
# 빌드 폴더 경로(사용자 이름 포함)가 실행 파일에 남지 않게
set(CMAKE_C_FLAGS_INIT "-ffile-prefix-map=$WORK=/build")
set(CMAKE_CXX_FLAGS_INIT "-ffile-prefix-map=$WORK=/build")
$TOOLS
TC

# libFLAC(정적, iOS arm64): codec=flac으로 7대 Wi-Fi 부하를 줄인다 (2026-10-09, 7ch PCM 약 38 Mbps → 시계 맞춤이 수 ms 밀림)
FLAC_VER=1.4.3
if [ ! -f deps/prefix/lib/libFLAC.a ]; then
  mkdir -p deps && ( cd deps
    [ -d "flac-$FLAC_VER" ] || { curl -sSL -o flac.tar.xz "https://github.com/xiph/flac/releases/download/$FLAC_VER/flac-$FLAC_VER.tar.xz" && tar -xf flac.tar.xz; }
    rm -rf flac-out && cmake -S "flac-$FLAC_VER" -B flac-out -G Ninja -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain-ios.cmake" \
      -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF \
      -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF -DWITH_OGG=OFF -DWITH_STACK_PROTECTOR=OFF -DWITH_FORTIFY_SOURCE=OFF >/dev/null
    ninja -C flac-out FLAC >/dev/null   # 전체 빌드는 microbench가 -lrt 때문에 실패
    rm -rf prefix && mkdir -p prefix/lib/pkgconfig prefix/include
    cp flac-out/src/libFLAC/libFLAC.a prefix/lib/ && cp -R "flac-$FLAC_VER/include/FLAC" prefix/include/
    printf 'prefix=%s\nName: FLAC\nDescription: libFLAC iOS static\nVersion: %s\nLibs: -L${prefix}/lib -lFLAC\nCflags: -I${prefix}/include -DFLAC__NO_DLL\n' \
      "$WORK/deps/prefix" "$FLAC_VER" > prefix/lib/pkgconfig/flac.pc )
fi
# pkg-config가 호스트(Homebrew 등) 라이브러리를 찾지 않게 한다 (macOS에서 soxr dylib 링크 오류) → iOS용 deps만
export PKG_CONFIG_LIBDIR="$WORK/deps/prefix/lib/pkgconfig" PKG_CONFIG_PATH=""
# macOS: Homebrew pkgconf는 link 안 된 채로 있을 수 있음
PKG=$(command -v pkg-config || ls /opt/homebrew/Cellar/pkgconf/*/bin/pkg-config /usr/local/Cellar/pkgconf/*/bin/pkg-config 2>/dev/null | tail -1 || true)
[ -n "$PKG" ] || { echo "pkg-config가 없습니다 (apt install pkg-config / brew install pkgconf)"; exit 1; }
rm -rf out && cmake -S snapcast -B out -G Ninja -DCMAKE_TOOLCHAIN_FILE="$WORK/toolchain-ios.cmake" \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SERVER=OFF -DBUILD_WITH_SSL=OFF -DBUILD_WITH_ALSA=OFF \
  -DBUILD_WITH_FLAC=ON -DBUILD_WITH_VORBIS=OFF -DBUILD_WITH_OPUS=OFF -DBUILD_WITH_AVAHI=OFF \
  -DBUILD_WITH_EXPAT=OFF -DBUILD_SHARED_LIBS=OFF -DPKG_CONFIG_EXECUTABLE="$PKG" -DBoost_INCLUDE_DIR="$WORK/boost-$BOOST"
ninja -C out snapclient

rm -rf stage && cp -r "$HERE/pkg" stage
cp snapcast/bin/snapclient.app/snapclient stage/var/jb/usr/bin/snapclient
STRIP=$(command -v llvm-strip || command -v llvm-strip-18 || command -v strip)
"$STRIP" -x stage/var/jb/usr/bin/snapclient
./ldid -S"$HERE/entitlements.plist" stage/var/jb/usr/bin/snapclient
# keepawake: 화면이 꺼져도 폰이 잠들지 않게 (run 래퍼가 snapclient와 함께 띄움)
KA_LD=""; [ "$(uname -s)" = Linux ] && KA_LD="-fuse-ld=lld"
clang -O2 -ffile-prefix-map="$HERE"=/src -target arm64-apple-ios15.0 -isysroot "$WORK/sdks/$SDK_NAME" $KA_LD -framework CoreFoundation -framework IOKit \
  -o stage/var/jb/usr/bin/keepawake "$HERE/keepawake.c"
./ldid -S"$HERE/keepawake.entitlements" stage/var/jb/usr/bin/keepawake
find stage -type d -exec chmod 755 {} +
chmod 755 stage/DEBIAN/postinst stage/DEBIAN/prerm stage/var/jb/usr/bin/* stage/var/jb/usr/libexec/snapclient/run
chmod 644 stage/DEBIAN/control stage/DEBIAN/conffiles stage/var/jb/etc/snapclient.conf stage/var/jb/Library/LaunchDaemons/*.plist
VER=$(sed -n 's/^Version: //p' stage/DEBIAN/control)
mkdir -p "$HERE/dist"
dpkg-deb -Zxz --root-owner-group -b stage "$HERE/dist/io.github.jangcuber.snapclient_${VER}_iphoneos-arm64.deb"
echo "완료: $HERE/dist/io.github.jangcuber.snapclient_${VER}_iphoneos-arm64.deb"
