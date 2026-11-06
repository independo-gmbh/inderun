import Foundation
import XCTest
@testable import IndeRunCore
@testable import IndeRunNeuralSpeech

/// Unit tests of `NeuralSpeechProvider` and its fixture runtime. Mirrors `provider.test.ts` and
/// `fixture-runtime.test.ts`; the cross-SDK lifecycle lives in
/// `NeuralSpeechLifecycleConformanceTests`.
final class NeuralSpeechProviderTests: XCTestCase {
    // MARK: - Descriptor

    func testNeuralSpeechDescribesAHardCancelInProcessSpeechProvider() throws {
        let provider = makeProvider()
        let descriptor = provider.describe()

        XCTAssertEqual(provider.id, "local.onnx.speech.apple:fixture-tts")
        XCTAssertEqual(descriptor.id, "local.onnx.speech.apple:fixture-tts")
        XCTAssertEqual(descriptor.type, .local)
        XCTAssertEqual(descriptor.model, "fixture-tts")
        XCTAssertEqual(descriptor.transport, .inProcess)
        XCTAssertTrue(descriptor.supports.run)
        XCTAssertTrue(descriptor.supports.streaming)
        XCTAssertFalse(descriptor.supports.realtime)
        XCTAssertFalse(descriptor.supports.tools)
        XCTAssertFalse(descriptor.supports.reasoningEvents)
        XCTAssertFalse(descriptor.supports.structuredOutput)
        XCTAssertFalse(descriptor.supports.multimodal)
        XCTAssertEqual(descriptor.cancel, .hard)
        XCTAssertEqual(descriptor.tasks, ["text_to_speech"])
        XCTAssertEqual(descriptor.privacy?.dataLeavesDevice, false)

        let capability = try XCTUnwrap(descriptor.taskCapabilities?.first)
        XCTAssertEqual(descriptor.taskCapabilities?.count, 1)
        XCTAssertEqual(capability.kind, "text_to_speech")
        XCTAssertEqual(capability.inputs, [.text])
        XCTAssertEqual(capability.interaction.prepare, true)
        XCTAssertEqual(capability.interaction.run, true)
        XCTAssertEqual(capability.interaction.stream, true)
        XCTAssertEqual(capability.cancel, .hard)
        XCTAssertEqual(capability.outputs.map(\.delivery), [.playback, .artifact])
        XCTAssertNil(capability.outputs[0].mediaTypes)
        XCTAssertEqual(capability.outputs[1].mediaTypes, ["audio/wav"])
        XCTAssertEqual(capability.locales, ["de-DE", "de-AT", "en-US"])
        XCTAssertEqual(capability.privacy?.dataLeavesDevice, false)
    }

    func testNeuralSpeechTakesAnExplicitId() {
        XCTAssertEqual(makeProvider(id: "speech").describe().id, "speech")
    }

    // MARK: - Capabilities and prepare

    func testNeuralSpeechCapabilityCheckNeverLoadsTheModelAndReportsItCold() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let provider = makeProvider(runtime: runtime)

        _ = await provider.capabilities(host: host)
        let capabilities = await provider.capabilities(host: host)

