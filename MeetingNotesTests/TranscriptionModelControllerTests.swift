import XCTest
@testable import MeetingNotes

final class TranscriptionModelControllerTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TranscriptionModelControllerTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryRoot,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
        temporaryRoot = nil
        try super.tearDownWithError()
    }

    func testPreparePreservesBalancedModelIDAndFolder() async throws {
        let storage = makeStorage()
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        try await controller.prepare(mode: .balanced)

        let requests = await spy.recordedRequests()
        XCTAssertEqual(
            requests,
            [
                TranscriptionModelLoadRequest(
                    descriptor: TranscriptionModelCatalog.descriptor(
                        for: .balanced
                    ),
                    folder: storage.folder(for: .balanced),
                    download: true
                )
            ]
        )
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.descriptor.modelID,
            "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"
        )
        XCTAssertEqual(
            request.descriptor.downloadSelector,
            "openai_whisper-large-v3-v20240930_turbo"
        )
        XCTAssertEqual(
            request.folder.lastPathComponent,
            "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"
        )
    }

    func testHighAccuracyPassesExactLargeV3ModelID() async throws {
        let storage = makeStorage()
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        try await controller.prepare(mode: .highAccuracy)

        let requests = await spy.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(
            request.descriptor.modelID,
            "openai_whisper-large-v3"
        )
        XCTAssertEqual(
            request.descriptor.downloadSelector,
            "openai_whisper-large-v3"
        )
        XCTAssertEqual(request.descriptor.mode, .highAccuracy)
        XCTAssertEqual(request.folder, storage.folder(for: .highAccuracy))
        XCTAssertTrue(request.download)
    }

    func testDefaultFactoryUsesDownloadSelectorAndPersistentFolder() throws {
        let storage = makeStorage()
        let descriptor = TranscriptionModelCatalog.descriptor(for: .balanced)
        let folder = storage.folder(for: .balanced)
        let request = TranscriptionModelLoadRequest(
            descriptor: descriptor,
            folder: folder,
            download: true
        )

        let configuration = TranscriptionModelController
            .defaultServiceConfiguration(for: request)

        XCTAssertEqual(
            configuration.modelSelector,
            "openai_whisper-large-v3-v20240930_turbo"
        )
        XCTAssertEqual(configuration.persistentModelFolder, folder)
        XCTAssertTrue(configuration.download)
        XCTAssertEqual(
            folder.lastPathComponent,
            "openai_whisper-large-v3_turbo_v3_1747_1_10_256Page"
        )
    }

    func testDownloadedModelLoadsOfflineFromItsOwnFolder() async throws {
        let storage = makeStorage()
        let folder = storage.folder(for: .highAccuracy)
        try makeCompleteModel(at: folder)
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        try await controller.prepare(mode: .highAccuracy)

        let requests = await spy.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.folder, folder)
        XCTAssertFalse(request.download)
    }

    func testCachedHighAccuracyReportsReadyBeforePreparation() async throws {
        let storage = makeStorage()
        try makeCompleteModel(at: storage.folder(for: .highAccuracy))
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        let status = await controller.status(for: .highAccuracy)
        let requests = await spy.recordedRequests()

        XCTAssertEqual(status, .ready)
        XCTAssertTrue(requests.isEmpty)
    }

    func testIncompleteHighAccuracyCacheStillReportsNotDownloaded()
        async throws {
        let storage = makeStorage()
        let folder = storage.folder(for: .highAccuracy)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("config.json")
        )
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        let status = await controller.status(for: .highAccuracy)
        let requests = await spy.recordedRequests()

        XCTAssertEqual(status, .notDownloaded)
        XCTAssertTrue(requests.isEmpty)
    }

    func testChangingModeCreatesASeparateCachedService() async throws {
        let storage = makeStorage()
        let spy = TranscriptionModelServiceFactorySpy()
        let controller = makeController(storage: storage, spy: spy)

        let balanced = try await controller.service(mode: .balanced)
        let highAccuracy = try await controller.service(mode: .highAccuracy)
        let balancedAgain = try await controller.service(mode: .balanced)

        let balancedText = try await balanced.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text
        let highAccuracyText = try await highAccuracy.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text
        let balancedAgainText = try await balancedAgain.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text
        let requests = await spy.recordedRequests()

        XCTAssertEqual(balancedText, "balanced")
        XCTAssertEqual(highAccuracyText, "highAccuracy")
        XCTAssertEqual(balancedAgainText, "balanced")
        XCTAssertEqual(requests.map(\.descriptor.mode), [.balanced, .highAccuracy])
    }

    func testConcurrentPrepareForSameModeSharesOneOperation() async throws {
        let storage = makeStorage()
        let spy = TranscriptionModelServiceFactorySpy(preparationDelay: 0.05)
        let controller = makeController(storage: storage, spy: spy)

        async let first: Void = controller.prepare(mode: .balanced)
        async let second: Void = controller.prepare(mode: .balanced)
        _ = try await (first, second)

        let requests = await spy.recordedRequests()
        let prepareCount = await spy.prepareCount(for: .balanced)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(prepareCount, 1)
        let status = await controller.status(for: .balanced)
        XCTAssertEqual(status, .ready)
    }

    func testFailedHighAccuracyPreparationLeavesBalancedUsable() async throws {
        let storage = makeStorage()
        let spy = TranscriptionModelServiceFactorySpy(
            failingModes: [.highAccuracy]
        )
        let controller = makeController(storage: storage, spy: spy)

        try await controller.prepare(mode: .balanced)
        do {
            try await controller.prepare(mode: .highAccuracy)
            XCTFail("Expected high-accuracy preparation to fail")
        } catch TranscriptionModelControllerTestError.expectedFailure {
        }

        let balanced = try await controller.service(mode: .balanced)
        let text = try await balanced.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text
        let balancedStatus = await controller.status(for: .balanced)
        let highAccuracyStatus = await controller.status(for: .highAccuracy)

        XCTAssertEqual(text, "balanced")
        XCTAssertEqual(balancedStatus, .ready)
        XCTAssertEqual(highAccuracyStatus, .failed)
    }

    func testCancellingOneWaiterDoesNotCancelSharedPreparation()
        async throws {
        let storage = makeStorage()
        let gate = ControllerPreparationGate()
        let spy = TranscriptionModelServiceFactorySpy(
            preparationGate: gate
        )
        let controller = makeController(storage: storage, spy: spy)
        let cancelledWaiter = Task {
            try await controller.service(mode: .highAccuracy)
        }
        let successfulWaiter = Task {
            try await controller.service(mode: .highAccuracy)
        }
        for _ in 0..<1_000 {
            if await spy.prepareCount(for: .highAccuracy) == 1 {
                break
            }
            await Task.yield()
        }

        cancelledWaiter.cancel()
        await gate.resume()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("Expected the cancelled waiter to throw CancellationError")
        } catch is CancellationError {
        }
        let service = try await successfulWaiter.value
        let text = try await service.transcribe(
            samples: [1],
            startingAt: 0
        ).first?.text
        let requestCount = await spy.recordedRequests().count
        let prepareCount = await spy.prepareCount(for: .highAccuracy)
        let status = await controller.status(for: .highAccuracy)

        XCTAssertEqual(text, "highAccuracy")
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(status, .ready)
    }

    private func makeStorage() -> TranscriptionModelStorage {
        TranscriptionModelStorage(
            modelsRoot: temporaryRoot.appendingPathComponent(
                "WhisperModels-v2",
                isDirectory: true
            ),
            legacyModelFolder: nil
        )
    }

    private func makeController(
        storage: TranscriptionModelStorage,
        spy: TranscriptionModelServiceFactorySpy
    ) -> TranscriptionModelController {
        TranscriptionModelController(storage: storage) { request in
            await spy.makeService(for: request)
        }
    }

    private func makeCompleteModel(at folder: URL) throws {
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(
            to: folder.appendingPathComponent("config.json")
        )
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent(
                "Encoder.mlmodelc",
                isDirectory: true
            ),
            withIntermediateDirectories: true
        )
    }
}

