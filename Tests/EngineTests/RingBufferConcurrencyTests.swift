import XCTest
import os
@testable import Core

final class RingBufferConcurrencyTests: XCTestCase {
    func testConcurrentReadWriteOverwriting() {
        let capacity = 8192
        let rb = RingBuffer(capacity: capacity)
        
        let iterationCount = 100_000
        let chunkSize = 512
        
        let writeExpectation = expectation(description: "Writer finished")
        let readExpectation = expectation(description: "Reader finished")
        
        let finishedLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        finishedLock.initialize(to: os_unfair_lock_s())
        defer {
            finishedLock.deinitialize(count: 1)
            finishedLock.deallocate()
        }
        
        var finishedVal = false
        let getFinished = { () -> Bool in
            os_unfair_lock_lock(finishedLock)
            defer { os_unfair_lock_unlock(finishedLock) }
            return finishedVal
        }
        let setFinished = { (val: Bool) in
            os_unfair_lock_lock(finishedLock)
            defer { os_unfair_lock_unlock(finishedLock) }
            finishedVal = val
        }
        
        // Writer thread
        Thread.detachNewThread {
            let writeData = [UInt8](repeating: 1, count: chunkSize)
            for i in 0..<iterationCount {
                var localData = writeData
                localData[0] = UInt8(i & 0xFF)
                let wrote = localData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
                XCTAssertEqual(wrote, chunkSize)
            }
            setFinished(true)
            writeExpectation.fulfill()
        }
        
        // Reader thread
        Thread.detachNewThread {
            var readData = [UInt8](repeating: 0, count: chunkSize)
            while !getFinished() || rb.bytesAvailableForRead >= chunkSize {
                let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
                if read == 0 {
                    Thread.sleep(forTimeInterval: 0.0001)
                }
            }
            readExpectation.fulfill()
        }
        
        wait(for: [writeExpectation, readExpectation], timeout: 20.0)
    }
}