        XCTAssertEqual(runtime.prepareCalls, 0)
        XCTAssertTrue(capabilities.available)
        let task = try XCTUnwrap(capabilities.taskCapabilities?.first)
        XCTAssertEqual(task.kind, "text_to_speech")
        XCTAssertEqual(task.readiness, .cold)
        let voices = try XCTUnwrap(task.voices)
        XCTAssertEqual(voices.map(\.id), ["v_de", "v_at", "v_en"])
        XCTAssertEqual(voices.map(\.name), ["Fixture German", "Fixture Austrian", "Fixture English"])
        XCTAssertEqual(voices.map(\.locale), ["de-DE", "de-AT", "en-US"])
        XCTAssertEqual(voices.map(\.locales), [["de-DE", "de-AT"], ["de-AT"], ["en-US"]])
        XCTAssertEqual(voices.map(\.gender), [.female, nil, .male])
        XCTAssertEqual(voices.map(\.networkRequired), [false, false, false])
    }

    // swiftlint:disable:next line_length
    func testNeuralSpeechRefusesAMalformedPackageAPackageWithoutSpeechAnUnsupportedSourceTypeAnUnsupportedPlatformAndWhatTheRuntimeRefuses() async throws {
        let cases: [(json: String, runtime: FixtureNeuralSpeechRuntimeOptions?, reason: String)] = [
            (packageJSON(voices: [germanVoice, germanVoice]), nil, "model package malformed:"),
            (#"{"id": "text-only", "format": "onnx", "tasks": ["text_to_text"]}"#, nil, "unsupported task:"),
            (packageJSON(source: #"{"sourceType": "registry", "ref": "tts"}"#), nil, "model source unavailable:"),
            (packageJSON(runtime: #"{"platforms": ["web", "android"]}"#), nil, "platform unsupported:"),
            (packageJSON(channels: 2), nil, "unsupported channels: 2"),
            (
                packageJSON(),
                FixtureNeuralSpeechRuntimeOptions(
                    availability: NeuralSpeechAvailability(available: false, reason: "unsupported pipeline: kokoro")
                ),
                "unsupported pipeline: kokoro"
            )
        ]

        for entry in cases {
            let runtime = FixtureNeuralSpeechRuntime(options: entry.runtime ?? FixtureNeuralSpeechRuntimeOptions())
            let provider = NeuralSpeechProvider(
                options: NeuralSpeechProviderOptions(modelPackage: try decodePackage(entry.json), runtime: runtime)
            )
            let capabilities = await provider.capabilities(host: host)
            XCTAssertFalse(capabilities.available, entry.reason)
            if entry.runtime == nil {
                XCTAssertTrue(capabilities.reason?.hasPrefix(entry.reason) == true, capabilities.reason ?? "no reason")
            } else {
                XCTAssertEqual(capabilities.reason, entry.reason)
            }
        }
    }

    func testNeuralSpeechAcceptsTheFilesystemSourceAndTheApplePlatform() async throws {
        let provider = NeuralSpeechProvider(
            options: NeuralSpeechProviderOptions(
                modelPackage: try decodePackage(
                    packageJSON(source: #"{"sourceType": "filesystem", "ref": "/models/tts"}"#, runtime: #"{"platforms": ["apple"]}"#)
                ),
                runtime: FixtureNeuralSpeechRuntime()
            )
        )
        let capabilities = await provider.capabilities(host: host)
        XCTAssertTrue(capabilities.available, capabilities.reason ?? "")
    }

    func testNeuralSpeechRemembersALoadFailure() async throws {
        let runtime = FixtureNeuralSpeechRuntime(
            options: FixtureNeuralSpeechRuntimeOptions(
                prepareResult: NeuralSpeechAvailability(available: false, reason: "graph missing")
            )
        )
        let provider = makeProvider(runtime: runtime)

        do {
            try await drainPreparation(provider)
            XCTFail("prepare finished although the model failed to load")
        } catch let error as IndeRunException {
            XCTAssertEqual(error.errorClass, .CapabilityMismatch)
        }

        let capabilities = await provider.capabilities(host: host)
        XCTAssertFalse(capabilities.available)
        XCTAssertEqual(capabilities.reason, "graph missing")
        XCTAssertNil(capabilities.taskCapabilities)
        XCTAssertEqual(runtime.prepareCalls, 1)
    }

    func testNeuralSpeechReportsReadinessAbsentOncePrepared() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let provider = makeProvider(runtime: runtime)

        try await drainPreparation(provider)

        let capabilities = await provider.capabilities(host: host)
        XCTAssertEqual(runtime.prepareCalls, 1)
        XCTAssertTrue(capabilities.available)
        XCTAssertNil(capabilities.taskCapabilities?.first?.readiness)
        XCTAssertEqual(capabilities.taskCapabilities?.first?.voices?.count, 3)
    }

    func testNeuralSpeechReportsTheRuntimeNotPreparedHintUntilLoaded() async throws {
        let runtime = FixtureNeuralSpeechRuntime(
            options: FixtureNeuralSpeechRuntimeOptions(
                availability: NeuralSpeechAvailability(available: true, readiness: .notPrepared)
            )
        )
        let provider = makeProvider(runtime: runtime)

        let before = await provider.capabilities(host: host)
        let task = try XCTUnwrap(before.taskCapabilities?.first)
        XCTAssertEqual(task.readiness, .notPrepared)
        XCTAssertEqual(task.voices?.map(\.readiness), [.notPrepared, .notPrepared, .notPrepared])

        try await drainPreparation(provider)

        let after = await provider.capabilities(host: host)
        XCTAssertNil(after.taskCapabilities?.first?.readiness)
        XCTAssertEqual(after.taskCapabilities?.first?.voices?.map(\.readiness), [nil, nil, nil])
    }

    func testNeuralSpeechReportsAnExplicitColdHintOnTheVoices() async throws {
        let runtime = FixtureNeuralSpeechRuntime(
            options: FixtureNeuralSpeechRuntimeOptions(availability: NeuralSpeechAvailability(available: true, readiness: .cold))
        )
        let capabilities = await makeProvider(runtime: runtime).capabilities(host: host)
        let task = try XCTUnwrap(capabilities.taskCapabilities?.first)
        XCTAssertEqual(task.readiness, .cold)
        XCTAssertEqual(task.voices?.map(\.readiness), [.cold, .cold, .cold])
    }

    func testNeuralSpeechIgnoresTheHintOfAnUnavailableRuntime() async throws {
        let runtime = FixtureNeuralSpeechRuntime(
            options: FixtureNeuralSpeechRuntimeOptions(
                availability: NeuralSpeechAvailability(available: false, reason: "no model", readiness: .notPrepared)
            )
        )
        let capabilities = await makeProvider(runtime: runtime).capabilities(host: host)
        XCTAssertFalse(capabilities.available)
        XCTAssertEqual(capabilities.reason, "no model")
        XCTAssertNil(capabilities.taskCapabilities?.first?.readiness)
    }

    func testNeuralSpeechLeavesVoiceReadinessAbsentWithoutAHint() async throws {
        let provider = makeProvider()
        let capabilities = await provider.capabilities(host: host)
        let task = try XCTUnwrap(capabilities.taskCapabilities?.first)
        XCTAssertEqual(task.readiness, .cold)
        XCTAssertEqual(task.voices?.map(\.readiness), [nil, nil, nil])
    }

    // MARK: - Runs

    func testNeuralSpeechRefusesAnInlineDeliveryAndANonSpeechRequestBeforeCommit() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let provider = makeProvider(runtime: runtime)
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let inline = await refusal {
            _ = try await provider.run(request: speechRequest(mode: .inline), context: context)
        }
        let text = await refusal {
            _ = try await provider.run(request: TaskRequest(prompt: "Hello"), context: context)
        }

        XCTAssertEqual(inline?.errorClass, .CapabilityMismatch)
        XCTAssertEqual(text?.errorClass, .CapabilityMismatch)
        XCTAssertEqual(commits.count, 0)
        XCTAssertEqual(audio.sessions.count, 0)
        XCTAssertEqual(runtime.synthesized.count, 0)
    }

    func testNeuralSpeechStopsTheSessionWhenCancelledWhileTheAudioDrains() async throws {
        let provider = makeProvider()
        let output = BlockingDrainAudioOutput()
        let commits = CommitCounter()
        let cancellation = StreamCancellationToken()
        let context = ProviderStreamContext(
            runId: "run-1",
            hostServices: hostWith(output),
            cancellation: cancellation,
            commit: commits.commit
        )

        let consumed = Task { () -> Int in
            var events = 0
            for try await _ in provider.stream(request: speechRequest(), context: context) {
                events += 1
            }
            return events
        }
        try await waitUntil(ms: 2000, "drain() started") { output.drainStarted }
        cancellation.cancel()
        let events = try await bounded(ms: 2000, "stream") { try await consumed.value }

        XCTAssertEqual(commits.count, 1)
        XCTAssertGreaterThan(output.stops, 0)
        XCTAssertEqual(events, 0)
    }

    func testNeuralSpeechTimesOutBeforeCommitWhenTheFirstChunkIsSlowerThanTheTimeout() async throws {
        let provider = makeProvider(
            runtime: FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(delayMs: 2000)),
            timeout: .milliseconds(20)
        )
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let error = await refusal {
            _ = try await provider.run(request: speechRequest(), context: context)
        }

        XCTAssertEqual(error?.errorClass, .Timeout)
        XCTAssertEqual(commits.count, 0)
        XCTAssertEqual(audio.sessions.first?.stopped, true)
        XCTAssertEqual(audio.sessions.first?.writtenFrames, 0)
    }

    func testNeuralSpeechDoesNotTimeOutASlowSentenceAfterCommit() async throws {
        let provider = makeProvider(runtime: PacedRuntime { sentence in sentence == 2 ? 400 : 0 })
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let result = try await provider.run(
            request: speechRequest(text: "Hallo Welt. Wie geht es dir?", timeoutMs: 200),
            context: context
        )

        XCTAssertNotNil(result.output.playback)
        XCTAssertEqual(commits.count, 1)
        // 27 characters across the two sentences: 1350 ms.
        XCTAssertEqual(audio.sessions.first?.writtenFrames, 32400)
    }

    func testNeuralSpeechBoundsAnArtifactsWholeSynthesisWithTheTimeout() async throws {
        // Each sentence alone fits the budget; both together do not.
        let provider = makeProvider(runtime: PacedRuntime { _ in 150 })
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: host, commit: commits.commit)

        let error = await refusal {
            _ = try await provider.run(
                request: speechRequest(mode: .artifact, text: "Hallo Welt. Wie geht es dir?", timeoutMs: 200),
                context: context
            )
        }

        XCTAssertEqual(error?.errorClass, .Timeout)
        XCTAssertEqual(commits.count, 0)
    }

    func testNeuralSpeechTreatsATimeoutOfZeroOrLessAsUnbounded() async throws {
        let provider = makeProvider(
            runtime: FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(delayMs: 5)),
            timeout: .zero
        )
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let result = try await provider.run(request: speechRequest(), context: context)

        XCTAssertNotNil(result.output.playback)
        XCTAssertEqual(commits.count, 1)
    }

    func testNeuralSpeechOpensNoSessionForAWaiterCancelledAsItIsHandedTheTurn() async throws {
        let provider = makeProvider(
            runtime: FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(delayMs: 5))
        )
        let audio = StopHookAudioOutput()
        let host = hostWith(audio)
        let first = Task {
            try await provider.run(request: speechRequest(), context: RunContext(runId: "run-a", hostServices: host, commit: { true }))
        }
        try await waitUntil(ms: 2000, "A's first write") { (audio.fixture.sessions.first?.writes.count ?? 0) > 0 }
        let second = Task {
            try await provider.run(request: speechRequest(), context: RunContext(runId: "run-b", hostServices: host, commit: { true }))
        }
        // B queues for the turn while A plays. A's stop, just before A hands the turn over, cancels
        // B while the cooperative pool is busy for a moment, so the hand-over resumes B before the
        // cancellation's clean-up can take B out of the queue.
        try await Task.sleep(nanoseconds: 20_000_000)
        audio.onFirstStop {
            for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount {
                Task {
                    let end = Date().addingTimeInterval(0.05)
                    while Date() < end {}
                }
            }
            second.cancel()
        }

        _ = try await bounded(ms: 2000, "A") { try await first.value }
        let ended = await bounded(ms: 2000) { await second.result }
        let secondResult = try XCTUnwrap(ended, "B did not end")

        XCTAssertThrowsError(try secondResult.get())
        XCTAssertEqual(audio.opens, 1)
    }

    func testNeuralSpeechRefusesAChunkAtAnotherSampleRate() async throws {
        let provider = makeProvider(runtime: WrongRateRuntime())
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let error = await refusal {
            _ = try await provider.run(request: speechRequest(), context: context)
        }

        XCTAssertEqual(error?.errorClass, .Internal)
        XCTAssertEqual(commits.count, 0)
        XCTAssertEqual(audio.sessions.first?.writtenFrames, 0)
        XCTAssertEqual(audio.sessions.first?.stopped, true)
    }

    func testNeuralSpeechThrowsARuntimeFailureAfterCommitAndStopsTheSession() async throws {
        let provider = makeProvider(
            runtime: FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(failAfterChunks: 2))
        )
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let error = await refusal {
            _ = try await provider.run(request: speechRequest(), context: context)
        }

        XCTAssertEqual(error?.errorClass, .Internal)
        XCTAssertEqual(error?.message, "fixture synthesis failed")
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(audio.sessions.first?.writes.count, 2)
        XCTAssertEqual(audio.sessions.first?.stopped, true)
    }

    func testNeuralSpeechWritesAnArtifactWithoutAnAudioOutput() async throws {
        let provider = makeProvider()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: host, commit: commits.commit)

        let result = try await provider.run(request: speechRequest(mode: .artifact), context: context)

        let artifact = try XCTUnwrap(result.output.artifact)
        XCTAssertEqual(artifact.mediaType, "audio/wav")
        // "Hallo Welt." is 11 characters: 550 ms at 24000 Hz.
        XCTAssertEqual(artifact.byteLength, SpeechWAV.headerBytes + 2 * 13200)
        XCTAssertEqual(try XCTUnwrap(artifact.durationMs), 550, accuracy: 1e-9)
        XCTAssertEqual(result.output.speech?.locale, "de-AT")
        XCTAssertEqual(result.output.speech?.voice?.id, "v_de")
        XCTAssertEqual(commits.count, 1)
    }

    func testNeuralSpeechCountsFirstAudioMsFromTheInstantBeforeOpenWasCalled() async throws {
        let provider = makeProvider()
        // The fixture session reports 0: its first write happens at once on its virtual clock.
        let audio = SlowOpenAudioOutput(delayMs: 200)
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: { true })

        let result = try await provider.run(request: speechRequest(), context: context)

        XCTAssertEqual(audio.fixture.sessions.first?.firstAudioMs(), 0)
        // The session measures from the start of its own open(), so the slow open is counted once,
        // by the session; counting from when open() returned would add it a second time.
        let firstAudioMs = try XCTUnwrap(result.output.playback?.timing?.firstAudioMs)
        XCTAssertLessThan(firstAudioMs, 200)
    }

    func testNeuralSpeechBoundsAnArtifactWithTheTimeoutUpToFinish() async throws {
        let provider = makeProvider(timeout: .milliseconds(500))
        let commits = CommitCounter()
        // Synthesis is instant, well inside the budget even on a loaded runner; writing the WAV takes
        // the run past its deadline.
        let artifacts = SpyArtifacts(ArtifactStore().attempt(commit: commits.commit)) {
            Thread.sleep(forTimeInterval: 0.6)
        }
        let context = RunContext(runId: "run-1", hostServices: host, artifacts: artifacts, commit: commits.commit)

        let error = await refusal {
            _ = try await provider.run(request: speechRequest(mode: .artifact), context: context)
        }

        XCTAssertEqual(error?.errorClass, .Timeout)
        XCTAssertEqual(artifacts.finishCalls, 0)
        XCTAssertEqual(artifacts.aborts, 1)
        XCTAssertEqual(commits.count, 0)
    }

    // MARK: - Fixture runtime

    func testFixtureRuntimeYieldsFourteenChunksOf2400FramesWithIsLastOnlyOnTheLast() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let chunks = try await collect(runtime.synthesize(input(twentyEightCharacters)))

        XCTAssertEqual(chunks.count, 14)
        XCTAssertTrue(chunks.allSatisfy { $0.samples.count == 2400 && $0.sampleRate == 24000 })
        XCTAssertEqual(chunks.map(\.isLast), Array(repeating: false, count: 13) + [true])
        XCTAssertEqual(runtime.synthesized.map(\.text), [twentyEightCharacters])
        XCTAssertEqual(runtime.synthesized.first?.voiceId, "v1")
    }

    func testFixtureRuntimeEmitsAPartialLastChunk() async throws {
        let runtime = FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(chunkMs: 1000))
        let chunks = try await collect(runtime.synthesize(input(twentyEightCharacters)))
        XCTAssertEqual(chunks.map(\.samples.count), [24000, 9600])
    }

    func testFixtureRuntimeKeepsTheSinePhaseContinuousAcrossChunks() async throws {
        let chunks = try await collect(FixtureNeuralSpeechRuntime().synthesize(input(twentyEightCharacters)))
        func sample(_ frame: Int) -> Int16 {
            Int16((0.2 * 32767 * sin(2 * Double.pi * 440 * Double(frame) / 24000)).rounded())
        }
        XCTAssertEqual(chunks[1].samples[0], sample(2400))
        XCTAssertEqual(chunks[1].samples[5], sample(2405))
    }

    func testFixtureRuntimeFailsAfterTheScriptedChunks() async throws {
        let runtime = FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(failAfterChunks: 2))
        var received = 0
        do {
            for try await _ in runtime.synthesize(input(twentyEightCharacters)) {
                received += 1
            }
            XCTFail("the iteration ended without the scripted failure")
        } catch let error as NeuralSpeechRuntimeError {
            XCTAssertEqual(error.kind, .internalFailure)
        }
        XCTAssertEqual(received, 2)
    }

    func testFixtureRuntimeEndsWithoutThrowingWhenTheConsumerIsCancelled() async throws {
        let runtime = FixtureNeuralSpeechRuntime(options: FixtureNeuralSpeechRuntimeOptions(delayMs: 20))
        let stream = runtime.synthesize(input(twentyEightCharacters))
        let consumer = Task { () -> Int in
            var received = 0
            for try await _ in stream {
                received += 1
                if received == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return received
        }
        let received = try await bounded(ms: 2000, "cancelled synthesis") { try await consumer.value }
        XCTAssertEqual(received, 1)
    }

    func testFixtureRuntimeCountsItsCalls() async {
        let runtime = FixtureNeuralSpeechRuntime()
        _ = await runtime.availability(package)
        _ = await runtime.availability(package)
        _ = await runtime.prepare(package)
        XCTAssertEqual(runtime.availabilityCalls, 2)
        XCTAssertEqual(runtime.prepareCalls, 1)
    }

    // MARK: - Text normalization hook

    func testNeuralSpeechNormalizesTheWholeTextOnceBeforeItIsSplitIntoSentences() async throws {
        let runtime = NormalizingRuntime { text, _ in SharedCoreSpeechText.normalize(text, locale: "de-DE") }
        let provider = makeProvider(runtime: runtime)
        let context = RunContext(runId: "run-1", hostServices: hostWith(FixtureAudioOutputService()), commit: { true })

        _ = try await provider.run(
            request: speechRequest(text: "Am 3. Mai, z. B. um 14:30 Uhr.", locale: "de-DE"),
            context: context
        )

        XCTAssertEqual(runtime.hookLocales, ["de-DE"])
        XCTAssertEqual(runtime.hookTexts, ["Am 3. Mai, z. B. um 14:30 Uhr."])
        XCTAssertEqual(runtime.fixture.synthesized.map(\.text), ["Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig."])
    }

    func testNeuralSpeechNormalizesAnArtifactRunToo() async throws {
        let runtime = NormalizingRuntime { text, _ in SharedCoreSpeechText.normalize(text, locale: "de-DE") }
        let provider = makeProvider(runtime: runtime)
        let context = RunContext(runId: "run-1", hostServices: host, commit: { true })

        _ = try await provider.run(
            request: speechRequest(mode: .artifact, text: "Am 3. Mai, z. B. um 14:30 Uhr.", locale: "de-DE"),
            context: context
        )

        XCTAssertEqual(runtime.fixture.synthesized.map(\.text), ["Am dritten Mai, zum Beispiel um vierzehn Uhr dreißig."])
    }

    func testNeuralSpeechPassesTheRequestsRegionalLocaleWhileTheVoiceSpeaksItsLanguage() async throws {
        let onlyGerman = try decodePackage(packageJSON(voices: [#"{"id": "v_de", "name": "German", "locales": ["de-DE"]}"#]))
        let runtime = NormalizingRuntime { text, locale in SharedCoreSpeechText.normalize(text, locale: locale) }
        let provider = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: onlyGerman, runtime: runtime))
        let context = RunContext(runId: "run-1", hostServices: hostWith(FixtureAudioOutputService()), commit: { true })

        _ = try await provider.run(request: speechRequest(text: "Am 3.1.2026.", locale: "de-AT"), context: context)

        XCTAssertEqual(runtime.hookLocales, ["de-AT"])
        XCTAssertEqual(runtime.fixture.synthesized.map(\.text), ["Am dritten Jänner zweitausendsechsundzwanzig."])
    }

    func testNeuralSpeechPassesTheVoicesLocaleWhenNoVoiceSharesTheRequestsLanguage() async throws {
        let onlyGerman = try decodePackage(
            packageJSON(voices: [#"{"id": "v_de", "name": "German", "locales": ["de-DE", "de-AT"]}"#])
        )
        let runtime = NormalizingRuntime { text, _ in text }
        let provider = NeuralSpeechProvider(options: NeuralSpeechProviderOptions(modelPackage: onlyGerman, runtime: runtime))
        let context = RunContext(runId: "run-1", hostServices: hostWith(FixtureAudioOutputService()), commit: { true })

        _ = try await provider.run(request: speechRequest(text: "Bonjour.", locale: "fr-FR"), context: context)

        XCTAssertEqual(runtime.hookLocales, ["de-DE"])
    }

    func testNeuralSpeechTakesTheCancellationPathWhenTheRunIsCancelledDuringTheHook() async throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let runtime = NormalizingRuntime { text, _ in
            entered.signal()
            release.wait()
            return text
        }
        let provider = makeProvider(runtime: runtime)
        let audio = FixtureAudioOutputService()
        let commits = CommitCounter()
        let context = RunContext(runId: "run-1", hostServices: hostWith(audio), commit: commits.commit)

        let run = Task { try await provider.run(request: speechRequest(text: "Hallo Welt.", locale: "de-DE"), context: context) }
        try await waitUntil(ms: 2000, "hook entered") { !runtime.hookTexts.isEmpty }
        run.cancel()
        release.signal()

        do {
            _ = try await bounded(ms: 2000, "run") { try await run.value }
            XCTFail("expected the run to end as a cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertEqual(commits.count, 0)
        XCTAssertTrue(audio.sessions.isEmpty)
        XCTAssertTrue(runtime.fixture.synthesized.isEmpty)
    }

    func testNeuralSpeechHandsTheTextOverUnchangedToARuntimeWithoutTheHook() async throws {
        let runtime = FixtureNeuralSpeechRuntime()
        let provider = makeProvider(runtime: runtime)
        let context = RunContext(runId: "run-1", hostServices: hostWith(FixtureAudioOutputService()), commit: { true })

        _ = try await provider.run(request: speechRequest(text: "Es sind 3 Mai.", locale: "de-DE"), context: context)

        XCTAssertEqual(runtime.synthesized.map(\.text), ["Es sind 3 Mai."])
    }

    // MARK: - Helpers

    private let host = HostServices(connectivity: MockConnectivityService(), clock: MockClockService())
    private let twentyEightCharacters = "abcdefghijklmnopqrstuvwxyz12"
    private lazy var package: ModelPackage = {
        // swiftlint:disable:next force_try
        try! decodePackage(packageJSON())
    }()

    private func makeProvider(
        id: String? = nil,
        runtime: any NeuralSpeechRuntime = FixtureNeuralSpeechRuntime(),
        timeout: Duration? = nil
    ) -> NeuralSpeechProvider {
        NeuralSpeechProvider(
            options: NeuralSpeechProviderOptions(id: id, modelPackage: package, runtime: runtime, timeout: timeout)
        )
    }

    private func hostWith(_ audioOutput: any AudioOutputService) -> HostServices {
        HostServices(connectivity: MockConnectivityService(), clock: MockClockService(), audioOutput: audioOutput)
    }

    private func input(_ text: String) -> NeuralSpeechSynthesisInput {
        NeuralSpeechSynthesisInput(modelPackage: package, text: text, locale: "de-DE", voiceId: "v1")
    }

    private func drainPreparation(_ provider: NeuralSpeechProvider) async throws {
        let context = ProviderPrepareContext(runId: "prep-1", hostServices: host, task: "text_to_speech")
        for try await _ in provider.prepare(context: context) {}
    }
}

// MARK: - Packages and requests

private let germanVoice = #"{"id": "v_de", "name": "Fixture German", "locales": ["de-DE", "de-AT"], "gender": "female"}"#
private let austrianVoice = #"{"id": "v_at", "name": "Fixture Austrian", "locales": ["de-AT"]}"#
private let englishVoice = #"{"id": "v_en", "name": "Fixture English", "locales": ["en-US"], "gender": "male"}"#

private func packageJSON(
    voices: [String] = [germanVoice, austrianVoice, englishVoice],
    source: String = #"{"sourceType": "app_managed"}"#,
    runtime: String? = nil,
    channels: Int? = nil
) -> String {
    """
    {
      "id": "fixture-tts", "version": "1", "format": "onnx", "tasks": ["text_to_speech"],
      "source": \(source),
      \(runtime.map { "\"runtime\": \($0)," } ?? "")
      "speech": {
        "pipeline": "fixture", "sampleRate": 24000, \(channels.map { "\"channels\": \($0)," } ?? "")
        "graphs": {"acoustic": "acoustic.onnx"},
        "frontend": {"kind": "grapheme"},
        "voices": [\(voices.joined(separator: ", "))]
      }
    }
    """
}

private func decodePackage(_ json: String) throws -> ModelPackage {
    try JSONDecoder().decode(ModelPackage.self, from: Data(json.utf8))
}

private func speechRequest(
    mode: OutputDelivery = .playback,
    text: String = "Hallo Welt.",
    timeoutMs: Int? = nil,
    locale: String = "de-AT"
) -> TaskRequest {
    TaskRequest(
        task: TaskDescriptor(kind: .textToSpeech),
        constraints: timeoutMs.map { TaskRequestConstraints(timeoutMs: $0) },
        speech: SpeechInput(locale: locale, localeMatch: nil, text: text, voice: nil),
        delivery: OutputDeliveryRequest(destinationRef: nil, mediaTypes: nil, mode: mode)
    )
}

// MARK: - Test doubles

/// A fixture runtime with the pre-split hook; records what the provider handed it.
private final class NormalizingRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    let fixture = FixtureNeuralSpeechRuntime()
    private let transform: @Sendable (String, String) -> String
    private let lock = NSLock()
    private var texts: [String] = []
    private var locales: [String] = []

    init(_ transform: @escaping @Sendable (String, String) -> String) {
        self.transform = transform
    }

    var hookTexts: [String] { lock.withLock { texts } }
    var hookLocales: [String] { lock.withLock { locales } }

    func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.availability(modelPackage)
    }

    func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.prepare(modelPackage)
    }

    func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        fixture.synthesize(input)
    }

    func normalizeText(_ modelPackage: ModelPackage, text: String, locale: String) -> String {
        lock.withLock {
            texts.append(text)
            locales.append(locale)
        }
        return transform(text, locale)
    }
}

