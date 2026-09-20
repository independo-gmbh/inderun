## [0.2.2](https://github.com/independo-gmbh/inderun/compare/v0.2.1...v0.2.2) (2026-08-16)

### Bug Fixes 🛠️

* **ci:** drop broken sdkmanager platform install in maven-publish ([#143](https://github.com/independo-gmbh/inderun/issues/143)) ([#144](https://github.com/independo-gmbh/inderun/issues/144)) ([e46d26e](https://github.com/independo-gmbh/inderun/commit/e46d26e4679a9f964720168b0e946c4ee34136e1))

## [0.2.1](https://github.com/independo-gmbh/inderun/compare/v0.2.0...v0.2.1) (2026-08-16)

### Bug Fixes 🛠️

* **ci:** discard regenerated WASM stub before semantic-release backmerge ([ca98aa7](https://github.com/independo-gmbh/inderun/commit/ca98aa7b85b7d2d5a079c90ab4fa582dcabcfe7a))
* **deps:** pin adm-zip and sharp to patched versions via pnpm overrides ([aecd636](https://github.com/independo-gmbh/inderun/commit/aecd636f5840f63abe66b81093e4aef85d447e0b))

## [0.2.0](https://github.com/independo-gmbh/inderun/compare/v0.1.2...v0.2.0) (2026-08-16)

### Features 🚀

* add checkCapabilities() introspection and redesign web demo routing UI ([31d9f08](https://github.com/independo-gmbh/inderun/commit/31d9f085cc81a5dbdcff2168c4001a353c93976e))
* **android:** Android ONNX Runtime provider for developer-supplied models ([#128](https://github.com/independo-gmbh/inderun/issues/128)) ([7bdfb02](https://github.com/independo-gmbh/inderun/commit/7bdfb029a394c20250659f609a0f01749f59a372)), closes [#87](https://github.com/independo-gmbh/inderun/issues/87)
* **android:** harden ONNX runtime (NNAPI/XNNPACK EP, shared env, KV-cache, sampling) ([96fdf8f](https://github.com/independo-gmbh/inderun/commit/96fdf8f060cac24847ccb489509920a785cdc20b)), closes [#127](https://github.com/independo-gmbh/inderun/issues/127)
* **android:** rebuild demo app with capability-based routing UI and ONNX provider ([554b73f](https://github.com/independo-gmbh/inderun/commit/554b73f9c05b4aaca7367d937330cd32ad7f9967))
* **contracts:** generate cross-language IndeRunApi interface surface ([#123](https://github.com/independo-gmbh/inderun/issues/123)) ([d2ec832](https://github.com/independo-gmbh/inderun/commit/d2ec8329de24848e7c94744cc20d48e539665656)), closes [#134](https://github.com/independo-gmbh/inderun/issues/134)
* **contracts:** specify ONNX Runtime provider family and model package contract ([#32](https://github.com/independo-gmbh/inderun/issues/32)) ([741a258](https://github.com/independo-gmbh/inderun/commit/741a25861de1895f630f1555ddea1c51a784c77f)), closes [#85](https://github.com/independo-gmbh/inderun/issues/85) [#87](https://github.com/independo-gmbh/inderun/issues/87) [#86](https://github.com/independo-gmbh/inderun/issues/86)
* **ios:** add Apple ONNX Runtime provider for developer-supplied models ([#125](https://github.com/independo-gmbh/inderun/issues/125)) ([68ccdf4](https://github.com/independo-gmbh/inderun/commit/68ccdf410d600091b9ff225eace6bb0125b74267)), closes [#86](https://github.com/independo-gmbh/inderun/issues/86) [#32](https://github.com/independo-gmbh/inderun/issues/32) [#88](https://github.com/independo-gmbh/inderun/issues/88)
* **ios:** harden ONNX runtime (CoreML EP, shared env, KV-cache, sampling) and add LaMini-GPT demo model ([db704de](https://github.com/independo-gmbh/inderun/commit/db704de594f261e8c40f3c9af049a7b9d8c47647)), closes [#126](https://github.com/independo-gmbh/inderun/issues/126)
* **ios:** rebuild demo app with capability-based routing UI and ONNX provider ([1d70398](https://github.com/independo-gmbh/inderun/commit/1d70398fd00af0cca15eea8938700121e44df377))
* **web:** add Web system-model provider (Chrome Prompt API) ([728bc5b](https://github.com/independo-gmbh/inderun/commit/728bc5b2cd4a9b2235f6fd02cfe3ae2fb69bd8bf)), closes [#78](https://github.com/independo-gmbh/inderun/issues/78)
* **web:** implement ONNX Runtime provider for Web ([#85](https://github.com/independo-gmbh/inderun/issues/85)) ([455ae6b](https://github.com/independo-gmbh/inderun/commit/455ae6b6b1096f12eb963c8cae36e5102ac0b415)), closes [#32](https://github.com/independo-gmbh/inderun/issues/32) [#32](https://github.com/independo-gmbh/inderun/issues/32)

### Bug Fixes 🛠️

* **android:** avoid ktlint chain-wrapping ambiguity in NNAPI fallback ([81ee286](https://github.com/independo-gmbh/inderun/commit/81ee286bf8ffeeab77413f0b26b5d0c9460b2bc6))
* **ci:** unblock Dependabot queue, harden GitHub Actions workflows ([d7314c6](https://github.com/independo-gmbh/inderun/commit/d7314c64a1afa368dbb84507a95fe2850ea62722))
* **contracts:** bump quicktype to 26, adapt Kotlin generation ([b91a160](https://github.com/independo-gmbh/inderun/commit/b91a160c8ed48c8fea66c213425d970f19dadec7))
* probe OpenAI provider endpoint reachability in capabilities() ([68fc5ce](https://github.com/independo-gmbh/inderun/commit/68fc5ce13bd04022a6852525e8cda44ae647366a))
* **web:** default SystemModelWebProvider to the Chrome runtime ([c0959de](https://github.com/independo-gmbh/inderun/commit/c0959de425d3d15819dd0b22a25103a6a320efae))
* **web:** make WASM route planner actually load in bundler builds ([fabe26d](https://github.com/independo-gmbh/inderun/commit/fabe26d182e0fa00224e5b2ed92f7f4d0e8be730)), closes [#109](https://github.com/independo-gmbh/inderun/issues/109)

### Documentation 📚

* add spec for checkCapabilities() + web demo routing showcase ([5d458e7](https://github.com/independo-gmbh/inderun/commit/5d458e70b67851b039610c7c18076e9c2963a261))
* align provider docs with implementation, close [#84](https://github.com/independo-gmbh/inderun/issues/84)/[#88](https://github.com/independo-gmbh/inderun/issues/88), align README with OSS strategy ([7ceeee7](https://github.com/independo-gmbh/inderun/commit/7ceeee74cbad3e375043137ae28a7e54ec4774da))
* **ci:** document CodeQL as main-only PR gating, dev via weekly schedule ([78c67d2](https://github.com/independo-gmbh/inderun/commit/78c67d22c75e73270995b6f388120053afdc4baf))
* document toolchain prerequisites for contributors ([91c06c7](https://github.com/independo-gmbh/inderun/commit/91c06c7d77e3fd97297079de0352fe109532e542))
* research cross-platform API surface generation ([#123](https://github.com/independo-gmbh/inderun/issues/123)) ([844784e](https://github.com/independo-gmbh/inderun/commit/844784ef2da5e6b5a779a4057211d37f41904755))
* revise API surface generation recommendation to Option A ([be76764](https://github.com/independo-gmbh/inderun/commit/be76764547ee33606efca2ebb50accdd448b53ae))

### Miscellaneous Chores 🛠️

* **ci:** ignore vendored .build/ paths in CodeQL scan ([df477d6](https://github.com/independo-gmbh/inderun/commit/df477d69287f279cc79cfe56c5e5e57a4a3502f2)), closes [huggingface/swift-huggingface#62](https://github.com/huggingface/swift-huggingface/issues/62)
* **deps-dev:** bump @semantic-release/changelog from 6.0.3 to 7.0.0 ([26e2490](https://github.com/independo-gmbh/inderun/commit/26e249054e9abaf5b49c38e68c65f11ede5b0e2c))
* **deps-dev:** bump @semantic-release/git from 10.0.1 to 11.0.1 ([6f520c4](https://github.com/independo-gmbh/inderun/commit/6f520c4ba86a02ae97e4efdd5ad347dadef23818))
* **deps-dev:** bump @types/node from 24.13.2 to 26.1.1 ([76a00c3](https://github.com/independo-gmbh/inderun/commit/76a00c377aee22873dcc22cf65a77b8b0ac9963e))
* **deps-dev:** bump conventional-changelog-conventionalcommits ([f0d19a6](https://github.com/independo-gmbh/inderun/commit/f0d19a62c482a55c704aa28b2dfff404df89e3e3))
* **deps-dev:** bump conventional-changelog-conventionalcommits ([d0b7402](https://github.com/independo-gmbh/inderun/commit/d0b7402ea86591ff75c3605c87a5088e9d4d518b))
* **deps-dev:** bump quicktype from 23.3.6 to 24.0.2 ([a5a1714](https://github.com/independo-gmbh/inderun/commit/a5a1714756be787b3067257173c3855aafc58b95))
* **deps-dev:** bump the npm-routine group across 1 directory with 4 updates ([6678839](https://github.com/independo-gmbh/inderun/commit/66788395873ef96b55e51c900c6740d12cc4c46e))
* **deps-dev:** bump the npm-routine group across 1 directory with 5 updates ([47160d7](https://github.com/independo-gmbh/inderun/commit/47160d708c782d2f95a6b1d64c375763266cc713))
* **deps-dev:** bump the npm-routine group with 2 updates ([956b557](https://github.com/independo-gmbh/inderun/commit/956b557578cfbfe0454f39b7823c76d4b5074dfb))
* **deps:** bump actions/cache from 4.3.0 to 6.1.0 ([f16035f](https://github.com/independo-gmbh/inderun/commit/f16035f7390a14be1abdd235ea215aec5fc34f5a))
* **deps:** bump actions/setup-node from 6.4.0 to 7.0.0 ([9993272](https://github.com/independo-gmbh/inderun/commit/99932721bd09c1945fc0389f7da25e2d632bff76))
* **deps:** bump com.google.mlkit:genai-prompt in /android ([4bd5ec8](https://github.com/independo-gmbh/inderun/commit/4bd5ec8c88cead7f5de7cf0d7e30e9386f411588))
* **deps:** bump dorny/paths-filter from 3.0.4 to 4.0.2 ([a4fb41d](https://github.com/independo-gmbh/inderun/commit/a4fb41dffe04074b1a322c4290a38ba810a0f540))
* **deps:** bump the github-actions-routine group across 1 directory with 3 updates ([389cfe7](https://github.com/independo-gmbh/inderun/commit/389cfe743372c4eb8c3eec6f6aebdc7c253dc50d))
* **deps:** bump the github-actions-routine group with 2 updates ([1d0492e](https://github.com/independo-gmbh/inderun/commit/1d0492e74506c656c150898e5929999c77499a31))
* **deps:** bump the github-actions-routine group with 2 updates ([61468c4](https://github.com/independo-gmbh/inderun/commit/61468c414e2390bd38db02699d70bbbbd99382d8))
* **deps:** bump the github-actions-routine group with 3 updates ([0b5532a](https://github.com/independo-gmbh/inderun/commit/0b5532a096c5f65cd954089e9ddb453056277609))
* **deps:** bump the github-actions-routine group with 3 updates ([5af5a51](https://github.com/independo-gmbh/inderun/commit/5af5a5171a299957ae55e835d29d1f4575370dd1))
* **deps:** bump the gradle-routine group across 1 directory with 13 updates ([2ebdca8](https://github.com/independo-gmbh/inderun/commit/2ebdca80084cbd92c23b68e1ea875683a5155dd3))
* **deps:** bump the gradle-routine group in /android with 3 updates ([2d38724](https://github.com/independo-gmbh/inderun/commit/2d387248c9eb49a0f664c56c522ba0237114b855))
* **deps:** upgrade android dependencies ([8e9c67f](https://github.com/independo-gmbh/inderun/commit/8e9c67f09843ddf2241f991322a2267844d51dee))
* **deps:** upgrade npm dependencies ([2079870](https://github.com/independo-gmbh/inderun/commit/20798703ae72cd56fd0286f6580c91f91963b4ce))
* **ios:** ignore generated project.xcworkspace state ([2d6243c](https://github.com/independo-gmbh/inderun/commit/2d6243c604eb04cdb24616ffae2961b6277ee4fc))
* move Capacitor bridge to dedicated repo ([c3a05fa](https://github.com/independo-gmbh/inderun/commit/c3a05faa80759a3bf4d95875aff850dfc7af2c43)), closes [#73](https://github.com/independo-gmbh/inderun/issues/73)

### Code Refactors 🏗️

* **ios:** split SystemOnnxGenAiRuntime.swift by concern ([a75f26a](https://github.com/independo-gmbh/inderun/commit/a75f26a53e36553c8d7d233930352790650178ee))
* **web:** group inderun-web src by concern (core/providers) ([55cbad8](https://github.com/independo-gmbh/inderun/commit/55cbad86036c258f66682c41b182a9392771d756))

### CI/CD 👷

* **codeql:** cache SwiftPM deps and raise swift job timeout ([6fe9ca7](https://github.com/independo-gmbh/inderun/commit/6fe9ca7d05cd6c5441b7e342e5286dbfbb5629ab))
* explicitly install NDK/CMake for CodeQL and Maven publish ([5404d98](https://github.com/independo-gmbh/inderun/commit/5404d98390eb546ed742aa125cfa48dd8f585210))

## [0.1.2](https://github.com/independo-gmbh/inderun/compare/v0.1.1...v0.1.2) (2026-07-07)

### Bug Fixes 🛠️

* **ci:** run full contract generation in release workflow ([f351df7](https://github.com/independo-gmbh/inderun/commit/f351df74256e2c181f684d245de57eb494cb5828))

### Miscellaneous Chores 🛠️

* **deps:** upgrade npm dependencies ([a269afa](https://github.com/independo-gmbh/inderun/commit/a269afac61493284e2ed19fe0a6073399d7434cb))

## [0.1.1](https://github.com/independo-gmbh/inderun/compare/v0.1.0...v0.1.1) (2026-07-07)

### Bug Fixes 🛠️

* **ci:** dependabot cooldown, vanniktech 0.37 API, prerelease-free changelog ([8b3fa0a](https://github.com/independo-gmbh/inderun/commit/8b3fa0aaf1020eeb07a59823955d97b94067265e))
* **release:** pass npm --tag for prerelease publishes ([b119f76](https://github.com/independo-gmbh/inderun/commit/b119f769da676af0598b99f4c5050446b43c29b3))

### Documentation 📚

* **readme:** lead with on-device providers; link Core Docs ([6eddef1](https://github.com/independo-gmbh/inderun/commit/6eddef11dad53fd54c3279a1d358ec6a1dd8ca3d))
* restructure README per platform; fix badges ([3c44f4b](https://github.com/independo-gmbh/inderun/commit/3c44f4b89d11c7513e48d389577de2946170c2bf))
* use version-less install snippets where the platform allows ([187df3c](https://github.com/independo-gmbh/inderun/commit/187df3ccfe4a7b0b5bd68283c6287e53cc10ab01))

### Miscellaneous Chores 🛠️

* **deps:** bump github/codeql-action ([191c50a](https://github.com/independo-gmbh/inderun/commit/191c50a1760337e58954fa141d0623fcf843feed))
* **release:** 0.1.1-dev.1 [skip ci] ([8a115fe](https://github.com/independo-gmbh/inderun/commit/8a115fe96b6164f1c3289d42ddbe960844f1a787))
* **release:** 0.1.1-dev.1 [skip ci] ([0e5ebc1](https://github.com/independo-gmbh/inderun/commit/0e5ebc12cc4c745a5c461f7c8364bc259d185495))
* skip capacitor builds for now - will be moved to dedicated repo soon ([73bf453](https://github.com/independo-gmbh/inderun/commit/73bf453649d0e340c3de80f6d02f9b4ecbd9d6a6))

### CI/CD 👷

* **release:** add automated multi-registry publishing ([#22](https://github.com/independo-gmbh/inderun/issues/22)) ([eb687d7](https://github.com/independo-gmbh/inderun/commit/eb687d7c360d37a67972475b23540e768d821377))
