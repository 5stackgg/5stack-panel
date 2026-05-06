# 5stack Platform Changelog

> Auto-generated — single source of truth for all 5stack ecosystem changes.
> Run `python3 changelogs/scripts/generate_changelog.py --help` for manual generation.

<!-- BEGIN GENERATED CONTENT -->

## 2026-05-06

### [api](https://github.com/5stackgg/api)

#### ✨ Features

- GPU usage ([`da93fc2`](https://github.com/5stackgg/api/commit/da93fc2b6bf3b45f0e231a12ebd8f8e3f67f407e)) — _Luke Policinski_
- Update how we pick best round by looking at kills diff ([`c98908a`](https://github.com/5stackgg/api/commit/c98908ac1f2c69b0387185bf6fdc9e5b6b1fc1f9)) — _Luke Policinski_
- Stream live no delay ([`11c5304`](https://github.com/5stackgg/api/commit/11c530402f95c67dd7c9f84d5fcf729a2293d429)) — _Luke Policinski_
- Snapshots ([`23e33c6`](https://github.com/5stackgg/api/commit/23e33c6621bc7c4eaf76a93572c8944d4e66c107)) — _Luke Policinski_

#### 🐛 Bug Fixes

- Fix missing dl url for minio ([`ece43c6`](https://github.com/5stackgg/api/commit/ece43c63fe7069327bc9d124fcb1ad832dd4f030)) — _Luke Policinski_
- Skipping clips cause owner was not set ([`da305c3`](https://github.com/5stackgg/api/commit/da305c3becef5f4cc5b84493a9ebff975a517f4d)) — _Luke Policinski_
- Fix migration for gpu busy nodes ([`3666450`](https://github.com/5stackgg/api/commit/3666450c20d33dfbc1dffc547a0dba55b27510bb)) — _Luke Policinski_
- Fix last signed in at cache ([`bedee53`](https://github.com/5stackgg/api/commit/bedee53126a97657d628fcddcf76157d95c57bdb)) — _Luke Policinski_

#### 🔧 Maintenance

- Mtx dfomain ([`d4021da`](https://github.com/5stackgg/api/commit/d4021daa61f3a8cd4e92ebd5b67d8ffbc287efe0)) — _Luke Policinski_
- Remove limit ([`739e0b0`](https://github.com/5stackgg/api/commit/739e0b09a5749eed6fd81e8b4557503a362d5ebd)) — _Luke Policinski_

### [web](https://github.com/5stackgg/web)

#### ✨ Features

- GPU usage ([`831d812`](https://github.com/5stackgg/web/commit/831d81241a9e02d2dd8577d0f748e1a2d7dd9428)) — _Luke Policinski_
- Stream live no delay ([`6a341db`](https://github.com/5stackgg/web/commit/6a341db68014abf5cfd82e53b5778217cceadd51)) — _Luke Policinski_
- Snapshots ([`0851fe3`](https://github.com/5stackgg/web/commit/0851fe3d88ecef6ea677dee71a0423333811f26e)) — _Luke Policinski_

#### 🐛 Bug Fixes

- Fix spectator buttons growing too big based on the number of players ([`981dac9`](https://github.com/5stackgg/web/commit/981dac99f4c6c880e07b3a404468566ff5c678c7)) — _Luke Policinski_
- Dont fetch logs when not a game node server ([`cd78b84`](https://github.com/5stackgg/web/commit/cd78b8417710a5fb24e5e9ebdbdaf396ca979498)) — _Luke Policinski_
- Dont require auth for match highlights ([`519979a`](https://github.com/5stackgg/web/commit/519979af29024257f3347b6e4ffa77b55023f0f0)) — _Luke Policinski_

#### 🔧 Maintenance

- Update to allow sorting by last sign in at ([`bf7ea28`](https://github.com/5stackgg/web/commit/bf7ea28584cc939908a9863a066a9ac9b149245c)) — _Luke Policinski_
- Update how we show volume ([`746cf69`](https://github.com/5stackgg/web/commit/746cf69dd5a7e6de83710963ba078b534aa287d8)) — _Luke Policinski_
- Remove unused settings in the app settings ([`0af577e`](https://github.com/5stackgg/web/commit/0af577ecfd288a39df35e2eaa9c75c9d41382994)) — _Luke Policinski_
- Add full screen to highlights ([`4ad4fc6`](https://github.com/5stackgg/web/commit/4ad4fc6d55193cd75e3d673f768162fc0640cd27)) — _Luke Policinski_

### [game-server](https://github.com/5stackgg/game-server)

#### 🏷️ Releases

- **[v0.0.365](https://github.com/5stackgg/game-server/releases/tag/v0.0.365)** `v0.0.365` _2026-05-06_

#### 🐛 Bug Fixes

- Fix rounds ([`595daf5`](https://github.com/5stackgg/game-server/commit/595daf58060ed0c7e7fbcd75964eec543a2d7a62)) — _Luke Policinski_
- Dont kick if known password ([`3b3c0e3`](https://github.com/5stackgg/game-server/commit/3b3c0e38bea74b09c4d38d25e0a018d07b41af5c)) — _Luke Policinski_
- Fix delta out of order when not using playcast ([`dc06d20`](https://github.com/5stackgg/game-server/commit/dc06d20092935f1b392a7196bdf2797e847fdd96)) — _Luke Policinski_
- Fix playcast delay bug to allow tv to finish ([`efe2c28`](https://github.com/5stackgg/game-server/commit/efe2c2844208056e15cf3c55a634a3b5a5b9e720)) — _Luke Policinski_

### [game-streamer](https://github.com/5stackgg/game-streamer)

#### ✨ Features

- Snapshots ([`2e5077b`](https://github.com/5stackgg/game-streamer/commit/2e5077b183507dbbbce05880e0fb37b3db7816af)) — _Luke Policinski_
- Highlights ([`698e1e8`](https://github.com/5stackgg/game-streamer/commit/698e1e8d0fbbb9ca4bebd0d70217780af515e081)) — _Luke Policinski_

#### 🔧 Maintenance

- Mtx dfomain ([`6229c8c`](https://github.com/5stackgg/game-streamer/commit/6229c8cd1285750970b5493fe81f8dca89168a8e)) — _Luke Policinski_
- Lower cuda ([`a4b20ce`](https://github.com/5stackgg/game-streamer/commit/a4b20ce653700afadf7e140e8d5c0c18bc8ae15d)) — _Luke Policinski_
- Add live state ([`4188b9c`](https://github.com/5stackgg/game-streamer/commit/4188b9c9bdb06d93dceec2a547592388d2468ef8)) — _Luke Policinski_

<!-- END GENERATED CONTENT -->