/// Counts `commit()` calls and always commits.
private final class CommitCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var commits = 0

    var count: Int { lock.withLock { commits } }

    var commit: @Sendable () -> Bool {
        { [self] in
            lock.withLock { commits += 1 }
            return true
        }
    }
}

/// An audio output whose `drain()` waits until the session is stopped.
private final class BlockingDrainAudioOutput: AudioOutputService, AudioOutputSession, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var stopCount = 0
    private var pending: CheckedContinuation<Void, Never>?

    var drainStarted: Bool { lock.withLock { started } }
    var stops: Int { lock.withLock { stopCount } }

    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession { self }

    func write(_ samples: [Int16]) async throws {}

    func drain() async throws {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                started = true
                if stopCount > 0 { return true }
                pending = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func stop() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            stopCount += 1
            defer { pending = nil }
            return pending
        }
        waiting?.resume()
    }

    func firstAudioMs() -> Double? { 0 }
}

/// A runtime that synthesizes at 16000 Hz whatever the package says.
private struct WrongRateRuntime: NeuralSpeechRuntime {
    func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        NeuralSpeechAvailability(available: true)
    }

    func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        NeuralSpeechAvailability(available: true)
    }

    func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(PcmChunk(samples: [0, 0, 0], sampleRate: 16000, isLast: true))
            continuation.finish()
        }
    }
}

