import SwiftUI
import UIKit

/// Hosts whichever `UIView` the active frame source renders into.
struct VideoPreview: UIViewRepresentable {
    let source: FrameSource

    func makeUIView(context: Context) -> ContainerView {
        let container = ContainerView()
        container.install(source.makePreviewView())
        context.coordinator.sourceIdentifier = ObjectIdentifier(source)
        return container
    }

    func updateUIView(_ container: ContainerView, context: Context) {
        let identifier = ObjectIdentifier(source)
        guard context.coordinator.sourceIdentifier != identifier else { return }
        context.coordinator.sourceIdentifier = identifier
        container.install(source.makePreviewView())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var sourceIdentifier: ObjectIdentifier?
    }

    final class ContainerView: UIView {
        private var hosted: UIView?

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            backgroundColor = .black
            clipsToBounds = true
        }

        func install(_ view: UIView) {
            hosted?.removeFromSuperview()
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
            hosted = view
        }
    }
}
