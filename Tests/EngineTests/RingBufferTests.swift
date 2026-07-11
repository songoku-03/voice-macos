import XCTest
@testable import Core

final class RingBufferTests: XCTestCase {
    func testBasicRoundTrip() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [1, 2, 3, 4, 5]
        let written = src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: src.count) }
        XCTAssertEqual(written, 5)
        XCTAssertEqual(rb.bytesAvailableForRead, 5)

        var dst = [UInt8](repeating: 0, count: 5)
        let readCount = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }
        XCTAssertEqual(readCount, 5)
        XCTAssertEqual(dst, src)
    }

    func testReadUnderflow() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [10, 20]
        src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 2) }

        var dst = [UInt8](repeating: 0, count: 5)
        let readCount = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }
        XCTAssertEqual(readCount, 0)
        XCTAssertEqual(rb.bytesAvailableForRead, 2, "data untouched")
    }

    func testBytesAvailableForWrite() {
        let rb = RingBuffer(capacity: 16) // usable = 15
        XCTAssertEqual(rb.bytesAvailableForWrite, 15)

        let src = [UInt8](repeating: 0xAA, count: 10)
        src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 10) }
        XCTAssertEqual(rb.bytesAvailableForWrite, 5)
    }

    func testWriteDropsEntireBlockWhenBufferIsFull() {
        let rb = RingBuffer(capacity: 8)
        let a = [UInt8](repeating: 0xAA, count: 7)
        a.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 7) }
        XCTAssertEqual(rb.bytesAvailableForWrite, 0)

        let b: [UInt8] = [0xBB]
        let wrote = b.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 1) }
        XCTAssertEqual(wrote, 0, "write() drops data when full")
    }

    func testWriteOverwritingStoresDataWhenBufferHasSpace() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [1, 2, 3]
        let wrote = src.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }
        XCTAssertEqual(wrote, 3)

        var dst = [UInt8](repeating: 0, count: 3)
        dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 3) }
        XCTAssertEqual(dst, src)
    }

    func testWriteOverwritingDiscardsOldestDataWhenFull() {
        let rb = RingBuffer(capacity: 8) // usable = 7
        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 7) }

        let b: [UInt8] = [8, 9, 10]
        let wrote = b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }
        XCTAssertEqual(wrote, 3, "writeOverwriting must succeed when full")

        XCTAssertEqual(rb.bytesAvailableForRead, 7)
        var dst = [UInt8](repeating: 0, count: 7)
        dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        XCTAssertEqual(dst, [4, 5, 6, 7, 8, 9, 10])
    }

    func testWriteOverwritingPartialSpace() {
        let rb = RingBuffer(capacity: 8)
        let a: [UInt8] = [1, 2, 3, 4, 5]
        a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 5) }

        let b: [UInt8] = [10, 11, 12, 13]
        let wrote = b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 4) }
        XCTAssertEqual(wrote, 4)

        XCTAssertEqual(rb.bytesAvailableForRead, 7)
        var dst = [UInt8](repeating: 0, count: 7)
        dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        XCTAssertEqual(dst, [3, 4, 5, 10, 11, 12, 13])
    }

    func testWriteOverwritingRejectsByteCountGreaterThanOrEqualToCapacity() {
        let rb = RingBuffer(capacity: 8)
        let big = [UInt8](repeating: 0xFF, count: 8)
        let wrote = big.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 8) }
        XCTAssertEqual(wrote, 0)
    }

    func testWriteOverwritingRejectsZeroLength() {
        let rb = RingBuffer(capacity: 8)
        let src: [UInt8] = [1]
        let wrote = src.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 0) }
        XCTAssertEqual(wrote, 0)
    }

    func testWrapAroundWriteRead() {
        let rb = RingBuffer(capacity: 8)
        let a = [UInt8](repeating: 0xAA, count: 5)
        a.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 5) }
        var trash = [UInt8](repeating: 0, count: 5)
        trash.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }

        let b: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        b.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 7) }

        var dst = [UInt8](repeating: 0, count: 7)
        dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        XCTAssertEqual(dst, b)
    }

    func testWriteOverwritingWrapAround() {
        let rb = RingBuffer(capacity: 8)
        let padding = [UInt8](repeating: 0, count: 5)
        padding.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 5) }
        var trash = [UInt8](repeating: 0, count: 5)
        trash.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }

        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 7) }

        let b: [UInt8] = [8, 9, 10]
        b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }

        var dst = [UInt8](repeating: 0, count: 7)
        dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        XCTAssertEqual(dst, [4, 5, 6, 7, 8, 9, 10])
    }

    func testClearResetsBuffer() {
        let rb = RingBuffer(capacity: 16)
        let src = [UInt8](repeating: 0xCC, count: 10)
        src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 10) }
        XCTAssertEqual(rb.bytesAvailableForRead, 10)
        rb.clear()
        XCTAssertEqual(rb.bytesAvailableForRead, 0)
        XCTAssertEqual(rb.bytesAvailableForWrite, 15)
    }

    func testAudioPipelineWriteOverwritingNeverStarvesReader() {
        let rb = RingBuffer(capacity: 8192)
        let chunkSize = 960
        var writeData = [UInt8](repeating: 0, count: chunkSize)
        var readData = [UInt8](repeating: 0, count: chunkSize)

        for i in 0..<10 {
            writeData[0] = UInt8(i & 0xFF)
            writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
        }
        XCTAssertGreaterThan(rb.bytesAvailableForRead, 0, "Buffer must have data")

        let available = rb.bytesAvailableForRead
        let chunksToRead = available / chunkSize
        XCTAssertGreaterThan(chunksToRead, 0, "Reader must find data — not starved")

        for _ in 0..<chunksToRead {
            let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
            XCTAssertEqual(read, chunkSize)
        }

        for i in 0..<100 {
            writeData[0] = UInt8(i & 0xFF)
            writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
            let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
            XCTAssertEqual(read, chunkSize, "Steady-state: reader should always get data")
        }
    }

    func testOriginalWriteCausesStarvation() {
        let rb = RingBuffer(capacity: 4096)
        let chunkSize = 960
        var writeData = [UInt8](repeating: 0xAA, count: chunkSize)
        var lastWrote = chunkSize
        while lastWrote > 0 {
            lastWrote = writeData.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: chunkSize) }
        }
        writeData = [UInt8](repeating: 0xBB, count: chunkSize)
        let dropped = writeData.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: chunkSize) }
        XCTAssertEqual(dropped, 0, "write() drops data when full — this is the bug")
    }

    func testWriteOverwritingNeverDropsUnderPressure() {
        let rb = RingBuffer(capacity: 4096)
        let chunkSize = 960
        var readData = [UInt8](repeating: 0, count: chunkSize)

        for i in 0..<20 {
            var writeData = [UInt8](repeating: UInt8(i & 0xFF), count: chunkSize)
            writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
        }

        XCTAssertGreaterThan(rb.bytesAvailableForRead, 0, "writeOverwriting keeps data available")
        let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
        XCTAssertEqual(read, chunkSize, "Reader gets a full chunk — no starvation")
    }
}
