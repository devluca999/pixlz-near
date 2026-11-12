import XCTest
@testable import Ponds

final class PondTests: XCTestCase {
    func test_seatsEveryFrogWhenThereArePadsEnough() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 5, frogs: 3).seated, 3)
    }
    func test_sparesWaitInTheReeds() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 2, frogs: 5).waiting, 3)
    }
    func test_addingPadsSeatsTheWaiting() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        var p = Pond(pads: 1, frogs: 3); p.addPads(2); XCTAssertEqual(p.waiting, 0)
    }
    func test_negativePadsChangeNothing() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        var p = Pond(pads: 2, frogs: 2); p.addPads(-4); XCTAssertEqual(p.pads, 2)
    }
    func test_anEmptyPondIsCalm() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 0, frogs: 0).seated, 0)
    }
    func test_onePadOneFrog() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 1, frogs: 1).waiting, 0)
    }
    func test_manyFrogsFewPads() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 1, frogs: 9).seated, 1)
    }
    func test_padsNeverGoNegative() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        var p = Pond(pads: 0, frogs: 1); p.addPads(-1); XCTAssertGreaterThanOrEqual(p.pads, 0)
    }
    func test_seatedNeverExceedsFrogs() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertLessThanOrEqual(Pond(pads: 9, frogs: 4).seated, 4)
    }
    func test_waitingIsNeverNegative() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 9, frogs: 4).waiting, 0)
    }
    func test_aBigPond() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 400, frogs: 300).seated, 300)
    }
    func test_aTinyPond() throws {
        Thread.sleep(forTimeInterval: 0.25)   // a little time, so the run reads on camera
        XCTAssertEqual(Pond(pads: 1, frogs: 0).seated, 0)
    }
}
