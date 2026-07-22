import XCTest
@testable import OuraProtocol

/// Golden per-tag fixture tests: raw TLV record bytes -> expected decoded event(s). Vectors are
/// SYNTHETIC, built from the byte layouts in docs/OURA_PROTOCOL.md s6 (no real biometric capture is
/// embedded). The full record is `type len rt(4 LE) payload` with rt = 0x00010002 (counter 2, session
/// 1) throughout, so every assertion pins ringTimestamp == 65538.
final class DecoderGoldenTests: XCTestCase {
    private let rt: UInt32 = 0x0001_0002   // 65538

    private func bytes(_ s: String) -> [UInt8] {
        var out = [UInt8](); out.reserveCapacity(s.count / 2)
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Parse one record from hex and assert the header decoded as expected.
    private func record(_ hex: String) -> OuraRecord {
        guard let rec = OuraFraming.parseRecord(bytes(hex)) else {
            XCTFail("record failed to parse: \(hex)"); return OuraRecord(type: 0, ringTimestamp: 0, payload: [])
        }
        XCTAssertEqual(rec.ringTimestamp, rt)
        return rec
    }

    // MARK: - 0x80 green IBI quality (split 11-bit IBI + 2-bit quality)

    func testGreenIBIQuality0x80FiltersOnQuality() {
        // Independently constructed: 1000ms/q1 passes; the same IBI at q0 and q2 is rejected.
        let rec = record("800a020001007d087d007d10")
        let ibis = OuraDecoders.decodeGreenIBIQuality(rec)
        XCTAssertEqual(ibis, [OuraIBI(ringTimestamp: rt, ibiMs: 1000)])
    }

    func testGreenIBIQuality0x80PhysiologicalBoundsAndShape() {
        // 300ms/q1 and 2000ms/q1 pass; 299ms and 2001ms are dropped.
        let rec = record("800c02000100250cfa08250bfa09")
        XCTAssertEqual(OuraDecoders.decodeGreenIBIQuality(rec), [
            OuraIBI(ringTimestamp: rt, ibiMs: 300),
            OuraIBI(ringTimestamp: rt, ibiMs: 2000),
        ])
        XCTAssertNil(OuraDecoders.decodeGreenIBIQuality(
            OuraRecord(type: 0x80, ringTimestamp: rt, payload: [0x7D])))
    }

    // MARK: - 0x60 IBI + amplitude (MSB-first bit-packed; n=7 -> shift 0)

    func testIBIAmplitude0x60BitPacked() {
        // first pair ibi1000 amp-mantissa64, last byte low nibble = 7 (shift 0).
        let rec = record("6012020001007d10000000000000000000000007")
        let ibis = OuraDecoders.decodeIBIAmplitude(rec)
        XCTAssertNotNil(ibis)
        XCTAssertEqual(ibis?.first, OuraIBI(ringTimestamp: rt, ibiMs: 1000, amplitude: 64))
    }

    // MARK: - 0x6E SpO2 IBI (REVERSE byte order x8)

    func testSpO2IBI0x6EReverseOrder() {
        // body[1..5] = 10,20,30,40,50 read 5->1 reversed -> 50,40,30,20,10 then x8.
        let rec = record("6e0a02000100000a141e2832")
        let ibis = OuraDecoders.decodeSpO2IBI(rec)
        XCTAssertEqual(ibis, [
            OuraIBI(ringTimestamp: rt, ibiMs: 400),
            OuraIBI(ringTimestamp: rt, ibiMs: 320),
            OuraIBI(ringTimestamp: rt, ibiMs: 240),
            OuraIBI(ringTimestamp: rt, ibiMs: 160),
            OuraIBI(ringTimestamp: rt, ibiMs: 80),
        ])
    }

    // MARK: - 0x5D HRV / RMSSD

    func testHRV0x5D() {
        // time 5000, b1=10, b2=-5
        let rec = record("5d080200010088130afb")
        let hrv = OuraDecoders.decodeHRV(rec)
        XCTAssertEqual(hrv, [OuraHRV(ringTimestamp: rt, timeMs: 5000, b1: 10, b2: -5)])
    }

    // MARK: - 0x6F SpO2 per-sample (byte6 high nibble is a base/status field, DISCARDED; samples are
    // direct percentages, #968 — adding the scaled base gave impossible ~223% readings)

    func testSpO2PerSample0x6F() {
        // byte6 high nibble 1 (base/status, discarded) ; samples 95,96 ; FF terminator.
        let rec = record("6f0802000100105f60ff")
        let s = OuraDecoders.decodeSpO2PerSample(rec)
        XCTAssertEqual(s, [
            OuraSpO2(ringTimestamp: rt, value: 95, unit: "percent", sampleOffsetSeconds: -1),
            OuraSpO2(ringTimestamp: rt, value: 96, unit: "percent"),
        ])
    }

    // MARK: - 0x7B SpO2 stable (BIG-endian footgun)

    func testSpO2Stable0x7BIsBigEndian() {
        // BE 0x03CA = 970. If decoded LE it would be 0xCA03 = 51715, so this proves the BE path.
        let rec = record("7b060200010003ca")
        let s = OuraDecoders.decodeSpO2Stable(rec)
        XCTAssertEqual(s, OuraSpO2(ringTimestamp: rt, value: 970, unit: "tenths_percent"))
    }

    // MARK: - 0x8B raw R-ratio + perfusion index

    func testSpO2RatioPI0x8BPreservesWireValuesAndCalibratesExplicitly() {
        // Synthetic record: header A5; Q14 ratios 0.75 and ~0.80; perfusion bytes 128 and 64.
        let rec = record("8b0b02000100a5300080333340")
        let decoded = OuraDecoders.decodeSpO2RatioPI(rec)
        XCTAssertEqual(decoded, OuraSpO2RatioRecord(ringTimestamp: rt, header: 0xA5, samples: [
            OuraSpO2RatioSample(ratioQ14: 0x3000, perfusionRaw: 128),
            OuraSpO2RatioSample(ratioQ14: 0x3333, perfusionRaw: 64),
        ]))
        XCTAssertEqual(decoded?.samples[0].ratio ?? -1, 0.75, accuracy: 1e-12)
        XCTAssertEqual(decoded?.samples[0].perfusionIndex ?? -1, 128.0 / 255.0 * 0.05,
                       accuracy: 1e-12)
        XCTAssertEqual(decoded?.samples.compactMap { OuraSpO2CalibrationProfile.gen4Oreo
            .calibratedTenthsPercent(ratio: $0.ratio) }, [938, 925])
        XCTAssertEqual(decoded?.samples.compactMap { OuraSpO2CalibrationProfile.cooper
            .calibratedTenthsPercent(ratio: $0.ratio) }, [943, 930])
        XCTAssertNil(OuraSpO2CalibrationProfile.forRingGeneration(.gen3))
        XCTAssertNil(OuraSpO2CalibrationProfile.forRingGeneration(.gen5))
    }

    func testSpO2RatioPI0x8BRejectsMalformedShape() {
        XCTAssertNil(OuraDecoders.decodeSpO2RatioPI(
            OuraRecord(type: 0x8B, ringTimestamp: rt, payload: [0x00, 0x30, 0x00])))
        XCTAssertNil(OuraSpO2CalibrationProfile.gen4Oreo.calibratedPercentage(ratio: 0))
    }

    func testSleepPeriod0x6AAndBedtimeBounds0x76() {
        let sleep = record("6a0e020001006e000000700003010000")
        XCTAssertEqual(OuraDecoders.decodeSleepPeriod(sleep),
                       OuraSleepPeriod(ringTimestamp: rt, averageHeartRate: 55,
                                       respirationRate: 14, motionCount: 3, sleepState: 1))

        let bedtime = record("760c02000100e8030000740e0000")
        XCTAssertEqual(OuraDecoders.decodeBedtimePeriod(bedtime),
                       OuraBedtimePeriod(ringTimestamp: rt,
                                         startRingTimestamp: 1000,
                                         endRingTimestamp: 3700))
    }

    // MARK: - 0x46 temperature (int16 LE / 100)

    func testTemp0x46() {
        // 3650/100 = 36.50 ; 3655/100 = 36.55
        let rec = record("460802000100420e470e")
        let t = OuraDecoders.decodeTemp(rec)
        XCTAssertEqual(t, [
            OuraTemp(ringTimestamp: rt, celsius: 36.50),
            OuraTemp(ringTimestamp: rt, celsius: 36.55),
        ])
    }

    // MARK: - 0x42 time sync (generation-specific)

    func testTimeSync0x42() {
        // epoch 1719662400000 ms, tz byte 2 -> 3600 s.
        let rec = record("420d0200010000d2dd639001000002")
        let ts = OuraDecoders.decodeTimeSync(rec)
        XCTAssertEqual(ts, OuraTimeSync(ringTimestamp: rt, epochMs: 1_719_662_400_000, tzOffsetSeconds: 3600))
    }

    func testRing4TimeSync0x42UsesCompressedEpochAndTokenFactor() {
        // token 0x00, counter 0x6553F1 LE -> 6,640,625 * 256 = 1,700,000,000 seconds.
        let normal = record("420d0200010000f1536500000000f6")
        XCTAssertEqual(
            OuraDecoders.decodeTimeSync(normal, ringGen: .gen4),
            OuraTimeSync(ringTimestamp: rt, epochMs: 1_700_000_000,
                         tzOffsetSeconds: 0, factorMsPerTick: 100, token: 0x00)
        )

        let burst = record("420d02000100fdf1536500000000f6")
        XCTAssertEqual(
            OuraDecoders.decodeTimeSync(burst, ringGen: .gen4),
            OuraTimeSync(ringTimestamp: rt, epochMs: 1_700_000_000,
                         tzOffsetSeconds: 0, factorMsPerTick: 1, token: 0xFD)
        )
    }

    // MARK: - 0x4E sleep phase (2-bit codes MSB-first; header byte skipped)

    func testSleepPhase0x4E() {
        // header 0x00, phase byte 0x6C = bits 01 10 11 00 -> light, deep, rem, awake.
        let rec = record("4e0602000100006c")
        let phases = OuraDecoders.decodeSleepPhase(rec)
        XCTAssertEqual(phases, [
            OuraSleepPhase(ringTimestamp: rt, index: 0, stage: .light),
            OuraSleepPhase(ringTimestamp: rt, index: 1, stage: .deep),
            OuraSleepPhase(ringTimestamp: rt, index: 2, stage: .rem),
            OuraSleepPhase(ringTimestamp: rt, index: 3, stage: .awake),
        ])
    }

    // MARK: - 0x6B motion period (2-bit MOTION_STATE codes; 2 header bytes skipped)

    func testMotionPeriod0x6B() {
        // 2 header bytes 0x00 0x00, code byte 0x1B = 00 01 10 11 -> noMotion, restless, tossing, active.
        let rec = record("6b070200010000001b")
        let m = OuraDecoders.decodeMotionPeriod(rec)
        XCTAssertEqual(m, [
            OuraMotion(ringTimestamp: rt, index: 0, state: .noMotion),
            OuraMotion(ringTimestamp: rt, index: 1, state: .restless),
            OuraMotion(ringTimestamp: rt, index: 2, state: .tossing),
            OuraMotion(ringTimestamp: rt, index: 3, state: .active),
        ])
    }

    // MARK: - 0x85 RTC beacon (unix_s u32 LE)

    func testRtcBeacon0x85() {
        let rec = record("850e0200010040f77f6600000000f601")
        let r = OuraDecoders.decodeRtcBeacon(rec)
        XCTAssertEqual(r, OuraRtcBeacon(ringTimestamp: rt, unixSeconds: 1_719_662_400))
    }

    // MARK: - 0x45 state change

    func testState0x45() {
        let rec = record("45050200010004")
        let s = OuraDecoders.decodeState(rec)
        XCTAssertEqual(s?.stateCode, 4)     // user_in_rest
        XCTAssertNil(s?.text)               // body too short for a trailing string
    }

    // MARK: - 0x43 debug text

    func testDebugText0x43() {
        let rec = record("4306020001004142")
        XCTAssertEqual(OuraDecoders.decodeDebugText(rec), "AB")
    }

    // MARK: - 0x0D battery (outer response body; percent at [0], voltage at [4..6] LE)

    func testBattery0x0D() {
        // body: 87%, charging 0, voltage 3900 mv at bytes 4..6.
        let body = bytes("570000003c0f0000")
        let b = OuraDecoders.decodeBattery(body)
        XCTAssertEqual(b, OuraBattery(percent: 87, voltageMv: 3900, charging: false))
    }

    func testBatteryRejectsImplausiblePercent() {
        // A "percent" > 100 is a misread; decode to nil, never a guessed value.
        let body: [UInt8] = [200, 0, 0, 0, 0, 0]
        XCTAssertNil(OuraDecoders.decodeBattery(body))
    }

    // MARK: - Live HR push (12-bit nibble IBI -> bpm), built from the s5.6 wire layout

    /// The fixture is derived from the OURA_PROTOCOL.md s5.6 wire frame, NOT from the implementation:
    ///   full frame = `2f 0f 28 02 XX 02 00 00 IBI_L IBI_H 00 00 00 00 YY ZZ 7f` (len 0x0f = 15)
    /// The transport strips the leading `2f 0f 28`, so the decoder receives the 14-byte subBody with the
    /// IBI at subBody[5..6]. Here IBI_L=0x01, IBI_H=0x04 -> ibi ((0x04 & 0x0F)<<8)|0x01 = 1025 ->
    /// bpm round(60000/1025) = 59. Per OURA_PROTOCOL.md s5.6.
    func testLiveHRPushNibbleIBI() {
        let fullFrame = bytes("2f0f28020002000001040000000000007f")
        // Self-check the wire layout: type 0x2f, len 0x0f (15) counts the bytes after type+len, i.e. the
        // subop byte plus the subBody (s2.2). So subBody.count must equal len - 1.
        XCTAssertEqual(fullFrame[0], 0x2F)
        XCTAssertEqual(fullFrame[1], 0x0F)
        XCTAssertEqual(Int(fullFrame[1]), 15)
        XCTAssertEqual(fullFrame.count, 2 + Int(fullFrame[1]))   // type + len + 15 body bytes = 17
        // Strip `2f 0f 28` (type, len, subop) exactly as the transport does -> the 14-byte subBody.
        XCTAssertEqual(Array(fullFrame[0..<3]), [0x2F, 0x0F, 0x28])
        let subBody = Array(fullFrame[3...])
        XCTAssertEqual(subBody.count, Int(fullFrame[1]) - 1)     // 14 == len(15) - subop(1)
        XCTAssertEqual(subBody.count, 14)
        // The IBI is at subBody index 5 (low) / 6 (high) per the stripped s5.6 layout.
        XCTAssertEqual(subBody[5], 0x01)
        XCTAssertEqual(subBody[6], 0x04)

        let hr = OuraDecoders.decodeLiveHRPush(subBody, ringTimestamp: rt)
        XCTAssertEqual(hr, OuraHR(ringTimestamp: rt, bpm: 59, ibiMs: 1025))
    }

    // MARK: - Honest-data invariant: short / malformed records decode to nil

    func testShortRecordsDecodeToNil() {
        // A 0x7B record with a 1-byte payload (needs 2 for the u16) -> nil, not a guess.
        let shortSpO2 = OuraRecord(type: 0x7B, ringTimestamp: rt, payload: [0x03])
        XCTAssertNil(OuraDecoders.decodeSpO2Stable(shortSpO2))
        // A 0x46 temp with an ODD payload length -> nil.
        let oddTemp = OuraRecord(type: 0x46, ringTimestamp: rt, payload: [0x01, 0x02, 0x03])
        XCTAssertNil(OuraDecoders.decodeTemp(oddTemp))
        // An empty HRV body -> nil.
        XCTAssertNil(OuraDecoders.decodeHRV(OuraRecord(type: 0x5D, ringTimestamp: rt, payload: [])))
    }
}
