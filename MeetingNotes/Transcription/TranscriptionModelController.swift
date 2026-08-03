import Foundation

struct TranscriptionModelLoadRequest: Equatable, Sendable {
    let descriptor: TranscriptionModelDescriptor
    let folder: URL
    let download: Bool
}

protocol TranscriptionModelStatusControlling: Sendable {
    func status(
        for mode: TranscriptionQualityMode
    ) async -> TranscriptionModelStatus
    func prepare(mode: TranscriptionQualityMode) async throws
}

protocol TranscriptionModelControlling: TranscriptionModelStatusControlling {
    func service(
        mode: TranscriptionQualityMode
    ) async throws -> any TranscriptionService
}

actor TranscriptionModelController: TranscriptionModelControlling {
    typealias ServiceFactory = @Sendable (
        TranscriptionModelLoadRequest
    ) async -> any TranscriptionService

    private struct Preparation: Sendable {
        let id: UUID
        let task: Task<any TranscriptionService, Error>
    }

    private let storage: TranscriptionModelStorage
    private let makeService: ServiceFactory
    private var statuses: [
        TranscriptionQualityMode: TranscriptionModelStatus
    ] = [:]
    private var services: [
        TranscriptionQualityMode: any TranscriptionService
    ] = [:]
    private var preparationTasks: [
        TranscriptionQualityMode: Preparation
    ] = [:]

    init(
        storage: TranscriptionModelStorage,
        makeService: @escaping ServiceFactory = { request in
            WhisperKitTranscriptionService(
                model: request.descriptor.modelID,
                persistentModelFolder: request.folder,
                download: request.download
            )
        }
    ) {
        self.storage = storage
        self.makeService = makeService
    }

    func status(
        for mode: TranscriptionQualityMode
    ) -> TranscriptionModelStatus {
        if let status = statuses[mode] {
            return status
        }
        let descriptor = TranscriptionModelCatalog.descriptor(for: mode)
        guard let folder = try? storage.resolvedFolder(for: descriptor),
              storage.hasCompleteModel(at: folder) else {
            return .notDownloaded
        }
        statuses[mode] = .ready
        return .ready
    }

    func prepare(mode: TranscriptionQualityMode) async throws {
        _ = try await service(mode: mode)
    }

    func service(
        mode: TranscriptionQualityMode
    ) async throws -> any TranscriptionService {
        if let service = services[mode] {
            try Task.checkCancellation()
            return service
        }
        if let preparation = preparationTasks[mode] {
            return try await finishPreparation(
                preparation,
                mode: mode
            )
        }

        let descriptor = TranscriptionModelCatalog.descriptor(for: mode)
        let folder: URL
        do {
            folder = try storage.resolvedFolder(for: descriptor)
        } catch {
            statuses[mode] = .failed
            throw error
        }
        let request = TranscriptionModelLoadRequest(
            descriptor: descriptor,
            folder: folder,
            download: !storage.hasCompleteModel(at: folder)
        )
        let makeService = self.makeService
        statuses[mode] = .downloading
        let task = Task<any TranscriptionService, Error> {
            let service = await makeService(request)
            try await service.prepare()
            return service
        }
        let preparation = Preparation(id: UUID(), task: task)
        preparationTasks[mode] = preparation
        return try await finishPreparation(preparation, mode: mode)
    }

    private func finishPreparation(
        _ preparation: Preparation,
        mode: TranscriptionQualityMode
    ) async throws -> any TranscriptionService {
        do {
            let service = try await preparation.task.value
            if preparationTasks[mode]?.id == preparation.id {
                services[mode] = service
                preparationTasks[mode] = nil
                statuses[mode] = .ready
            }
            try Task.checkCancellation()
            return service
        } catch {
            if preparationTasks[mode]?.id == preparation.id {
                preparationTasks[mode] = nil
                statuses[mode] = .failed
            }
            throw error
        }
    }
}

struct PreferredTranscriptionModelPreparer: TranscriptionModelPreparing {
    private let controller: any TranscriptionModelControlling
    private let qualityPreference: any TranscriptionQualityPreferenceReading

    init(
        controller: any TranscriptionModelControlling,
        qualityPreference: any TranscriptionQualityPreferenceReading
    ) {
        self.controller = controller
        self.qualityPreference = qualityPreference
    }

    func prepare() async throws {
        let mode = await qualityPreference.transcriptionQualityMode()
        try await controller.prepare(mode: mode)
    }
}
