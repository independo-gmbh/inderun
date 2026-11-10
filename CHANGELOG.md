## [0.5.0](https://github.com/independo-gmbh/inderun/compare/v0.4.0...v0.5.0) (2026-11-10)

### ⚠ BREAKING CHANGES

* **speech:** IndeRunApi gains a required close() member on TypeScript,
Swift and Kotlin, so custom IndeRunApi implementations must add it.
NeuralSpeechRuntime gains close() (optional on Web, defaulted on Swift; the
Kotlin interface now extends AutoCloseable with a default no-op).
* **providers:** on Kotlin, getModelPackageValidationIssues and
ModelPackageValidationIssue moved from app.independo.inderun.providers.onnx
(inderun-onnx-providers) to app.independo.inderun.core (inderun-core);
update the import. Swift keeps compiling: IndeRunOnnxProviders re-exports
IndeRunCore, where the validator now lives.
* **contracts:** PlaybackOutput's flat 'durationMs', 'firstAudioMs' and 'firstChunkMs'
moved into 'timing' (PlaybackTiming), on the wire and on SpokenSpeech in all three
SDKs; the Swift PlaybackOutput(durationMs:) and (durationMs:firstAudioMs:)
compatibility initializers and with(durationMs:) are gone, PlaybackOutput.CodingKeys
is 'timing' only. firstAudioMs now counts from the provider receiving the request, not
from the handoff to the platform. The generated Swift memberwise initializers of
ModelPackage, Runtime and ProviderVoice gained parameters; labelled compatibility
initializers keep the previous signatures. Format gained 'coreai', so exhaustive
switch/when statements need a case. The Kotlin ProviderVoice constructor gained
'locales' before 'name' (named arguments are unaffected). TypeScript SpeechVoiceInfo
gained a required 'kind'.
* **speech:** The generated Swift PlaybackOutput.CodingKeys gains a
firstAudioMs case, so a switch over it that lists every case must add one.
PlaybackOutput(durationMs:) and with(durationMs:) keep compiling.
* **sdk:** A custom ONNX runtime (OnnxGenAiRuntime,
AndroidOnnxGenAiRuntime, OnnxTextGenerationRuntime) must add availability(),
and prepare() now loads the model, so a corrupt model is found at load, not at
routing. AppleFoundationModelsAvailability gains notReady. ML Kit, Chrome and
Foundation Models descriptors now carry taskCapabilities.
* **api:** IndeRunApi gains readArtifact and disposeArtifact, which every implementer (including the Capacitor bridge and test fakes) must add. RunContext and ProviderStreamContext gain an artifacts sink.
* **engine:** RunContext and ProviderStreamContext gain commit(), and ProviderStreamEvent gains a result case that exhaustive Swift switch / Kotlin when statements must handle. The Swift/Kotlin terminal-outcome factories take an optional partialText and output. A cancelled stream outcome may now carry neither partialText nor output.
* **contracts:** the generated Output/OutputType types are renamed TaskOutput/TaskOutputType (Swift Kind is TaskKind), TaskResult.output.text and the terminal finalText/partialText are optional in the generated types, and TaskKind/TaskOutputType gain cases that exhaustive switch/when statements must handle. Text JSON payloads are unchanged, and generateText/streamText still return a non-optional string.
* **routing:** the route-plan and provenance reason codes gain
input_not_supported, output_delivery_not_supported,
output_format_not_supported, locale_not_supported and
voice_not_available; an exhaustive Swift switch over the generated Code
must handle them. A provider whose descriptor lists a task other than
text_to_text without declaring taskCapabilities is now rejected for it
with task_not_supported. The generated Swift memberwise initializers of
ProviderDescriptor, ProviderDynamicCapabilities, RoutePlannerInputTask and
Candidate gain parameters. Text requests reach the planner with inputs
["text"]. The planner's JSON output omits absent optional fields
instead of writing null. See docs/migration.md.
* **contracts:** the provider capability types are generated contracts.
Swift and Kotlin nested types move to top-level names:
ProviderDescriptor.ProviderType -> ProviderType, TransportType ->
ProviderTransport, StreamingStyle -> StreamingStyle, SupportsCapabilities
-> ProviderSupports, CancelSemantics -> CancelSemantics, ResourceLimits ->
ProviderLimits, PrivacyDescriptor -> ProviderPrivacy, and the request
privacy enum PrivacyEnum -> Privacy. Kotlin enum entries are PascalCase
with a rawValue (ProviderType.Local, CancelSemantics.None), ProviderLimits
fields are Long?, and these types must be constructed with named
arguments. Swift keeps the 0.4 initializer labels through convenience
initializers. A route-planner input passed to planRouteJson must carry
complete provider descriptors. See docs/migration.md.

### Features 🚀

