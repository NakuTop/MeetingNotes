import Foundation

struct AudioDiagnosticRuleEngine: Sendable {
    private static let minimumSilenceObservation: TimeInterval = 2

    func evaluate(_ facts: AudioDiagnosticFacts) -> AudioDiagnosticReport? {
        var issues: [AudioDiagnosticIssueCode] = []
        var evidenceIsIncomplete = false

        if !facts.microphonePermission.isAuthorized {
            append(.microphonePermissionDenied, to: &issues)
        }
        if let screenPermission = facts.screenPermission,
           !screenPermission.isAuthorized {
            append(.screenPermissionDenied, to: &issues)
        }
        if !facts.inputDeviceAvailable {
            append(.inputDeviceUnavailable, to: &issues)
        }
        if facts.outputToneWasScheduled {
            switch facts.userHeardOutputTone {
            case false:
                append(.outputNotAudible, to: &issues)
            case nil:
                evidenceIsIncomplete = true
            case true:
                break
            }
        }

        if let microphoneMetrics = facts.microphoneMetrics {
            switch microphoneMetrics.level {
            case .noFrames:
                append(.microphoneNoFrames, to: &issues)
            case .silent, .veryLow:
                if microphoneMetrics.observationDuration
                    >= Self.minimumSilenceObservation {
                    append(.microphoneSilent, to: &issues)
                } else {
                    evidenceIsIncomplete = true
                }
            case .audible:
                break
            }
        } else {
            evidenceIsIncomplete = true
        }

        let systemAudioIsApplicable =
            facts.screenPermission == .authorized
            || facts.systemAudioMetrics != nil
        if systemAudioIsApplicable {
            if let systemAudioMetrics = facts.systemAudioMetrics {
                switch systemAudioMetrics.level {
                case .noFrames:
                    append(.systemAudioNoFrames, to: &issues)
                case .silent, .veryLow:
                    if systemAudioMetrics.observationDuration
                        >= Self.minimumSilenceObservation {
                        append(.systemAudioNoFrames, to: &issues)
                    } else {
                        evidenceIsIncomplete = true
                    }
                case .audible:
                    break
                }
            } else {
                evidenceIsIncomplete = true
            }
        }

        if !issues.isEmpty {
            return report(issues: issues, facts: facts)
        }

        if evidenceIsIncomplete {
            return nil
        }

        if facts.historicalPlaybackFailed {
            issues.append(.playbackPipelineSuspected)
        } else {
            issues.append(.captureHealthy)
        }
        return report(issues: issues, facts: facts)
    }

    private func append(
        _ issue: AudioDiagnosticIssueCode,
        to issues: inout [AudioDiagnosticIssueCode]
    ) {
        if !issues.contains(issue) {
            issues.append(issue)
        }
    }

    private func report(
        issues: [AudioDiagnosticIssueCode],
        facts: AudioDiagnosticFacts
    ) -> AudioDiagnosticReport {
        AudioDiagnosticReport(
            primaryIssue: issues[0],
            supportingIssues: Array(issues.dropFirst()),
            facts: facts
        )
    }
}
