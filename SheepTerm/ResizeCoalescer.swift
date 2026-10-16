import Foundation

/// A terminal's new size reaches the device once it has stopped changing
/// (5.0 (24)): the sidebar's slide, a window drag or a pane divider resize
/// the view every frame, and every SSH window-change makes a switch redraw
/// its prompt — a dozen in 0.2 s garbled the line. The LAST size always goes
/// out; nothing is sent when the size ends where it began.
@MainActor
final class ResizeCoalescer {
    static let delay: TimeInterval = 0.15
    private var pending: (cols: Int, rows: Int)?
    private var sent: (cols: Int, rows: Int)?
    private var generation = 0
    private let send: (Int, Int) -> Void

    init(send: @escaping (Int, Int) -> Void) { self.send = send }

    func changed(cols: Int, rows: Int) {
        pending = (cols, rows)
        generation &+= 1
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
            guard let self, current == self.generation, let size = self.pending else { return }
            self.pending = nil
            if let sent = self.sent, sent == size { return }
            self.sent = size
            self.send(size.cols, size.rows)
        }
    }
}
