import Foundation
import SwiftUI

enum AppVisualTreatment: Equatable, Sendable {
    case material
    case liquidGlass
}

struct AppMotionProfile: Equatable, Sendable {
    let duration: TimeInterval
    let scale: CGFloat
    let usesSpring: Bool

    var animation: Animation {
        usesSpring
            ? .snappy(duration: duration, extraBounce: 0.02)
            : .easeOut(duration: duration)
    }
}

enum AppVisualPolicy {
    static func treatment(
        forMajorVersion majorVersion: Int
    ) -> AppVisualTreatment {
        majorVersion >= 26 ? .liquidGlass : .material
    }

    static func motion(reduceMotion: Bool) -> AppMotionProfile {
        reduceMotion
            ? AppMotionProfile(
                duration: 0.12,
                scale: 1,
                usesSpring: false
            )
            : AppMotionProfile(
                duration: 0.24,
                scale: 0.985,
                usesSpring: true
            )
    }
}

extension View {
    @ViewBuilder
    func adaptiveGlassSurface<S: Shape>(
        in shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay(
                    shape.stroke(.white.opacity(0.14), lineWidth: 0.5)
                )
        }
    }

    @ViewBuilder
    func adaptivePrimaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func adaptiveSecondaryButtonStyle() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }
}

struct AdaptiveGlassCard<Content: View>: View {
    private let tint: Color?
    private let content: Content

    init(
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .adaptiveGlassSurface(
                in: RoundedRectangle(cornerRadius: 18, style: .continuous),
                tint: tint
            )
    }
}

struct AppWindowGlassBackground: View {
    var body: some View {
        Rectangle()
            .fill(.clear)
            .adaptiveGlassSurface(in: Rectangle())
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
