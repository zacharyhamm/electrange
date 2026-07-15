import Foundation

@MainActor
final class ConfirmationBroker {
    private typealias Pending = (id: UUID, continuation: CheckedContinuation<Bool, Never>)
    private var pending: Pending?

    var hasPendingRequest: Bool { pending != nil }

    func request() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                resolve(approved: false)
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                pending = (id, continuation)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolve(approved: false, id: id)
            }
        }
    }

    func resolve(approved: Bool) {
        resolve(approved: approved, id: pending?.id)
    }

    private func resolve(approved: Bool, id: UUID?) {
        guard let id, pending?.id == id else { return }
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(returning: approved)
    }
}
