#!/bin/bash
# Mac용 snapserver(수정판) 빌드: 늦은 타이머 깨어남마다 스트림 시각을 재조정(onResync)하지 않게 함
#  2026-10-08 실측: 10분에 onResync 7~14회 → 매번 모든 폰이 하드 재동기화 (00 HANDOFF)
#  결과: tools/snapserver/snapserver  (Homebrew snapserver와 같은 설정 파일 사용)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${WORK:-$HOME/build-snapserver-mac}"
REV=4fed179e177b251c67326e7b62a25c8d8fb2d1a9   # ios_client와 같은 snapcast 리비전
BOOST=1.86.0
mkdir -p "$WORK" && cd "$WORK"
[ -d snapcast ] || git clone -q https://github.com/snapcast/snapcast.git
git -C snapcast checkout -q -f "$REV"
git -C snapcast apply "$HERE/snapserver-late-read.patch"
if [ ! -d "boost-$BOOST" ]; then
  B="$HOME/build-snapclient-ios/boost-$BOOST"
  if [ -d "$B" ]; then ln -s "$B" "boost-$BOOST"; else
    curl -sSL -o boost.tar.xz "https://github.com/boostorg/boost/releases/download/boost-$BOOST/boost-$BOOST-b2-nodocs.tar.xz"
    tar -xf boost.tar.xz; fi
fi
# codec=flac(무손실 압축, 7대일 때 Wi-Fi 부하 줄이기, 2026-10-09)용으로 Homebrew flac을 씀(brew install flac pkgconf).
# vorbis/opus/expat 없이 빌드. pkg-config가 없으면 빈 stub로 대신한다(그 경우 flac 없음).
PKG=$(command -v pkg-config || ls /opt/homebrew/Cellar/pkgconf/*/bin/pkg-config 2>/dev/null | tail -1 || true)
FLAC=OFF
if [ -n "$PKG" ] && PKG_CONFIG_PATH="$(brew --prefix flac 2>/dev/null)/lib/pkgconfig" "$PKG" --exists flac; then
  FLAC=ON; export PKG_CONFIG_PATH="$(brew --prefix flac)/lib/pkgconfig"
fi
if [ -z "$PKG" ]; then
  PKG="$WORK/pkg-config-stub"
  printf '#!/bin/sh\n[ "$1" = --version ] && echo 0.29.2 && exit 0\nexit 1\n' > "$PKG"; chmod +x "$PKG"
fi
rm -rf out
cmake -S snapcast -B out -DCMAKE_BUILD_TYPE=Release -DBUILD_CLIENT=OFF -DBUILD_SERVER=ON -DBUILD_TESTS=OFF \
  -DBUILD_WITH_AVAHI=OFF -DBUILD_WITH_SSL=OFF -DBUILD_WITH_FLAC=$FLAC -DBUILD_WITH_VORBIS=OFF -DBUILD_WITH_OPUS=OFF \
  -DBUILD_WITH_EXPAT=OFF -DPKG_CONFIG_EXECUTABLE="$PKG" -DBoost_INCLUDE_DIR="$WORK/boost-$BOOST" >/dev/null
cmake --build out -j"$(sysctl -n hw.ncpu)" --target snapserver
cp "$(find snapcast/bin out -name snapserver -type f -perm +111 | head -1)" "$HERE/snapserver"
"$HERE/snapserver" --version | head -1
echo "flac: $FLAC"