private enum TranscriptionModelControllerTestError: Error {
    case expectedFailure
}

private actor TranscriptionModelServiceFactorySpy {
    private let preparationDelay: TimeInterval
    private let preparationGate: ControllerPreparationGate?
    private let failingModes: Set<TranscriptionQualityMode>
    private var requests: [TranscriptionModelLoadRequest] = []
    private var services: [TranscriptionQualityMode: ControllerFakeService] = [:]

    init(
        preparationDelay: TimeInterval = 0,
        preparationGate: ControllerPreparationGate? = nil,
        failingModes: Set<TranscriptionQualityMode> = []
    ) {
        self.preparationDelay = preparationDelay
        self.preparationGate = preparationGate
        self.failingModes = failingModes
    }

    func makeService(
        for request: TranscriptionModelLoadRequest
    ) -> any TranscriptionService {
        requests.append(request)
        let service = ControllerFakeService(
            mode: request.descriptor.mode,
            preparationDelay: preparationDelay,
            preparationGate: preparationGate,
            shouldFailPreparation: failingModes.contains(
                request.descriptor.mode
            )
        )
        services[request.descriptor.mode] = service
        return service
    }

    func recordedRequests() -> [TranscriptionModelLoadRequest] {
        requests
    }

    func prepareCount(for mode: TranscriptionQualityMode) async -> Int {
        await services[mode]?.recordedPrepareCount() ?? 0
    }
}

private actor ControllerFakeService: TranscriptionService {
    private let mode: TranscriptionQualityMode
    private let preparationDelay: TimeInterval
    private let preparationGate: ControllerPreparationGate?
    private let shouldFailPreparation: Bool
    private var prepareCount = 0

    init(
        mode: TranscriptionQualityMode,
        preparationDelay: TimeInterval,
        preparationGate: ControllerPreparationGate?,
        shouldFailPreparation: Bool
    ) {
        self.mode = mode
        self.preparationDelay = preparationDelay
        self.preparationGate = preparationGate
        self.shouldFailPreparation = shouldFailPreparation
    }

    func prepare() async throws {
        prepareCount += 1
        if preparationDelay > 0 {
            try await Task.sleep(
                for: .seconds(preparationDelay)
            )
        }
        if let preparationGate {
            await preparationGate.wait()
        }
        if shouldFailPreparation {
            throw TranscriptionModelControllerTestError.expectedFailure
        }
    }

    func transcribe(
        samples: [Float],
        startingAt: TimeInterval
    ) async throws -> [TranscriptDraft] {
        _ = samples
        return [
            TranscriptDraft(
                startTime: startingAt,
                endTime: startingAt + 1,
                text: mode.rawValue
            )
        ]
    }

    func recordedPrepareCount() -> Int {
        prepareCount
    }
}

private actor ControllerPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
