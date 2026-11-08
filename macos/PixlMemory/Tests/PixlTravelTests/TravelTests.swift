import Foundation
import PixlzCore
import Testing
@testable import PixlTravel

/// Two devices in one process, talking over real Bonjour on this Mac.
@MainActor
struct BonjourTripTests {
    func device(_ name: String) -> DeviceRef { DeviceRef(deviceId: "\(name)-\(UUID().uuidString.prefix(8))", deviceName: name) }

    /// Spins the main run loop until `ok` or the timeout.
    func waitUntil(_ timeout: Double, _ ok: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if ok() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ok()
    }

    @Test(.timeLimit(.minutes(1))) func aPixlHopsToAnotherDeviceAndOnlyOneOwnsIt() async throws {
        let macA = device("Studio Mac"), macB = device("Laptop")
        let a = TripRunner(me: macA, store: InMemoryPetStore(), knownSpecies: ["frogg", "cat"])
        let b = TripRunner(me: macB, store: InMemoryPetStore(), knownSpecies: ["frogg", "cat"])
        a.adoptIfNeeded(species: "cat", name: "Nox")
        var asked: (DeviceRef, String)?
        var entered: PetState?, exitedTo: DeviceRef?
        b.onAsk = { asked = ($0, $1) }
        b.onEntrance = { entered = $0 }
        a.onExit = { exitedTo = $0 }
        try a.start(); try b.start()
        defer { a.stop(); b.stop() }

        // discovery: each sees the other (Bonjour, like AirDrop finding a device)
        let found = await waitUntil(15) { a.peers.contains(macB) && b.peers.contains(macA) }
        #expect(found, "the two devices didn't find each other over Bonjour")
        guard found else { return }

        // the first offer from an unknown device waits for the user's yes
        a.send(to: macB)
        #expect(await waitUntil(5) { asked != nil })
        #expect(asked?.0 == macA && asked?.1 == "Nox" && entered == nil)
        b.consent(true, for: macA)

        // the trip: B owns Nox (epoch + 1), A plays the exit and keeps only the away record
        #expect(await waitUntil(10) { entered != nil && exitedTo != nil })
        #expect(entered?.name == "Nox" && entered?.species == "cat" && entered?.owner == macB && entered?.epoch == 2)   // a new Pixl starts at epoch 1; every move adds one
        #expect(exitedTo == macB)
        #expect(b.owned != nil && a.owned == nil)
        if case .away(_, let epoch, let ownerName, _)? = a.record { #expect(epoch == 2 && ownerName == "Laptop") }
        else { Issue.record("A should hold an away record, has \(String(describing: a.record))") }

        // and back: B now trusts nothing from A automatically… but A trusts nobody yet either,
        // so the return trip asks A first; declining keeps Nox on B
        var askedA = false
        a.onAsk = { _, _ in askedA = true }
        b.send(to: macA)
        #expect(await waitUntil(5) { askedA })
        var shrug: String?
        b.onShrug = { shrug = $0 }
        a.consent(false, for: macB)
        #expect(await waitUntil(5) { shrug != nil })
        #expect(b.owned?.name == "Nox" && a.owned == nil)   // declined: the Pixl stays where it is
    }

    @Test func thisDeviceHasAStableIdAndAnOverrideForASecondCopy() throws {
        let d = try #require(UserDefaults(suiteName: "pixl-dev-\(UUID())"))
        let first = ThisDevice.ref(defaults: d, env: [:])
        #expect(ThisDevice.ref(defaults: d, env: [:]) == first)                       // stable across launches
        let second = ThisDevice.ref(defaults: d, env: ["PIXL_DEVICE_ID": "copy-2", "PIXL_DEVICE_NAME": "Second copy"])
        #expect(second == DeviceRef(deviceId: "copy-2", deviceName: "Second copy"))
    }
}