* **api:** add the engine-owned artifact store with bounded reads and disposal ([3a64f29](https://github.com/independo-gmbh/inderun/commit/3a64f29959af4c6505e81997ba438bbef7a29174)), closes [#247](https://github.com/independo-gmbh/inderun/issues/247)
* **contracts:** admit text-to-speech requests and non-text outputs in the 1.0 contracts ([b5e4bf2](https://github.com/independo-gmbh/inderun/commit/b5e4bf2f34171e4ade1792780d707eecbc9b4c83))
* **contracts:** describe speech models, multilingual voices and playback timing ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([3dca2e0](https://github.com/independo-gmbh/inderun/commit/3dca2e07caf3e2effc88633b554d86d9f2d416b1))
* **contracts:** generate the provider capability snapshot from a schema ([c83bd81](https://github.com/independo-gmbh/inderun/commit/c83bd8138010f87d9cfb3ba4cee6fdb7125962a8)), closes [#210](https://github.com/independo-gmbh/inderun/issues/210)
* **core:** add the optional audio output host service ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([575836f](https://github.com/independo-gmbh/inderun/commit/575836f01e70ef96418a2a0b7afbb46d4cc98ec5))
* **demo:** publish the reference speech experience and release checks ([7b5aa81](https://github.com/independo-gmbh/inderun/commit/7b5aa814335f770d6df68e6144cc6be63333125b)), closes [#250](https://github.com/independo-gmbh/inderun/issues/250) [#252](https://github.com/independo-gmbh/inderun/issues/252)
* **demos:** add the opt-in Voices lab and the neural model catalog ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([b448f66](https://github.com/independo-gmbh/inderun/commit/b448f66110b00c3b5beffff443736c539c4dd936))
* **engine:** commit non-text outputs explicitly and carry them in terminal outcomes ([f3d7216](https://github.com/independo-gmbh/inderun/commit/f3d7216558fed958b4e68953018833607c4092aa))
* **engine:** write artifacts to app-provided destinations ([967e8fe](https://github.com/independo-gmbh/inderun/commit/967e8fe4120a56bf1ae82e5035e16ce6e4fb3346))
* **providers:** add the Android system speech provider ([32e1930](https://github.com/independo-gmbh/inderun/commit/32e1930a9d9649a35769cce0f8b453fa859205e8)), closes [#248](https://github.com/independo-gmbh/inderun/issues/248)
* **providers:** add the Apple Core AI neural speech runtime ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([b2e4edb](https://github.com/independo-gmbh/inderun/commit/b2e4edb95203c6e7e1d588586294b9fd77d1e8ec)), closes [#function](https://github.com/independo-gmbh/inderun/issues/function) [#if](https://github.com/independo-gmbh/inderun/issues/if)
* **providers:** add the Apple system speech provider ([263fce4](https://github.com/independo-gmbh/inderun/commit/263fce4826b03e40caf2fefcd41a2d2d772a8c1b)), closes [#244](https://github.com/independo-gmbh/inderun/issues/244) [#247](https://github.com/independo-gmbh/inderun/issues/247)
* **providers:** add the browser speechSynthesis provider ([292c7fd](https://github.com/independo-gmbh/inderun/commit/292c7fd3f88d4e5934c56b3a2329d96dc8ad53d2)), closes [#249](https://github.com/independo-gmbh/inderun/issues/249)
* **providers:** add the neural speech provider family ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([2e8b208](https://github.com/independo-gmbh/inderun/commit/2e8b2082b1e7106ca0b4e1634786d2c51ae78ca6))
* **providers:** normalize German text before neural speech ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([a43d049](https://github.com/independo-gmbh/inderun/commit/a43d049509557d70d63f3f26325538655707e1c2))
* **providers:** run neural speech through ONNX Runtime with the Articulino pipeline ([#260](https://github.com/independo-gmbh/inderun/issues/260)) ([270fbf2](https://github.com/independo-gmbh/inderun/commit/270fbf2dda62afe02743101901099b4aa19aa5c7))
* **routing:** match providers on per-task capabilities ([59c503d](https://github.com/independo-gmbh/inderun/commit/59c503d1a07c56ba9ab66aac2b5ccdb0d37af2d6)), closes [#243](https://github.com/independo-gmbh/inderun/issues/243)
* **routing:** project speech requests onto the planner and re-check the bound voice before each attempt ([902ae8b](https://github.com/independo-gmbh/inderun/commit/902ae8b871772a6467dc40fb7f2aedd17d82be3e))
* **sdk:** add speak, generateSpeech, listVoices and prepare ([65766e2](https://github.com/independo-gmbh/inderun/commit/65766e20cf7ccbe33e0c5bbad43e5ec9dd9d9e7b)), closes [#246](https://github.com/independo-gmbh/inderun/issues/246)
* **speech-text:** normalize English text for speech ([6c27eac](https://github.com/independo-gmbh/inderun/commit/6c27eac55a3a0e6ac6e0551837cbb896532b9021))
* **speech:** add neural speech benchmark reports and verification records ([#276](https://github.com/independo-gmbh/inderun/issues/276)) ([ec7fde4](https://github.com/independo-gmbh/inderun/commit/ec7fde401c2ba1d280438399b0248eb7d12126dd))
* **speech:** bound audio output waits, add close(), deflake tests, ship WASM release builds ([#280](https://github.com/independo-gmbh/inderun/issues/280)) ([ba275b5](https://github.com/independo-gmbh/inderun/commit/ba275b59acf49867ddd8de943dd31508819bf9d6))
* **speech:** normalize English text before neural synthesis ([17f9178](https://github.com/independo-gmbh/inderun/commit/17f9178651b708407e776b6f133c64417a5a111b))
* **speech:** run the exported Articulino Core AI asset and record the conversion ([#279](https://github.com/independo-gmbh/inderun/issues/279)) ([ddf2671](https://github.com/independo-gmbh/inderun/commit/ddf2671759c1e9da2a0a2f612caf474c50c20891))
* **speech:** validate real audio and report time to first word ([28c674b](https://github.com/independo-gmbh/inderun/commit/28c674be7077481f2c808815730d9114a8065d87)), closes [#251](https://github.com/independo-gmbh/inderun/issues/251)
* **web:** select provider runtimes with JSON descriptors ([#213](https://github.com/independo-gmbh/inderun/issues/213)) ([62a7838](https://github.com/independo-gmbh/inderun/commit/62a78388841360ccc2631605d303c4aa6799afa2))

### Bug Fixes 🛠️

* **android:** declare ACCESS_NETWORK_STATE in the system speech providers manifest ([e3532df](https://github.com/independo-gmbh/inderun/commit/e3532df10fd995169c79b00e121088086c8b70c2))
* **android:** drop core-ktx and document consumer host requirements ([#214](https://github.com/independo-gmbh/inderun/issues/214)) ([fcbac10](https://github.com/independo-gmbh/inderun/commit/fcbac10d7586c780c0e3df733f6568acc1d4db85))
* **onnx:** keep a session loaded during cancellation from leaking on Kotlin ([ac12c31](https://github.com/independo-gmbh/inderun/commit/ac12c31023a8abf405720fe74c6e8a613d9daeee))
* **onnx:** release the default text runtime with the provider's close() on Swift and Kotlin ([5a1614e](https://github.com/independo-gmbh/inderun/commit/5a1614ece7b661649c2c029b0e8ca98ce53396f4))
* **speech-text:** read German money with a decimal point, a dash or cents only ([033c23b](https://github.com/independo-gmbh/inderun/commit/033c23bd3dee6fe040a05853a47b9d7b4ad1d158))
* **speech:** let the Core AI factory's provider release the runtime it built ([ee73062](https://github.com/independo-gmbh/inderun/commit/ee73062ba8d574e5cc529670f7512b404018a8e0))
* **web:** declare the package side-effect free so the facade bundles alone ([6eaa3c7](https://github.com/independo-gmbh/inderun/commit/6eaa3c7a622b517fc1f42171b5aa91b25c4089ec))
* **web:** split neural speech sentences without a backtracking regex ([3c7e47c](https://github.com/independo-gmbh/inderun/commit/3c7e47c75573228a18a946890ec8aa910d4009b4)), closes [#12](https://github.com/independo-gmbh/inderun/issues/12)

### Documentation 📚

* **architecture:** record ADR 017 for media artifact transport and lifecycle ([3d63dd2](https://github.com/independo-gmbh/inderun/commit/3d63dd28e4d7a9041ffedcdfb9713529b69c2e9b))
* **ci:** correct Dependabot Swift coverage note ([0063e7d](https://github.com/independo-gmbh/inderun/commit/0063e7d2a82db640e3b87c712c657de4b8fd74b6))
* **contracts:** record ADR 016 for modality-extensible task contracts ([d07a90d](https://github.com/independo-gmbh/inderun/commit/d07a90d0a978706eaa94bb3db6ecb6f913215301)), closes [#245](https://github.com/independo-gmbh/inderun/issues/245) [#242](https://github.com/independo-gmbh/inderun/issues/242)
* **plans:** add v0.5.0 readiness plan ([deb992a](https://github.com/independo-gmbh/inderun/commit/deb992acd7cced09e198cf2de1dd602b827bb353))
* **speech:** record that Supertonic 3 is not integrated ([#277](https://github.com/independo-gmbh/inderun/issues/277)) ([0e1461e](https://github.com/independo-gmbh/inderun/commit/0e1461eb5f06b1ffee43f745bfff87c98ae86dfe)), closes [#289](https://github.com/independo-gmbh/inderun/issues/289)

### Miscellaneous Chores 🛠️

* credit the co-author of the M5 capability foundation ([6fda2c5](https://github.com/independo-gmbh/inderun/commit/6fda2c5967e9f04873d920ff50f395e4e9dfd5c4)), closes [#253](https://github.com/independo-gmbh/inderun/issues/253) [#242](https://github.com/independo-gmbh/inderun/issues/242) [#210](https://github.com/independo-gmbh/inderun/issues/210) [#243](https://github.com/independo-gmbh/inderun/issues/243)
* **deps-dev:** bump happy-dom from 20.14.6 to 21.0.4 ([ae6dc30](https://github.com/independo-gmbh/inderun/commit/ae6dc303f63f179fdfd1c2bc815e631f7d92ee90))
* **deps-dev:** bump the npm-routine group across 1 directory with 4 updates ([5df4336](https://github.com/independo-gmbh/inderun/commit/5df43362924d969e9e63214bd1e2085b2dfb160a))
* **deps-dev:** bump vitest ([7efdfc4](https://github.com/independo-gmbh/inderun/commit/7efdfc4d7884b5dc8e10a6e089074e674dbcca55))
* **deps:** bump com.diffplug.spotless ([0df5af6](https://github.com/independo-gmbh/inderun/commit/0df5af62168aad91c1befbc80ba04e576a1f832a))
* **deps:** bump com.google.mlkit:genai-common in /android ([4aa35ed](https://github.com/independo-gmbh/inderun/commit/4aa35edbf8f299e4c59265d92f0c119f443cfc42))
* **deps:** bump com.google.mlkit:genai-prompt in /android ([62e90f5](https://github.com/independo-gmbh/inderun/commit/62e90f50dc1fd81de884365828ebde4660599fe5))
* **deps:** bump serde_json ([2a51883](https://github.com/independo-gmbh/inderun/commit/2a51883d5f7a431a8649459f7a0f6b73cbb422f2))
* **deps:** bump the github-actions-routine group across 1 directory with 4 updates ([6a0ef6b](https://github.com/independo-gmbh/inderun/commit/6a0ef6b7f80eec30491ed44bf37ee8043c7ccfa6))
* **deps:** bump the gradle-routine group across 1 directory with 4 updates ([7ba1270](https://github.com/independo-gmbh/inderun/commit/7ba12701aa7484a454395d9b709d6e5391bb99f1))
* **deps:** bump the gradle-routine group in /android with 4 updates ([8b65952](https://github.com/independo-gmbh/inderun/commit/8b6595252da8760c906f659ff0733b0abcc8397a))
* **deps:** bump the npm-routine group across 1 directory with 5 updates ([5618437](https://github.com/independo-gmbh/inderun/commit/5618437e43a2efd3eb51ac53975db68cd555bf68))
* **deps:** bump wasm-bindgen ([8a2d0ba](https://github.com/independo-gmbh/inderun/commit/8a2d0bae0d9319c8a469ce4cf8261c52f172f6bb))
* **deps:** patch vulnerable undici and fast-uri ([8bc8011](https://github.com/independo-gmbh/inderun/commit/8bc80110ac106d1c2e7d1ee78a06b4fe20f34296))
* **deps:** rebuild the Apple route core for the dependency bump ([641459c](https://github.com/independo-gmbh/inderun/commit/641459cd29a913847ff07425b5dad4bd7449488d))
* **deps:** update swift-transformers and swift-huggingface ([62cceab](https://github.com/independo-gmbh/inderun/commit/62cceab4a2fe4248cd59dad07ebc62bf2acea7b2)), closes [huggingface/swift-huggingface#62](https://github.com/huggingface/swift-huggingface/issues/62)
* get dev ready for v0.5.0 ([#213](https://github.com/independo-gmbh/inderun/issues/213), [#214](https://github.com/independo-gmbh/inderun/issues/214), English speech text, [#276](https://github.com/independo-gmbh/inderun/issues/276)) ([#296](https://github.com/independo-gmbh/inderun/issues/296)) ([c093dbc](https://github.com/independo-gmbh/inderun/commit/c093dbc189839967c65ffeffa4aa9c969eea3a06))
* **website:** decode entities once and strip tags fully in the docs checks ([5cc82ce](https://github.com/independo-gmbh/inderun/commit/5cc82ce37666f68b4d87238c2de2bb00b70ddc57))
* **website:** launch inderun.dev with a single-source documentation architecture ([#292](https://github.com/independo-gmbh/inderun/issues/292)) ([b4fbc88](https://github.com/independo-gmbh/inderun/commit/b4fbc88ac054188592954bb7ae772920c3bac4ab))

### Tests 🛠️

* **android:** record Pixel 9 Pro speech benchmarks and fix the package loader's variant ([#276](https://github.com/independo-gmbh/inderun/issues/276)) ([e9e57ae](https://github.com/independo-gmbh/inderun/commit/e9e57aeea5bc76a147c81ba7def635ce0fbec050))
* **web:** freeze the clock in the system speech engine test ([fa228d8](https://github.com/independo-gmbh/inderun/commit/fa228d825292a884a5d8ece368696e2fe82b35ba))

### CI/CD 👷

* filter SwiftPM dependency findings from CodeQL ([bd9a12b](https://github.com/independo-gmbh/inderun/commit/bd9a12b8cb9c3848ef80a9a71a4aa8638a3d0893))
* **swift:** run the Swift checks as parallel jobs ([1f13b70](https://github.com/independo-gmbh/inderun/commit/1f13b703eb8ce69ae23285d04faa2a82e38e0d4c))

## [0.4.0](https://github.com/independo-gmbh/inderun/compare/v0.3.3...v0.4.0) (2026-10-21)

### ⚠ BREAKING CHANGES

* **web:** @independo/inderun-web no longer exports provider-authoring
APIs from its root. Import ProviderAdapter, ProviderDescriptor,
ProviderDynamicCapabilities, RunContext, ProviderStreamContext,
ProviderStreamEvent, ProviderRegistry, HostServices and the host-service
interfaces, createBrowserHostServices and the browser host services, and
the create* error constructors (with IndeRunExceptionParams) from
@independo/inderun-web/provider. Router, RouteSelection, RoutePlanner,
WasmRoutePlanner, PlannerOutcome, WasmUnavailableReason,
SharedPlannerInput, SharedPlannerRoutePlan and EventGate are no longer
exported. See docs/migration.md.
* **contracts:** the provider-authoring stream `done` event gains a
`reportedModel` field. Swift pattern matches on
`ProviderStreamEvent.done` must bind four values. The Swift and Kotlin
StreamTerminalOutcome builders (`completed`/`failed`/`cancelled`,
`completedOutcome`/`errorOutcome`/`cancelledOutcome`) take a required
`provenance` argument. The generated Swift memberwise initializers of
TaskResult, IndeRunError and StreamTerminalOutcome gain a
`provenance` parameter.
* **routing:** the OpenAI-compatible factories (createIndeRunWeb
`openAI`, Swift and Kotlin makeOpenAIRegistry) take `models` instead
of `model` and register target ids `<id>:<model>`. The Web IndeRun
constructor's third argument is now an options object
`{ telemetryService?, modelProfiles? }`.

### Features 🚀

* **contracts:** add normalized execution provenance ([5f4b458](https://github.com/independo-gmbh/inderun/commit/5f4b458007898a077a6f1d305b326f6176331ae3)), closes [#184](https://github.com/independo-gmbh/inderun/issues/184)
* **providers:** accept OpenRouter's Responses dialect in the OpenAI-compatible provider ([d2fdaed](https://github.com/independo-gmbh/inderun/commit/d2fdaed48a930c1fa158027cdb84ed94072d9190)), closes [#186](https://github.com/independo-gmbh/inderun/issues/186)
* **routing:** add model profiles and model-bound targets ([ee15f97](https://github.com/independo-gmbh/inderun/commit/ee15f9729b43f6539d7a049756323df1f715535f)), closes [#238](https://github.com/independo-gmbh/inderun/issues/238)
* **sdk:** add generateText/streamText facade over IndeRunApi ([d64c743](https://github.com/independo-gmbh/inderun/commit/d64c743964d9e17a0dcede1729d48cc8722fb372)), closes [#183](https://github.com/independo-gmbh/inderun/issues/183)
* **web:** split the Web SDK into application and provider entry points ([08e1e5f](https://github.com/independo-gmbh/inderun/commit/08e1e5f132b436a4167f6c4edae33296c490f04d)), closes [#187](https://github.com/independo-gmbh/inderun/issues/187)

### Documentation 📚

* **architecture:** define public API layering and compatibility contract ([ccd61b6](https://github.com/independo-gmbh/inderun/commit/ccd61b6b4dbcc7e818cc14c00d7f6ea63b9d4e2e)), closes [#182](https://github.com/independo-gmbh/inderun/issues/182)

### CI/CD 👷

* make the Swift API guard advisory for announced breaks ([5dd697e](https://github.com/independo-gmbh/inderun/commit/5dd697e3963ba042c1d79e5359317abde6e33699))

## [0.3.3](https://github.com/independo-gmbh/inderun/compare/v0.3.2...v0.3.3) (2026-10-20)

### Bug Fixes 🛠️

* **deps:** patch sharp, handlebars and stream-json advisories ([49d1f98](https://github.com/independo-gmbh/inderun/commit/49d1f9841c59ea668e90723cf10b44c48f475031))

### Miscellaneous Chores 🛠️

* **deps-dev:** bump the npm-routine group with 7 updates ([01bd92f](https://github.com/independo-gmbh/inderun/commit/01bd92fd5d56cffb509bf8c091bd51d18d84f6ae))
* **deps:** bump serde_json ([2581218](https://github.com/independo-gmbh/inderun/commit/25812182e7f900cad751fe71dfb59e990c48bd17))
* **deps:** bump the github-actions-routine group with 3 updates ([d27d726](https://github.com/independo-gmbh/inderun/commit/d27d726cdc4042d56e6aab9e26a9326aabf99907))
* **deps:** bump the gradle-routine group in /android with 4 updates ([b29059a](https://github.com/independo-gmbh/inderun/commit/b29059a409fce88254687a0e390fb1660dd3c6c0))
* **deps:** bump the npm-routine group with 6 updates ([4acf5fe](https://github.com/independo-gmbh/inderun/commit/4acf5fed45a2ecf73d0d569148e92cbb89be5044))
* **deps:** rebuild the Apple route core for the dependency bump ([0bd435e](https://github.com/independo-gmbh/inderun/commit/0bd435ea960a56ac22785a70d7f0e535c492088d))

## [0.3.2](https://github.com/independo-gmbh/inderun/compare/v0.3.1...v0.3.2) (2026-10-04)

### Bug Fixes 🛠️

* **deps:** restore rolldown native bindings in lockfile ([#228](https://github.com/independo-gmbh/inderun/issues/228)) ([71aa9f5](https://github.com/independo-gmbh/inderun/commit/71aa9f5a66019441d519958d56a629a3e298a6a7))

### Miscellaneous Chores 🛠️

* **deps-dev:** bump the npm-routine group with 5 updates ([0a83076](https://github.com/independo-gmbh/inderun/commit/0a83076e0aa92ce9c688d3d72088fad19f79c02c))
* **deps:** bump the github-actions-routine group with 2 updates ([8d022da](https://github.com/independo-gmbh/inderun/commit/8d022dab439bf7e566eb674bec9e1bf4526b8eda))
* **deps:** bump the gradle-routine group in /android with 4 updates ([a341d59](https://github.com/independo-gmbh/inderun/commit/a341d594150ecef23c2026e749056db37772c651))
* **deps:** bump wasm-bindgen ([285db2e](https://github.com/independo-gmbh/inderun/commit/285db2e3f59300cd3a5372e45ec79f99e8ab44d9))
* **deps:** rebuild the Apple route core for the dependency bump ([c9d2ea0](https://github.com/independo-gmbh/inderun/commit/c9d2ea007161d0fa1d21d9e468b629e72e4006dd))
* **deps:** upgrade dependencies ([94b0e46](https://github.com/independo-gmbh/inderun/commit/94b0e46eefd638c7d0e5599341248b96fcb04f82))

### CI/CD 👷

* **release:** cut prereleases as -rc.N so Maven ranks them below releases ([#229](https://github.com/independo-gmbh/inderun/issues/229)) ([2428616](https://github.com/independo-gmbh/inderun/commit/2428616a1351809df33eff0c788a996dd4c10bac))

## [0.3.1](https://github.com/independo-gmbh/inderun/compare/v0.3.0...v0.3.1) (2026-09-30)

### Bug Fixes 🛠️

* **contracts:** give every generated Kotlin enum its schema wire value ([#221](https://github.com/independo-gmbh/inderun/issues/221)) ([dfe50fc](https://github.com/independo-gmbh/inderun/commit/dfe50fcd0bea3a305b3f233482622a55d6c97fe6)), closes [#212](https://github.com/independo-gmbh/inderun/issues/212)

### Documentation 📚

* track both non-streaming provider families in the provider matrix ([#217](https://github.com/independo-gmbh/inderun/issues/217)) ([90e795d](https://github.com/independo-gmbh/inderun/commit/90e795d0aa4b1e79c37f3d44d1e2866bcc52063b)), closes [#146](https://github.com/independo-gmbh/inderun/issues/146)

### Miscellaneous Chores 🛠️

* **deps-dev:** bump vitest from 4.1.11 to 5.0.0 ([#194](https://github.com/independo-gmbh/inderun/issues/194)) ([8ea36a8](https://github.com/independo-gmbh/inderun/commit/8ea36a88bdae930c43d0e7a38a573e372b5e3195))
* **deps:** bump com.microsoft.onnxruntime:onnxruntime-android ([28cf5d3](https://github.com/independo-gmbh/inderun/commit/28cf5d30337175619f94a8810bd8f47121a62c6f))
* **deps:** bump the github-actions-routine group across 1 directory with 4 updates ([#196](https://github.com/independo-gmbh/inderun/issues/196)) ([c5dfb7d](https://github.com/independo-gmbh/inderun/commit/c5dfb7db5d1684533dd5896e17f6a7f4d1a6459f))
* **deps:** bump the github-actions-routine group with 2 updates ([0f9c104](https://github.com/independo-gmbh/inderun/commit/0f9c104c550e9d908776da06a1a6cb1bbb7e9f9b))
* **deps:** bump the gradle-routine group across 1 directory with 6 updates ([#195](https://github.com/independo-gmbh/inderun/issues/195)) ([ead6b11](https://github.com/independo-gmbh/inderun/commit/ead6b1102e4b871b82ee3b07b7eb8cf5c8561d1d))
* **deps:** bump the npm-routine group with 5 updates ([0e08511](https://github.com/independo-gmbh/inderun/commit/0e08511262c898b91979568b47d5b1003f350173))
* **deps:** bump wasm-bindgen in the cargo-routine group ([519c793](https://github.com/independo-gmbh/inderun/commit/519c793b3eed69200d127bac9b391f0eaece1d34))
* **deps:** rebuild the Apple route core for the dependency bump ([5df8f4f](https://github.com/independo-gmbh/inderun/commit/5df8f4f38c46dd04b958f9602020af0d92a2b9a9))
* **deps:** upgrade dependencies ([d79ded7](https://github.com/independo-gmbh/inderun/commit/d79ded76cb1ba66323a5d92e04732dc158155c9a))

### CI/CD 👷

* derive the wasm-bindgen CLI version from Cargo.lock ([d716a5f](https://github.com/independo-gmbh/inderun/commit/d716a5f64d7925726b9084574bd29300c9513541)), closes [#192](https://github.com/independo-gmbh/inderun/issues/192)

## [0.3.0](https://github.com/independo-gmbh/inderun/compare/v0.2.2...v0.3.0) (2026-09-20)

### ⚠ BREAKING CHANGES

* **android:** `AndroidMlKitGenAiRuntime` gained `generateTextStream` and
`generateText` now returns `AndroidMlKitGenAiOutput` instead of `String`, so a
custom implementation of that seam no longer compiles. The runtime-injecting
`AndroidMlKitGenAiProvider` constructor is now public rather than internal,
matching `AndroidOnnxRuntimeProvider`. ML Kit failures that previously all
surfaced as `Internal` in Mode 1 now classify by `GenAiException.errorCode`, so
a busy runtime reports `RateLimited`, an incompatible device reports
`CapabilityMismatch`, and a policy rejection reports `CapabilityMismatch` while
retracting any content already streamed. A stream consumer must now handle
`content_snapshot` even from a provider whose declared `streamingStyle` is
`tokens` or `chunks`, because that is how content retraction is delivered.
* **web:** `RouteSelection` no longer has a `plannerSource` field, and the
`route_decided` telemetry payload no longer carries `plannerSource` or
`plannerUnavailableReason`. Consumers reading either key from that payload were
reading a constant.
* **android:** Android routing no longer falls back to a second planner.
A route request whose plan cannot be produced now fails with an `Internal`
error instead of being routed by different rules, and `localRequired` no
longer admits a cloud provider anywhere in the fallback chain. Provider
selection may differ where the mirror ignored `preferences.optimizeFor`.
Building the Android SDK now requires Node and `rustup`; assembling an AAR
additionally requires the Android NDK.
* **ios:** RoutePlanning.planRoute is now throwing and returns a
non-optional RoutePlan; returning nil to signal "fall back" no longer has
a meaning. Routing fails with an Internal error carrying
plannerUnavailableReason when the shared core cannot produce a plan,
where it previously fell back to in-process Swift route selection, so
provider selection and failure summaries now match the Rust core's
semantics rather than the Swift restatement's.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Jy43ekX3icyfF98cbDPtfP
* **web:** PlannerOutcome no longer has a `source` field — a null
`routePlan` is the unavailable signal. RouteSelection.plannerSource is
narrowed to "wasm" and no longer carries plannerUnavailableReason; the
route_decided telemetry payload keeps both keys, with
plannerUnavailableReason always null. Routing now fails with an Internal
error when the WASM route core cannot be loaded, where it previously fell
back to in-process TypeScript route selection.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Jy43ekX3icyfF98cbDPtfP

### Features 🚀

* **android:** stream Mode 2 from ML Kit GenAI ([56c1846](https://github.com/independo-gmbh/inderun/commit/56c1846d4e121e307816519f2a2116a4d7e9372b))
* **contracts:** add canonical Mode 2 streaming contracts ([#145](https://github.com/independo-gmbh/inderun/issues/145)) ([017c1ca](https://github.com/independo-gmbh/inderun/commit/017c1ca51948642d2fb9aeab3f184a655c053ec7))
* **engine:** add Mode 2 streaming orchestrator, Event Gate, cancellation semantics ([#148](https://github.com/independo-gmbh/inderun/issues/148)) ([76454e8](https://github.com/independo-gmbh/inderun/commit/76454e8d7bffc1ac41c5fed46e86b0592e3010b6))
* **ios:** stream Mode 2 from Apple Foundation Models ([2e76a21](https://github.com/independo-gmbh/inderun/commit/2e76a21f590c4194eadb3c72f1109e2a37359abc))
* OpenAI-compatible streaming parity across Web, iOS, and Android ([#165](https://github.com/independo-gmbh/inderun/issues/165)) ([e0dc51e](https://github.com/independo-gmbh/inderun/commit/e0dc51e9781eb4d201ed44387ed2543d46ecc36f))
* **routing:** make interaction mode a routing input ([#163](https://github.com/independo-gmbh/inderun/issues/163)) ([dc282ee](https://github.com/independo-gmbh/inderun/commit/dc282eefefca4d3e9e969594a738e5367eefb4a1)), closes [152/#153](https://github.com/152/inderun/issues/153) [#150](https://github.com/independo-gmbh/inderun/issues/150)
* **web-demo:** add a diagnostic Mode 2 stream panel ([eb8eb2f](https://github.com/independo-gmbh/inderun/commit/eb8eb2f66294c900ac25788bdafda0bf9f5c78ec))

### Bug Fixes 🛠️

* **android:** keep coroutines off :inderun-kotlin's published API contract ([dae41d4](https://github.com/independo-gmbh/inderun/commit/dae41d4c3b3b8c981cb3c9fbe8443b96ebe2b829)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* **android:** put public-API dependencies on consumers' compile classpath ([154461b](https://github.com/independo-gmbh/inderun/commit/154461b27dd4e708b992680ecaf99abb47259748)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* **ci:** drop broken sdkmanager platform install in maven-publish ([#143](https://github.com/independo-gmbh/inderun/issues/143)) ([04caeb8](https://github.com/independo-gmbh/inderun/commit/04caeb84cb911db87f986d6d2ca0da32a7ed536d))
* **deps:** override typescript-json-schema to drop vulnerable vm2 transitive dep ([88a4935](https://github.com/independo-gmbh/inderun/commit/88a4935bf499e2c0987abb75cbd7d0844da2d7c5))
* **ios,android:** carry route-plan diagnostics on routing failures ([ae618b1](https://github.com/independo-gmbh/inderun/commit/ae618b17067c0c33ac0c82981a2c12d6a2b70bfd))
* **ios:** compile the re-export boundary in CI, not just the ABI ([00e3177](https://github.com/independo-gmbh/inderun/commit/00e31775ab3c33a886381493a3b3ab6451209157)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* **ios:** re-export the contract types the SDK's own API names ([09f4be7](https://github.com/independo-gmbh/inderun/commit/09f4be7d8b464d59010e4d5f6981461f00033eba)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* **web:** re-export the contract types the SDK's signatures use ([696bedf](https://github.com/independo-gmbh/inderun/commit/696bedf271d0fd0f0e6bddf77b44370668352f10)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)

### Documentation 📚

* add the canonical Mode 2 streaming guide ([aaf2e41](https://github.com/independo-gmbh/inderun/commit/aaf2e410c1545e4e4fc5bfb9069dc0a0b1785a34))
* correct planner references left stale by the mirror deletions ([70f4903](https://github.com/independo-gmbh/inderun/commit/70f490385d86bab09cfd1ae7bd9165f00efc8e52))
* correct the README's claim that streaming is unimplemented ([c3321ba](https://github.com/independo-gmbh/inderun/commit/c3321ba2c7a63ddb2eeb3b180a17403fa17952a2)), closes [#151](https://github.com/independo-gmbh/inderun/issues/151)
* describe the Capacitor bridge's Mode 2 behavior ([#198](https://github.com/independo-gmbh/inderun/issues/198)) ([f35f1c6](https://github.com/independo-gmbh/inderun/commit/f35f1c6029d33bb74b55f959c75185d480a93d3f)), closes [#149](https://github.com/independo-gmbh/inderun/issues/149)
* describe the published packages by what they do ([63eb979](https://github.com/independo-gmbh/inderun/commit/63eb97961455b3a9b159830a4135c12b1bca76dd))
* document Capacitor coverage and the Milestone 4 boundary ([ff90e54](https://github.com/independo-gmbh/inderun/commit/ff90e5438d3a2ef10f76fa590f70a7f1e0c7893c))
* document streaming conformance and manual validation ([434b9fd](https://github.com/independo-gmbh/inderun/commit/434b9fda28271d27170507fbf34428097a98f940))
* explain placement constraints and capability-based routing ([608a0e6](https://github.com/independo-gmbh/inderun/commit/608a0e6ab13743e45be91f7891f5512bb4ea9767))
* fold the per-SDK streaming prose into the streaming guide ([619e61f](https://github.com/independo-gmbh/inderun/commit/619e61fdaf66bdb06845059edd8cff8c6a1f004f)), closes [#154](https://github.com/independo-gmbh/inderun/issues/154)
* lead with on-device execution and cloud fallback ([124bf43](https://github.com/independo-gmbh/inderun/commit/124bf43d6d48b066517adc74acac611b7d2d7f6c))
* put BREAKING CHANGE last in commit messages ([#176](https://github.com/independo-gmbh/inderun/issues/176)) ([58b393b](https://github.com/independo-gmbh/inderun/commit/58b393b065fc3f31d5dab23c938bf7a5d0340eb3))
* record the packaging-parity rule and the new commands ([6c13250](https://github.com/independo-gmbh/inderun/commit/6c13250a05d38f2e4791a125dde230e83806048f)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* separate authContextRef from shipping a developer-owned key ([e517f6b](https://github.com/independo-gmbh/inderun/commit/e517f6bb2e99d3333600a914264f55aefd63e73c))
* separate Swift products from Swift imports ([36d65cc](https://github.com/independo-gmbh/inderun/commit/36d65cc0cb63ab56c0a462260d2ebac9e4341103)), closes [#191](https://github.com/independo-gmbh/inderun/issues/191) [#189](https://github.com/independo-gmbh/inderun/issues/189)
* **web:** document the published TypeScript entry points with TSDoc ([4c94740](https://github.com/independo-gmbh/inderun/commit/4c94740b7ce89b2beecf0c62e9ea41c92539747b))

### Miscellaneous Chores 🛠️

* **deps-dev:** bump the npm-routine group with 2 updates ([c026232](https://github.com/independo-gmbh/inderun/commit/c026232f242e15e412a477539d3ad68c4771736d))
* **deps-dev:** bump the npm-routine group with 4 updates ([185a6a9](https://github.com/independo-gmbh/inderun/commit/185a6a9589214cbb7b68a590943cf28799f6ae3e))
* **deps-dev:** bump the npm-routine group with 4 updates ([0b3797f](https://github.com/independo-gmbh/inderun/commit/0b3797fa730fd9b1f4d13a6dccbdb135065e488b))
* **deps-dev:** bump the npm-routine group with 4 updates ([7d29ee2](https://github.com/independo-gmbh/inderun/commit/7d29ee2d8409b580627719ed74b5f3b2ff356d6e))
* **deps:** bump actions/setup-java from 5.7.0 to 6.0.0 ([9100e2b](https://github.com/independo-gmbh/inderun/commit/9100e2b8b6739087a3f758124cae4e0a87021b77))
* **deps:** bump com.microsoft.onnxruntime:onnxruntime-android ([2dc7140](https://github.com/independo-gmbh/inderun/commit/2dc7140c70ac84ef5c3d6606919f7984976f9ed3))
* **deps:** bump org.json:json from 20260719 to 20260814 in /android ([9c5dffb](https://github.com/independo-gmbh/inderun/commit/9c5dffba7a6808e05b41e353d053b12624c27329))
* **deps:** bump the cargo-routine group with 3 updates ([fadbd9a](https://github.com/independo-gmbh/inderun/commit/fadbd9aef95d256f4bf33c20bb8dfd81398e887e))
* **deps:** bump the github-actions-routine group with 2 updates ([f24adf9](https://github.com/independo-gmbh/inderun/commit/f24adf9f81cc51d3f8f48d290db3093d8024a595))
* **deps:** bump the github-actions-routine group with 2 updates ([df5477e](https://github.com/independo-gmbh/inderun/commit/df5477e921b8e3ab99dea9fac515b7fab90d0b38))
* **deps:** bump the github-actions-routine group with 2 updates ([dd4a753](https://github.com/independo-gmbh/inderun/commit/dd4a7533e71b0974795810fcba1c40d1ba47435f))
* **deps:** bump the gradle-routine group across 1 directory with 4 updates ([5aa7aba](https://github.com/independo-gmbh/inderun/commit/5aa7aba7b449839e2fa3c96ffa5bb58d5453ff43))
* **deps:** bump the gradle-routine group in /android with 3 updates ([2b47ed0](https://github.com/independo-gmbh/inderun/commit/2b47ed05bc05a2ec8b374adc6e1f9e6d38482721))
* **deps:** rebuild the Apple route core for the cargo bump ([9847cc9](https://github.com/independo-gmbh/inderun/commit/9847cc96ef47ea5b7428d4894750710beba551d5))
* **deps:** upgrade dependencies ([471b75d](https://github.com/independo-gmbh/inderun/commit/471b75d5323e51b30f42bbfcae4e374b93fcc88f))
* merge the 0.2.2 release commit back into dev ([d417f19](https://github.com/independo-gmbh/inderun/commit/d417f1965a0b2707d9b0ac2e820ef638abebae0a)), closes [#201](https://github.com/independo-gmbh/inderun/issues/201) [#202](https://github.com/independo-gmbh/inderun/issues/202)

### Code Refactors 🏗️

* **android:** route only through the shared Rust planner ([c552e64](https://github.com/independo-gmbh/inderun/commit/c552e6448fdd2cd2d47021c98517c71f6b94eeca))
* **ios:** route only through the shared Rust planner ([db9c157](https://github.com/independo-gmbh/inderun/commit/db9c157c144a0168e15720373d8dfcff63adcdb1)), closes [#171](https://github.com/independo-gmbh/inderun/issues/171)
* **web:** drop the planner fields left over from the two-planner design ([12053a5](https://github.com/independo-gmbh/inderun/commit/12053a5a1f7481a13f56ffba0fdc0dd137cff5f5))
* **web:** route only through the shared Rust planner ([6e85cda](https://github.com/independo-gmbh/inderun/commit/6e85cdaca00f1dffba67f720a14c1d10cdeff2f6)), closes [#171](https://github.com/independo-gmbh/inderun/issues/171) [#164](https://github.com/independo-gmbh/inderun/issues/164)

### Tests 🛠️

* add the shared Mode 2 engine conformance catalog ([b6f48b0](https://github.com/independo-gmbh/inderun/commit/b6f48b0ec82cae0305cf5bf50b5686db09e887a6))
* **android:** drive the engine conformance catalog ([2ec1e94](https://github.com/independo-gmbh/inderun/commit/2ec1e94b0cf896f5e39f646533b06db58b7f9e9f))
* **ios:** drive the engine conformance catalog ([1f7186b](https://github.com/independo-gmbh/inderun/commit/1f7186b7e22e0da02bb998dd034f1393277a714b))
* **js:** drive the engine conformance catalog ([5a9e8a5](https://github.com/independo-gmbh/inderun/commit/5a9e8a506d4786ea24dac09830aff2c6e71af626))
* **swift:** replace wall-clock streaming assertions with deterministic gates ([0cba58b](https://github.com/independo-gmbh/inderun/commit/0cba58b8354ed968fe12843dab84e9bd553e0fb1))
* **web:** stop the streaming-abort test racing its own fixture ([70da87c](https://github.com/independo-gmbh/inderun/commit/70da87cec8ebfa8bd1e23311f9e2c372cacbdd3d))

### CI/CD 👷

* bump setup-android to v4.0.4 for the removed tools package ([#199](https://github.com/independo-gmbh/inderun/issues/199)) ([ba1a5d6](https://github.com/independo-gmbh/inderun/commit/ba1a5d6873c4792864ef8a630050bfc5d95c8082))
* give the CodeQL Kotlin scan the toolchain its build needs ([#208](https://github.com/independo-gmbh/inderun/issues/208)) ([588f229](https://github.com/independo-gmbh/inderun/commit/588f229920b98663e9b08cbb92a71f0e44ded39b)), closes [#207](https://github.com/independo-gmbh/inderun/issues/207) [#204](https://github.com/independo-gmbh/inderun/issues/204) [#207](https://github.com/independo-gmbh/inderun/issues/207)
* guard public-API packaging on all three SDKs ([6d588b6](https://github.com/independo-gmbh/inderun/commit/6d588b6cfb01b5e5dbca14c27066d073ab5c2796)), closes [#189](https://github.com/independo-gmbh/inderun/issues/189)
* install the pinned Rust toolchain explicitly ([#175](https://github.com/independo-gmbh/inderun/issues/175)) ([ff82fa2](https://github.com/independo-gmbh/inderun/commit/ff82fa29c96500f77210bc7c4b9eb3178575bde0))
* install the pinned Rust toolchain in the CodeQL Kotlin job ([#209](https://github.com/independo-gmbh/inderun/issues/209)) ([99cd856](https://github.com/independo-gmbh/inderun/commit/99cd85648451a9f31746dd7367aab2cd039f8da5)), closes [#208](https://github.com/independo-gmbh/inderun/issues/208) [#208](https://github.com/independo-gmbh/inderun/issues/208)
* keep breaking changes at minor bumps while pre-1.0 ([07102e2](https://github.com/independo-gmbh/inderun/commit/07102e22aed8f5e1a87184c52d2548aa29ca474e))
* publish Android prereleases to Maven Central ([#197](https://github.com/independo-gmbh/inderun/issues/197)) ([cd9dbdf](https://github.com/independo-gmbh/inderun/commit/cd9dbdfaaabd54d25dbd86261b0801be52d94785)), closes [#149](https://github.com/independo-gmbh/inderun/issues/149)
* rebuild the Apple route core on Dependabot cargo PRs ([1821294](https://github.com/independo-gmbh/inderun/commit/1821294011c5ea7d0b8ceaaf3439507a506370ff))
* stop the Kotlin scan and the Swift API guard blocking releases ([#207](https://github.com/independo-gmbh/inderun/issues/207)) ([e33d3bb](https://github.com/independo-gmbh/inderun/commit/e33d3bb6eb4629663a98e00264a66642603da579)), closes [#204](https://github.com/independo-gmbh/inderun/issues/204) [#206](https://github.com/independo-gmbh/inderun/issues/206)

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
