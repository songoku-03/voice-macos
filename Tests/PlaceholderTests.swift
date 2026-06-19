import Testing
@testable import Core

struct RingBufferTests {
    @Test func writeAndRead() {
        let buffer = RingBuffer(capacity: 10)
        
        // Initially empty
        #expect(buffer.bytesAvailableForRead == 0)
        #expect(buffer.bytesAvailableForWrite == 9) // capacity - 1
        
        // Write 4 bytes
        let dataToVal: [UInt8] = [1, 2, 3, 4]
        let written = dataToVal.withUnsafeBytes { ptr in
            buffer.write(ptr.baseAddress!, byteCount: 4)
        }
        #expect(written == 4)
        #expect(buffer.bytesAvailableForRead == 4)
        #expect(buffer.bytesAvailableForWrite == 5)
        
        // Read 4 bytes
        var readBuf = [UInt8](repeating: 0, count: 4)
        let read = readBuf.withUnsafeMutableBytes { ptr in
            buffer.read(ptr.baseAddress!, byteCount: 4)
        }
        #expect(read == 4)
        #expect(readBuf == [1, 2, 3, 4])
        #expect(buffer.bytesAvailableForRead == 0)
    }
    
    @Test func wrapping() {
        let buffer = RingBuffer(capacity: 10)
        
        // Write 6 bytes
        let data1: [UInt8] = [1, 2, 3, 4, 5, 6]
        data1.withUnsafeBytes { ptr in
            buffer.write(ptr.baseAddress!, byteCount: 6)
        }
        
        // Read 4 bytes
        var readBuf = [UInt8](repeating: 0, count: 4)
        readBuf.withUnsafeMutableBytes { ptr in
            buffer.read(ptr.baseAddress!, byteCount: 4)
        }
        #expect(readBuf == [1, 2, 3, 4])
        
        // Now readOffset is 4, writeOffset is 6. Available for read: 2.
        // Available for write: 10 - 1 - 2 = 7.
        // Let's write 5 bytes, which will wrap.
        let data2: [UInt8] = [7, 8, 9, 10, 11]
        let written = data2.withUnsafeBytes { ptr in
            buffer.write(ptr.baseAddress!, byteCount: 5)
        }
        #expect(written == 5)
        
        // Read remaining 7 bytes
        var readBuf2 = [UInt8](repeating: 0, count: 7)
        readBuf2.withUnsafeMutableBytes { ptr in
            buffer.read(ptr.baseAddress!, byteCount: 7)
        }
        #expect(readBuf2 == [5, 6, 7, 8, 9, 10, 11])
    }
}
