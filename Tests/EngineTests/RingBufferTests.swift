import Testing
@testable import Core

@Suite struct RingBufferTests {
    @Test func basicRoundTrip() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [1, 2, 3, 4, 5]
        let written = src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: src.count) }
        #expect(written == 5)
        #expect(rb.bytesAvailableForRead == 5)

        var dst = [UInt8](repeating: 0, count: 5)
        let readCount = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }
        #expect(readCount == 5)
        #expect(dst == src)
    }

    @Test func readUnderflow() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [10, 20]
        _ = src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 2) }

        var dst = [UInt8](repeating: 0, count: 5)
        let readCount = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }
        #expect(readCount == 0)
        #expect(rb.bytesAvailableForRead == 2, "data untouched")
    }

    @Test func bytesAvailableForWrite() {
        let rb = RingBuffer(capacity: 16) // usable = 15
        #expect(rb.bytesAvailableForWrite == 15)

        let src = [UInt8](repeating: 0xAA, count: 10)
        _ = src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 10) }
        #expect(rb.bytesAvailableForWrite == 5)
    }

    @Test func writeDropsEntireBlockWhenBufferIsFull() {
        let rb = RingBuffer(capacity: 8)
        let a = [UInt8](repeating: 0xAA, count: 7)
        _ = a.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 7) }
        #expect(rb.bytesAvailableForWrite == 0)

        let b: [UInt8] = [0xBB]
        let wrote = b.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 1) }
        #expect(wrote == 0, "write() drops data when full")
    }

    @Test func writeOverwritingStoresDataWhenBufferHasSpace() {
        let rb = RingBuffer(capacity: 64)
        let src: [UInt8] = [1, 2, 3]
        let wrote = src.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }
        #expect(wrote == 3)

        var dst = [UInt8](repeating: 0, count: 3)
        _ = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 3) }
        #expect(dst == src)
    }

    @Test func writeOverwritingDiscardsOldestDataWhenFull() {
        let rb = RingBuffer(capacity: 8) // usable = 7
        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        _ = a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 7) }

        let b: [UInt8] = [8, 9, 10]
        let wrote = b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }
        #expect(wrote == 3, "writeOverwriting must succeed when full")

        #expect(rb.bytesAvailableForRead == 7)
        var dst = [UInt8](repeating: 0, count: 7)
        _ = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        #expect(dst == [4, 5, 6, 7, 8, 9, 10])
    }

    @Test func writeOverwritingPartialSpace() {
        let rb = RingBuffer(capacity: 8)
        let a: [UInt8] = [1, 2, 3, 4, 5]
        _ = a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 5) }

        let b: [UInt8] = [10, 11, 12, 13]
        let wrote = b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 4) }
        #expect(wrote == 4)

        #expect(rb.bytesAvailableForRead == 7)
        var dst = [UInt8](repeating: 0, count: 7)
        _ = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        #expect(dst == [3, 4, 5, 10, 11, 12, 13])
    }

    @Test func writeOverwritingRejectsByteCountGreaterThanOrEqualToCapacity() {
        let rb = RingBuffer(capacity: 8)
        let big = [UInt8](repeating: 0xFF, count: 8)
        let wrote = big.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 8) }
        #expect(wrote == 0)
    }

    @Test func writeOverwritingRejectsZeroLength() {
        let rb = RingBuffer(capacity: 8)
        let src: [UInt8] = [1]
        let wrote = src.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 0) }
        #expect(wrote == 0)
    }

    @Test func wrapAroundWriteRead() {
        let rb = RingBuffer(capacity: 8)
        let a = [UInt8](repeating: 0xAA, count: 5)
        _ = a.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 5) }
        var trash = [UInt8](repeating: 0, count: 5)
        _ = trash.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }

        let b: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        _ = b.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 7) }

        var dst = [UInt8](repeating: 0, count: 7)
        _ = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        #expect(dst == b)
    }

    @Test func writeOverwritingWrapAround() {
        let rb = RingBuffer(capacity: 8)
        let padding = [UInt8](repeating: 0, count: 5)
        _ = padding.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 5) }
        var trash = [UInt8](repeating: 0, count: 5)
        _ = trash.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 5) }

        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7]
        _ = a.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 7) }

        let b: [UInt8] = [8, 9, 10]
        _ = b.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: 3) }

        var dst = [UInt8](repeating: 0, count: 7)
        _ = dst.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: 7) }
        #expect(dst == [4, 5, 6, 7, 8, 9, 10])
    }

    @Test func clearResetsBuffer() {
        let rb = RingBuffer(capacity: 16)
        let src = [UInt8](repeating: 0xCC, count: 10)
        _ = src.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: 10) }
        #expect(rb.bytesAvailableForRead == 10)
        rb.clear()
        #expect(rb.bytesAvailableForRead == 0)
        #expect(rb.bytesAvailableForWrite == 15)
    }

    @Test func audioPipelineWriteOverwritingNeverStarvesReader() {
        let rb = RingBuffer(capacity: 8192)
        let chunkSize = 960
        var writeData = [UInt8](repeating: 0, count: chunkSize)
        var readData = [UInt8](repeating: 0, count: chunkSize)

        for i in 0..<10 {
            writeData[0] = UInt8(i & 0xFF)
            _ = writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
        }
        #expect(rb.bytesAvailableForRead > 0, "Buffer must have data")

        let available = rb.bytesAvailableForRead
        let chunksToRead = available / chunkSize
        #expect(chunksToRead > 0, "Reader must find data — not starved")

        for _ in 0..<chunksToRead {
            let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
            #expect(read == chunkSize)
        }

        for i in 0..<100 {
            writeData[0] = UInt8(i & 0xFF)
            _ = writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
            let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
            #expect(read == chunkSize, "Steady-state: reader should always get data")
        }
    }

    @Test func originalWriteCausesStarvation() {
        let rb = RingBuffer(capacity: 4096)
        let chunkSize = 960
        var writeData = [UInt8](repeating: 0xAA, count: chunkSize)
        var lastWrote = chunkSize
        while lastWrote > 0 {
            lastWrote = writeData.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: chunkSize) }
        }
        writeData = [UInt8](repeating: 0xBB, count: chunkSize)
        let dropped = writeData.withUnsafeBytes { rb.write($0.baseAddress!, byteCount: chunkSize) }
        #expect(dropped == 0, "write() drops data when full — this is the bug")
    }

    @Test func writeOverwritingNeverDropsUnderPressure() {
        let rb = RingBuffer(capacity: 4096)
        let chunkSize = 960
        var readData = [UInt8](repeating: 0, count: chunkSize)

        for i in 0..<20 {
            var writeData = [UInt8](repeating: UInt8(i & 0xFF), count: chunkSize)
            _ = writeData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
        }

        #expect(rb.bytesAvailableForRead > 0, "writeOverwriting keeps data available")
        let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
        #expect(read == chunkSize, "Reader gets a full chunk — no starvation")
    }
}