/// The fixture runtime, waiting `delayMs(n)` before the first chunk of the n-th sentence (from 1).
private final class PacedRuntime: NeuralSpeechRuntime, @unchecked Sendable {
    private let fixture = FixtureNeuralSpeechRuntime()
    private let delayMs: @Sendable (Int) -> Int
    private let lock = NSLock()
    private var calls = 0

    init(delayMs: @escaping @Sendable (_ sentence: Int) -> Int) {
        self.delayMs = delayMs
    }

    func availability(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.availability(modelPackage)
    }

    func prepare(_ modelPackage: ModelPackage) async -> NeuralSpeechAvailability {
        await fixture.prepare(modelPackage)
    }

    func synthesize(_ input: NeuralSpeechSynthesisInput) -> AsyncThrowingStream<PcmChunk, Error> {
        let sentence: Int = lock.withLock {
            calls += 1
            return calls
        }
        let chunks = PacedChunks(fixture.synthesize(input), delayMs: delayMs(sentence))
        return AsyncThrowingStream(unfolding: { try await chunks.next() })
    }

    private final class PacedChunks: @unchecked Sendable {
        private var iterator: AsyncThrowingStream<PcmChunk, Error>.AsyncIterator
        private var delayMs: Int

        init(_ stream: AsyncThrowingStream<PcmChunk, Error>, delayMs: Int) {
            self.iterator = stream.makeAsyncIterator()
            self.delayMs = delayMs
        }

