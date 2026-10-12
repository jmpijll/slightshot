import AppKit

// MARK: - Annotation history

extension OverlayView {
    func undo() {
        if textEntry != nil { cancelTextEntry(); return }
        guard let annotation = annotations.popLast() else { return }
        undoneAnnotations.append(annotation)
    }

    func redo() {
        guard textEntry == nil, canvas.liveAnnotation == nil,
              let annotation = undoneAnnotations.popLast() else { return }
        annotations.append(annotation)
    }

    func updateRedoAvailability() {
        toolbars.setCanRedo(textEntry == nil && canvas.liveAnnotation == nil && !undoneAnnotations.isEmpty)
    }

    func commitAnnotation(_ annotation: Annotation) {
        undoneAnnotations.removeAll()
        annotations.append(annotation)
    }
}
