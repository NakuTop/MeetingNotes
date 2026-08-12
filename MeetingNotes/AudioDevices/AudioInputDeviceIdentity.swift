import Foundation

enum AudioInputDeviceIdentityMatcher {
    static func mergedInputs(
        from snapshot: AudioInputDiscoverySnapshot
    ) -> [AudioInputDevice] {
        var results: [AudioInputDevice] = []
        var matchedAVF: Set<Int> = []
        var matchedCoreAudio: Set<Int> = []

        // Priority 1: exact UID / identifier correspondence.
        for (avfIndex, avf) in snapshot.avFoundationInputs.enumerated() {
            guard !matchedAVF.contains(avfIndex) else { continue }
            if let coreAudioIndex = snapshot.coreAudioInputs.firstIndex(
                where: { $0.uid == avf.uniqueID }
            ), !matchedCoreAudio.contains(coreAudioIndex) {
                results.append(
                    merged(
                        avFoundation: avf,
                        coreAudio: snapshot.coreAudioInputs[coreAudioIndex]
                    )
                )
                matchedAVF.insert(avfIndex)
                matchedCoreAudio.insert(coreAudioIndex)
            }
        }

        // Priority 2: system-default relationship with matching name.
        for (avfIndex, avf) in snapshot.avFoundationInputs.enumerated() {
            guard !matchedAVF.contains(avfIndex) else { continue }
            guard avf.isSystemDefault else { continue }
            if let coreAudioIndex = unmatchedCoreAudioIndex(
                matchingName: avf.name,
                isSystemDefaultOnly: true,
                in: snapshot,
                matched: matchedCoreAudio
            ) {
                results.append(
                    merged(
                        avFoundation: avf,
                        coreAudio: snapshot.coreAudioInputs[coreAudioIndex]
                    )
                )
                matchedAVF.insert(avfIndex)
                matchedCoreAudio.insert(coreAudioIndex)
            }
        }

        // Priority 3: controlled exact name matching, last resort.
        for (avfIndex, avf) in snapshot.avFoundationInputs.enumerated() {
            guard !matchedAVF.contains(avfIndex) else { continue }
            guard hasUniqueUnmatchedPair(
                name: avf.name,
                in: snapshot,
                matchedAVF: matchedAVF,
                matchedCoreAudio: matchedCoreAudio
            ) else {
                continue
            }
            if let coreAudioIndex = unmatchedCoreAudioIndex(
                matchingName: avf.name,
                isSystemDefaultOnly: false,
                in: snapshot,
                matched: matchedCoreAudio
            ) {
                results.append(
                    merged(
                        avFoundation: avf,
                        coreAudio: snapshot.coreAudioInputs[coreAudioIndex]
                    )
                )
                matchedAVF.insert(avfIndex)
                matchedCoreAudio.insert(coreAudioIndex)
            }
        }

        for (avfIndex, avf) in snapshot.avFoundationInputs.enumerated()
        where !matchedAVF.contains(avfIndex) {
            results.append(merged(avFoundation: avf, coreAudio: nil))
        }

        for (coreAudioIndex, coreAudio) in
            snapshot.coreAudioInputs.enumerated()
        where !matchedCoreAudio.contains(coreAudioIndex) {
            results.append(
                merged(avFoundation: nil, coreAudio: coreAudio)
            )
        }

        return results
    }

    private static func hasUniqueUnmatchedPair(
        name: String,
        in snapshot: AudioInputDiscoverySnapshot,
        matchedAVF: Set<Int>,
        matchedCoreAudio: Set<Int>
    ) -> Bool {
        let normalized = normalizedName(name)
        let avFoundationCount = snapshot.avFoundationInputs.indices
            .filter {
                !matchedAVF.contains($0)
                    && normalizedName(
                        snapshot.avFoundationInputs[$0].name
                    ) == normalized
            }
            .count
        let coreAudioCount = snapshot.coreAudioInputs.indices
            .filter {
                !matchedCoreAudio.contains($0)
                    && normalizedName(
                        snapshot.coreAudioInputs[$0].name
                    ) == normalized
            }
            .count
        return avFoundationCount == 1 && coreAudioCount == 1
    }

    private static func unmatchedCoreAudioIndex(
        matchingName name: String,
        isSystemDefaultOnly: Bool,
        in snapshot: AudioInputDiscoverySnapshot,
        matched: Set<Int>
    ) -> Int? {
        snapshot.coreAudioInputs.indices.first { index in
            guard !matched.contains(index) else { return false }
            let candidate = snapshot.coreAudioInputs[index]
            if isSystemDefaultOnly, !candidate.isSystemDefault {
                return false
            }
            return normalizedName(candidate.name)
                == normalizedName(name)
        }
    }

    private static func merged(
        avFoundation: AVFoundationInputDevice?,
        coreAudio: CoreAudioInputDevice?
    ) -> AudioInputDevice {
        let isSystemDefault =
            avFoundation?.isSystemDefault == true
            || coreAudio?.isSystemDefault == true
        return AudioInputDevice(
            id: avFoundation?.uniqueID
                ?? coreAudio.map { "ca:\($0.uid)" }
                ?? "unknown-input",
            name: avFoundation?.name ?? coreAudio?.name ?? "",
            manufacturer: avFoundation?.manufacturer ?? "",
            isConnected:
                avFoundation?.isConnected == true
                || coreAudio?.isAlive == true,
            isSuspended: avFoundation?.isSuspended ?? false,
            isInUseByAnotherApplication:
                avFoundation?.isInUseByAnotherApplication ?? false,
            isSystemDefault: isSystemDefault,
            avFoundationUniqueID: avFoundation?.uniqueID,
            coreAudioUID: coreAudio?.uid,
            coreAudioDeviceID: coreAudio?.deviceID,
            inputChannelCount: coreAudio?.inputChannelCount ?? 0,
            isAVFoundationAvailable: avFoundation != nil,
            isCoreAudioAvailable: coreAudio != nil
        )
    }

    private static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedLowercase
    }
}