        func next() async throws -> PcmChunk? {
            if delayMs > 0 {
                let wait = delayMs
                delayMs = 0
                do {
                    try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000)
                } catch {
                    return nil
                }
            }
            var current = iterator
            defer { iterator = current }
            return try await current.next()
        }
    }
}

/// A ``FixtureAudioOutputService`` whose `open` waits `delayMs` of wall time before opening.
private final class SlowOpenAudioOutput: AudioOutputService, @unchecked Sendable {
    let fixture = FixtureAudioOutputService()
    private let delayMs: Int

    init(delayMs: Int) {
        self.delayMs = delayMs
    }

    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession {
        try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
        return try await fixture.open(format: format)
    }
}

/// Wraps a sink, counting what its writers were asked to do; `onWrite` runs before each write.
private final class SpyArtifacts: ArtifactSink, @unchecked Sendable {
    private let inner: any ArtifactSink
    private let onWrite: @Sendable () -> Void
    private let lock = NSLock()
    private var finished = 0
    private var aborted = 0

    var finishCalls: Int { lock.withLock { finished } }
    var aborts: Int { lock.withLock { aborted } }

    init(_ inner: any ArtifactSink, onWrite: @escaping @Sendable () -> Void) {
        self.inner = inner
        self.onWrite = onWrite
    }

