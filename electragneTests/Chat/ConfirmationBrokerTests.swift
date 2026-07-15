import Testing
@testable import electragne

@MainActor
struct ConfirmationBrokerTests {
    @Test func approvesOnce() async {
        let broker = ConfirmationBroker()
        let request = Task { await broker.request() }
        await waitForRequest(broker)

        broker.resolve(approved: true)
        broker.resolve(approved: false)

        #expect(await request.value)
        #expect(!broker.hasPendingRequest)
    }

    @Test func cancellationRejectsRequest() async {
        let broker = ConfirmationBroker()
        let request = Task { await broker.request() }
        await waitForRequest(broker)

        request.cancel()

        #expect(await request.value == false)
        #expect(!broker.hasPendingRequest)
    }

    @Test func newerRequestSupersedesOlderRequest() async {
        let broker = ConfirmationBroker()
        let first = Task { await broker.request() }
        await waitForRequest(broker)

        let second = Task { await broker.request() }
        #expect(await first.value == false)
        broker.resolve(approved: true)

        #expect(await second.value)
        #expect(!broker.hasPendingRequest)
    }

    private func waitForRequest(_ broker: ConfirmationBroker) async {
        while !broker.hasPendingRequest { await Task.yield() }
    }
}
