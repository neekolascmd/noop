import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawSensorExportTests: XCTestCase {
    func testExportCarriesDeviceProvenanceAndScopesRowsToSelectedRing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "oura-ring", mac: nil, name: "Oura Ring")
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: "WHOOP")

        let phase = WhoopEvent(
            ts: 1_750_000_000,
            kind: "OURA_SLEEP_PHASE_SERIES",
            payload: [
                "source_tag": .int(0x4E),
                "phase_codes": .intArray([0, 1, 2, 3]),
            ]
        )
        _ = try await store.insert(Streams(events: [phase]), deviceId: "oura-ring")
        _ = try await store.insert(
            Streams(events: [WhoopEvent(ts: phase.ts, kind: "WHOOP_DECOY", payload: [:])]),
            deviceId: "my-whoop"
        )

        let url = try await store.exportRawCSV(deviceId: "oura-ring", since: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        let firstLine = try XCTUnwrap(csv.split(separator: "\n", omittingEmptySubsequences: false).first)

        XCTAssertEqual(
            String(firstLine),
            "unix_s,iso_utc,device_id,stream,hr_bpm,rr_ms,grav_x,grav_y,grav_z,step_counter," +
                "ppg_bpm,ppg_conf,spo2_red,spo2_ir,skintemp_raw,resp_raw,band_sleep_state,event_kind,event_payload"
        )
        XCTAssertTrue(csv.contains(",oura-ring,event,"))
        XCTAssertTrue(csv.contains("OURA_SLEEP_PHASE_SERIES"))
        XCTAssertTrue(csv.contains("phase_codes"))
        XCTAssertFalse(csv.contains("WHOOP_DECOY"), "export must not leak rows from the canonical WHOOP namespace")
    }

    func testExportQuotesDeviceIdAsAnRFC4180Field() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceId = "oura,lab-ring"
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 1_750_000_000, bpm: 60)]),
            deviceId: deviceId
        )

        let url = try await store.exportRawCSV(deviceId: deviceId, since: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(csv.contains(",\"oura,lab-ring\",hr,60,"))
    }
}