    func create(spec: ArtifactSpec) -> any ArtifactWriter {
        SpyWriter(inner.create(spec: spec), spy: self)
    }

    private final class SpyWriter: ArtifactWriter, @unchecked Sendable {
        private let writer: any ArtifactWriter
        private let spy: SpyArtifacts

        init(_ writer: any ArtifactWriter, spy: SpyArtifacts) {
            self.writer = writer
            self.spy = spy
        }

        func write(_ bytes: Data) throws {
            spy.onWrite()
            try writer.write(bytes)
        }

        func finish() throws -> MediaArtifact {
            spy.lock.withLock { spy.finished += 1 }
            return try writer.finish()
        }

        func abort() {
            spy.lock.withLock { spy.aborted += 1 }
            writer.abort()
        }
    }
}

/// A ``FixtureAudioOutputService`` that runs a hook when its first session is stopped.
private final class StopHookAudioOutput: AudioOutputService, @unchecked Sendable {
    let fixture = FixtureAudioOutputService()
    private let lock = NSLock()
    private var hook: (@Sendable () -> Void)?
    private var openCalls = 0

    /// Every `open` call, also one the fixture refuses because the caller is cancelled.
    var opens: Int { lock.withLock { openCalls } }

    func onFirstStop(_ hook: @escaping @Sendable () -> Void) {
        lock.withLock { self.hook = hook }
    }

