# Notices

This repository is licensed under the GNU General Public License v3.0 (see `LICENSE`).
It contains patches to, and is built from, the following third-party projects. Their source is downloaded at build time;
only patch files and original code live in this repository.

| Project | Used for | License |
|---|---|---|
| [Snapcast](https://github.com/snapcast/snapcast), Copyright (C) 2014-2025 Johannes Pohl (badaix) | `ios_client/snapcast-ios.patch` (iOS client), `tools/snapserver/snapserver-late-read.patch` (Mac server), protocol reimplemented in `windows_host/snaphost.py` | GPL-3.0 |
| [BlackHole](https://github.com/ExistentialAudio/BlackHole) v0.7.2, Copyright (C) 2019 Existential Audio Inc. | `tools/sysaudio/blackhole_7_1_4.patch` (12-channel 7.1.4 virtual device "SpatialPhones") | GPL-3.0 |
| [FLAC](https://github.com/xiph/flac) 1.4.3 (libFLAC), Xiph.Org Foundation | statically linked into the iOS client | BSD-3-Clause |
| [Boost](https://www.boost.org/) 1.86.0 | headers used by Snapcast | BSL-1.0 |
| [theos/sdks](https://github.com/theos/sdks) iPhoneOS16.5.sdk | build-time iOS SDK (not redistributed) | Apple SDK terms |
| [ldid](https://github.com/ProcursusTeam/ldid) (Procursus) | build-time code signing | AGPL-3.0 (tool only) |
| [Dopamine](https://github.com/opa334/Dopamine) | the jailbreak the phones need (not included) | — |

Binary `.deb` packages published on the Releases page contain the modified Snapcast client (GPL-3.0); the corresponding
source is this repository plus Snapcast commit `4fed179e177b251c67326e7b62a25c8d8fb2d1a9`.

"Dolby", "Dolby Atmos", "Apple Music", "iPhone" and "Mac" are trademarks of their respective owners. This project is not affiliated with them.
