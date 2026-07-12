import Foundation
import os

public final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let buffer: UnsafeMutablePointer<UInt8>
    private let readOffsetPtr: UnsafeMutablePointer<Int32>
    private let writeOffsetPtr: UnsafeMutablePointer<Int32>
    
    public init(capacity: Int) {
        self.capacity = capacity
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        self.buffer.initialize(repeating: 0, count: capacity)
        
        self.readOffsetPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.readOffsetPtr.initialize(to: 0)
        
        self.writeOffsetPtr = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        self.writeOffsetPtr.initialize(to: 0)
    }
    
    deinit {
        buffer.deallocate()
        readOffsetPtr.deinitialize(count: 1)
        readOffsetPtr.deallocate()
        writeOffsetPtr.deinitialize(count: 1)
        writeOffsetPtr.deallocate()
    }
    
    public var bytesAvailableForRead: Int {
        let w = Int(OSAtomicAdd32Barrier(0, writeOffsetPtr))
        let r = Int(OSAtomicAdd32Barrier(0, readOffsetPtr))
        if w >= r {
            return w - r
        } else {
            return capacity - r + w
        }
    }
    
    public var bytesAvailableForWrite: Int {
        let w = Int(OSAtomicAdd32Barrier(0, writeOffsetPtr))
        let r = Int(OSAtomicAdd32Barrier(0, readOffsetPtr))
        let used = w >= r ? (w - r) : (capacity - r + w)
        return capacity - 1 - used
    }
    
    @discardableResult
    public func write(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        while true {
            let w = OSAtomicAdd32Barrier(0, writeOffsetPtr)
            let r = OSAtomicAdd32Barrier(0, readOffsetPtr)
            
            let wInt = Int(w)
            let rInt = Int(r)
            
            let used = wInt >= rInt ? (wInt - rInt) : (capacity - rInt + wInt)
            let available = capacity - 1 - used
            guard available >= byteCount else {
                return 0 // Buffer full / not enough space
            }
            
            let firstPart = min(byteCount, capacity - wInt)
            rawBuffer.advanced(by: wInt).copyMemory(from: data, byteCount: firstPart)
            
            if firstPart < byteCount {
                let secondPart = byteCount - firstPart
                rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: secondPart)
            }
            
            let nextW = Int32((wInt + byteCount) % capacity)
            if OSAtomicCompareAndSwap32Barrier(w, nextW, writeOffsetPtr) {
                return byteCount
            }
        }
    }
    
    /// Write data into the ring buffer, overwriting oldest unread data when full.
    @discardableResult
    public func writeOverwriting(_ data: UnsafeRawPointer, byteCount: Int) -> Int {
        guard byteCount > 0 && byteCount < capacity else { return 0 }
        let rawBuffer = UnsafeMutableRawPointer(buffer)
        
        while true {
            let w = OSAtomicAdd32Barrier(0, writeOffsetPtr)
            let r = OSAtomicAdd32Barrier(0, readOffsetPtr)
            
            let wInt = Int(w)
            let rInt = Int(r)
            let used = wInt >= rInt ? (wInt - rInt) : (capacity - rInt + wInt)
            let available = capacity - 1 - used
            
            var newR = r
            if available < byteCount {
                let deficit = byteCount - available
                newR = Int32((rInt + deficit) % capacity)
                if !OSAtomicCompareAndSwap32Barrier(r, newR, readOffsetPtr) {
                    continue
                }
            }
            
            // Now write the data
            let firstPart = min(byteCount, capacity - wInt)
            rawBuffer.advanced(by: wInt).copyMemory(from: data, byteCount: firstPart)
            
            if firstPart < byteCount {
                let secondPart = byteCount - firstPart
                rawBuffer.copyMemory(from: data.advanced(by: firstPart), byteCount: secondPart)
            }
            
            let nextW = Int32((wInt + byteCount) % capacity)
            if OSAtomicCompareAndSwap32Barrier(w, nextW, writeOffsetPtr) {
                return byteCount
            }
        }
    }
    
    /// Read data from the ring buffer.
    @discardableResult
    public func read(_ dest: UnsafeMutableRawPointer, byteCount: Int) -> Int {
        let rawBuffer = UnsafeRawPointer(buffer)
        while true {
            let r = OSAtomicAdd32Barrier(0, readOffsetPtr)
            let w = OSAtomicAdd32Barrier(0, writeOffsetPtr)
            
            let rInt = Int(r)
            let wInt = Int(w)
            
            let available = wInt >= rInt ? (wInt - rInt) : (capacity - rInt + wInt)
            guard available >= byteCount else {
                return 0 // Not enough data
            }
            
            let firstPart = min(byteCount, capacity - rInt)
            dest.copyMemory(from: rawBuffer.advanced(by: rInt), byteCount: firstPart)
            
            if firstPart < byteCount {
                let secondPart = byteCount - firstPart
                dest.advanced(by: firstPart).copyMemory(from: rawBuffer, byteCount: secondPart)
            }
            
            let nextR = Int32((rInt + byteCount) % capacity)
            if OSAtomicCompareAndSwap32Barrier(r, nextR, readOffsetPtr) {
                return byteCount
            }
        }
    }
    
    public func clear() {
        while true {
            let r = OSAtomicAdd32Barrier(0, readOffsetPtr)
            if OSAtomicCompareAndSwap32Barrier(r, 0, readOffsetPtr) {
                break
            }
        }
        while true {
            let w = OSAtomicAdd32Barrier(0, writeOffsetPtr)
            if OSAtomicCompareAndSwap32Barrier(w, 0, writeOffsetPtr) {
                break
            }
        }
    }
}