    func open(format: AudioOutputFormat) async throws -> any AudioOutputSession {
        lock.withLock { openCalls += 1 }
        let session = try await fixture.open(format: format)
        return HookedSession(session) { [self] in
            let hook: (@Sendable () -> Void)? = lock.withLock {
                defer { self.hook = nil }
                return self.hook
            }
            hook?()
        }
    }

    private final class HookedSession: AudioOutputSession, @unchecked Sendable {
        private let session: any AudioOutputSession
        private let onStop: @Sendable () -> Void

        init(_ session: any AudioOutputSession, onStop: @escaping @Sendable () -> Void) {
            self.session = session
            self.onStop = onStop
        }

        func write(_ samples: [Int16]) async throws { try await session.write(samples) }
        func drain() async throws { try await session.drain() }
        func firstAudioMs() -> Double? { session.firstAudioMs() }

        func stop() {
            session.stop()
            onStop()
        }
    }
}

// MARK: - Waiting

private struct WaitExceeded: Error, CustomStringConvertible {
    let label: String
    let ms: Int
    var description: String { "\(label) did not happen within \(ms) ms" }
}

private func collect(_ stream: AsyncThrowingStream<PcmChunk, Error>) async throws -> [PcmChunk] {
    var chunks: [PcmChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

private func refusal(_ action: () async throws -> Void) async -> IndeRunException? {
    do {
        try await action()
        XCTFail("expected a refusal")
        return nil
    } catch let error as IndeRunException {
        return error
    } catch {
        XCTFail("expected an IndeRunException, got \(error)")
        return nil
    }
}

private func bounded<T: Sendable>(ms: Int, _ label: String, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            throw WaitExceeded(label: label, ms: ms)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw WaitExceeded(label: label, ms: ms) }
        return first
    }
}

private func bounded<T: Sendable>(ms: Int, _ operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
            return nil
        }
        defer { group.cancelAll() }
        return await group.next() ?? nil
    }
}

private func waitUntil(ms: Int, _ label: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(Double(ms) / 1000)
    while !condition() {
        if Date() > deadline { throw WaitExceeded(label: label, ms: ms) }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}
