# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](http://keepachangelog.com/en/1.0.0/)
and this project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html).

<!-- insertion marker -->
## Unreleased

<small>[Compare with latest](https://github.com/kamoyl/movies_management/compare/fd4378f30a45e184b8332729e72de01c51f96e39...HEAD)</small>

### Added

- Added forgotten script ([fc629f0](https://github.com/kamoyl/movies_management/commit/fc629f03ce12cb7128a694322fae35012c7af3b7) by Kamoyl).

### Fixed

- Fix serialized background jobs and TrueHD frame drop; add timeline.csv ([07e7946](https://github.com/kamoyl/movies_management/commit/07e79461d3ab978b3a02b4a894e750105b419a8e) by Kamoyl).

### Changed


### Removed

- Remove the tone_mapping_runtime statistics column ([fe3bc96](https://github.com/kamoyl/movies_management/commit/fe3bc96fc68ad85f91ab95cc6033d826fcb4338e) by Kamoyl).

### Misc

- report.xlsx also after an error exit (EXIT trap) ([c1f7cd0](https://github.com/kamoyl/movies_management/commit/c1f7cd0eeb51ec92e40d534a7b21f9708554a83a) by Kamoyl).
- memory.csv: memory estimate vs reality per encode; report sheet ([41bd21b](https://github.com/kamoyl/movies_management/commit/41bd21b611e913dc2f9584672bd00d62571d0f64) by Kamoyl).
- HandBrake watchdog; leftover processes listed after Ctrl+C ([4837cd5](https://github.com/kamoyl/movies_management/commit/4837cd5c2dfc895d7df2f7ce2b9e1c578ac4ddcd) by Kamoyl).
- .config synced from get-auditing; config_syncing added ([3f44637](https://github.com/kamoyl/movies_management/commit/3f44637150cbfcf9bf64e7c5037d9b315fce2660) by Kamoyl).
- Metrics sampling, memory warning before the encode, Excel report ([82894a0](https://github.com/kamoyl/movies_management/commit/82894a054ba50c06e24680bde10c87afea075e1b) by Kamoyl).
- README: optimization state over time; metrics planned first ([f73c3c3](https://github.com/kamoyl/movies_management/commit/f73c3c36fc3ae025cab337722202a92dc1c48b4f) by Kamoyl).
- Compress the remaining logs also after Ctrl+C / systemctl stop ([ce3e980](https://github.com/kamoyl/movies_management/commit/ce3e980a8294b8aa2dd069235d413cf3b5a37ac1) by Kamoyl).
- Compress logs with gzip; ToDo list moved from the script header to README ([fb42af2](https://github.com/kamoyl/movies_management/commit/fb42af229fdc9b4b4e2dfa718ad3a5938b365b94) by Kamoyl).
- Frame analysis: 7 sampled frames by seeking instead of decoding the whole chunk ([3d4a2cb](https://github.com/kamoyl/movies_management/commit/3d4a2cb6c50bf62ef3715bae88edca8212b437e1) by Kamoyl).
- recovering_lost_frames: tone mapping before select, recovery took ~8 min per open-GOP split ([b6541d0](https://github.com/kamoyl/movies_management/commit/b6541d0e69524377786e8634dc37fc546553427a) by Kamoyl).
- interpolation_nncn -S: start through /usr/bin/env (SELinux); Ctrl+C removes frame_analysis ([b682fe8](https://github.com/kamoyl/movies_management/commit/b682fe80c034af04698354ff6aa0bf4500fe2f25) by Kamoyl).
- interpolation_nncn -S: run in the background as a systemd service ([1f95de0](https://github.com/kamoyl/movies_management/commit/1f95de0833525f7aeaeac6247eeef9d689fadc9a) by Kamoyl).
- interpolation_nncn: Ctrl+C cleans up, keeping finished chunks ([d283cd3](https://github.com/kamoyl/movies_management/commit/d283cd3dc3088c52eeac80f10b48aa7d77da47c7) by Kamoyl).
- interpolation_nncn: resume by default; -F for a fresh start ([f75f929](https://github.com/kamoyl/movies_management/commit/f75f929c766630082cd51e404989c9cd305b927d) by Kamoyl).
- -E: stop the run after a failed encode; record the encode profile ([3fb04d3](https://github.com/kamoyl/movies_management/commit/3fb04d3db858386932b6b50c8680115848efb5cf) by Kamoyl).
- Space monitor: fix divide by zero and the run-wide peak ([c7a0121](https://github.com/kamoyl/movies_management/commit/c7a012111d65d0410c13bca0c5f99a53224dc7af) by Kamoyl).
- -E join: take audio and subtitles from the source, not the parts ([f18972f](https://github.com/kamoyl/movies_management/commit/f18972f0a5ea354a5e9926aa830431c6b14e8594) by Kamoyl).
- Updated CHANGELOG only ([3a6cd16](https://github.com/kamoyl/movies_management/commit/3a6cd167a550f3884a1379c44747340e48200b36) by Kamoyl).
- Joined movie in sync: recover open-GOP frames, exact frame rate ([b7f0359](https://github.com/kamoyl/movies_management/commit/b7f03598967c43e152176ab1ed115ee8cfcb9153) by Kamoyl).
- updated CHANGELOG ([0a402fa](https://github.com/kamoyl/movies_management/commit/0a402fadbad5472043b2fe7362b9eb5821a70561) by Kamoyl).
- README: add research item for interpolation above 8 bits ([3706956](https://github.com/kamoyl/movies_management/commit/370695631936248d08f5133f73ac50030653a0f0) by Kamoyl).
- interpolation_nncn: split only at keyframes the decoder can start from ([eff9fa3](https://github.com/kamoyl/movies_management/commit/eff9fa3d776bd58e94b1b82af9e3ce5b609eff5d) by Kamoyl).
- README: drop "frames on tmpfs" from the planned optimizations, with measurement ([4630449](https://github.com/kamoyl/movies_management/commit/463044948f7cb6a2f3966fa1c15c447be79eb210) by Kamoyl).
- .gitignore: ignore the local var and download symlinks ([745c3bd](https://github.com/kamoyl/movies_management/commit/745c3bd09171dbb1dff1e4b6c0a5279f6e022517) by Kamoyl).
- interpolation_nncn: split at closed-GOP keyframes, count decoded frames, keep video in sync ([7a987c3](https://github.com/kamoyl/movies_management/commit/7a987c3cbbd63652761cfab3cf6827c731e09ed9) by Kamoyl).
- Final encode of each part (-E), VMAF in the background, frame-analysis fix ([1261d29](https://github.com/kamoyl/movies_management/commit/1261d29ed18d7637456b6640fac61fa8ab3218b2) by Kamoyl).
- Join parts with --append-mode track; fix bc divide by zero; drop debug echoes ([9f45dc6](https://github.com/kamoyl/movies_management/commit/9f45dc6d6645e87275b0910e438fdccc6b482b77) by Kamoyl).
- Updated gitignore ([a03765b](https://github.com/kamoyl/movies_management/commit/a03765bf8ea9c47a0960e65340ba3108934c4973) by Kamoyl).
- Tone mapping inside frame extraction; first complete run on macOS ([0332370](https://github.com/kamoyl/movies_management/commit/033237061d6144b4de5f4907fd676e152f6fac0b) by Kamoyl).
- Free disk space per chunk, fail early on NCNN errors, 4K codec benchmark ([0fbcfad](https://github.com/kamoyl/movies_management/commit/0fbcfad3a91fb8361e23cfcd14b693dca00dc37a) by Kamoyl).
- Selectable lossless intermediate codec; name unsplit results after input ([a1557a5](https://github.com/kamoyl/movies_management/commit/a1557a596d11e77394b545f3cfec1ccc2cb9ff0c) by Kamoyl).
- Use -fps_mode instead of removed -vsync; tidy ToDo header ([923610f](https://github.com/kamoyl/movies_management/commit/923610f2c543a84a58f716b9e12ec51a6645b3cf) by Kamoyl).
- Stop tracking Vim swap files ([8554c76](https://github.com/kamoyl/movies_management/commit/8554c761ef69846f7c57540f935eb3727f9a51ca) by Kamoyl).
- VMAF: compare only original-position frames; use all CPU cores ([aea2e93](https://github.com/kamoyl/movies_management/commit/aea2e93cbc5a570c4f4dd3c3b73ad2e56d0bee34) by Kamoyl).
- Process short videos in one go; add -T to switch off tone mapping ([b590ff5](https://github.com/kamoyl/movies_management/commit/b590ff550b46d2cf2844045a7f98317f249ab22c) by Kamoyl).
- Build NCNN tool when missing; keep test files in a local tmp/ ([d17d896](https://github.com/kamoyl/movies_management/commit/d17d896c0f34a8eaa7ea06d10227f8c87b720fdd) by Kamoyl).
- Use a decimal point for numbers regardless of locale ([f8c1c28](https://github.com/kamoyl/movies_management/commit/f8c1c285da0ea4ae686c3745aa898c224d4f83e7) by Kamoyl).
- Make scripts robust, coherent and tested; add README and CI ([9b64032](https://github.com/kamoyl/movies_management/commit/9b640320b0faaa7e58eaba43300b8114fbda101b) by Kamoyl).
- Tiny yet important changes in regards to syntax, and quality ([64c4783](https://github.com/kamoyl/movies_management/commit/64c4783aa5b719a1410f90d853b898f5ef0874da) by Kamoyl).
- Updating all changes I have done so far ([0cad841](https://github.com/kamoyl/movies_management/commit/0cad841be7cbdb9935184ae78b4ddfe68823ccf5) by Kamoyl).
- * added update full directory ([7a81568](https://github.com/kamoyl/movies_management/commit/7a81568afe1039af7d35cd4653ec3c2a9ce033a4) by Kamil Czarnecki).
- * lots of cleaning ([092c007](https://github.com/kamoyl/movies_management/commit/092c0079935a70f8ee8fd631bde862f560968225) by Kamil Czarnecki).
- * corrected weird issue related to update metadata of the movie ([e545089](https://github.com/kamoyl/movies_management/commit/e5450892a004d8dbdae47e175cf2e5dc1db4de35) by Kamil Czarnecki).
- * corrected minidla restart and refresh ([1bf5c8c](https://github.com/kamoyl/movies_management/commit/1bf5c8c0707d1af21857df6a631075cfea7558a0) by Kamil Czarnecki).
- * Added update of single files, when IMDB is provided, and when not, and if cover url is manually provided ([b2803b7](https://github.com/kamoyl/movies_management/commit/b2803b79868de23c54c0e6e620c62f704ea55d35) by Kamil Czarnecki).
- * completely rewritten code, migrated to functions, to let parameters work ([b918d67](https://github.com/kamoyl/movies_management/commit/b918d67942a044d454e4bcf4df9c23f8285ccdfa) by Kamil Czarnecki).
- * some cleaning ([a5870fa](https://github.com/kamoyl/movies_management/commit/a5870fa776ab4c3c7fdda5d12429e3dd44b70683) by Kamil Czarnecki).
- * first commit ([a9a3d60](https://github.com/kamoyl/movies_management/commit/a9a3d6094afb9321d85fb6ae88aa51f17e5e6cc8) by Kamil Czarnecki).
- Update README.md ([b73be4b](https://github.com/kamoyl/movies_management/commit/b73be4be15df64ff805b570dc1853fc6749582c3) by Kamil Czarnecki).
- Initial commit ([fd4378f](https://github.com/kamoyl/movies_management/commit/fd4378f30a45e184b8332729e72de01c51f96e39) by Kamil Czarnecki).

<!-- insertion marker -->
