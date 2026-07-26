import Testing
import Foundation
import os
@testable import Core

@Suite struct RingBufferConcurrencyTests {
    @Test func concurrentReadWriteOverwriting() {
        let capacity = 8192
        let rb = RingBuffer(capacity: capacity)
        
        let iterationCount = 100_000
        let chunkSize = 512
        
        let group = DispatchGroup()
        
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
        group.enter()
        Thread.detachNewThread {
            let writeData = [UInt8](repeating: 1, count: chunkSize)
            for i in 0..<iterationCount {
                var localData = writeData
                localData[0] = UInt8(i & 0xFF)
                let wrote = localData.withUnsafeBytes { rb.writeOverwriting($0.baseAddress!, byteCount: chunkSize) }
                #expect(wrote == chunkSize)
            }
            setFinished(true)
            group.leave()
        }
        
        // Reader thread
        group.enter()
        Thread.detachNewThread {
            var readData = [UInt8](repeating: 0, count: chunkSize)
            while !getFinished() || rb.bytesAvailableForRead >= chunkSize {
                let read = readData.withUnsafeMutableBytes { rb.read($0.baseAddress!, byteCount: chunkSize) }
                if read == 0 {
                    Thread.sleep(forTimeInterval: 0.0001)
                }
            }
            group.leave()
        }
        
        #expect(group.wait(timeout: .now() + 20.0) == .success)
    }
}
