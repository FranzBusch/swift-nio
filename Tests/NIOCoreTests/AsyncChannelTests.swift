//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2022 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest

final class AsyncChannelTests: XCTestCase {
    func testAsyncChannelBasicFunctionality() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            let iterator = wrapped.inboundStream.makeAsyncIterator()
            try await channel.writeInbound("hello")
            let firstRead = try await iterator.next()
            XCTAssertEqual(firstRead, "hello")

            try await channel.writeInbound("world")
            let secondRead = try await iterator.next()
            XCTAssertEqual(secondRead, "world")

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireUserInboundEventTriggered(ChannelEvent.inputClosed)
            }

            let thirdRead = try await iterator.next()
            XCTAssertNil(thirdRead)

            try await channel.close()
        }
    }

    func testAsyncChannelBasicWrites() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await wrapped.writeAndFlush("hello")
            try await wrapped.writeAndFlush("world")

            let firstRead = try await channel.waitForOutboundWrite(as: String.self)
            let secondRead = try await channel.waitForOutboundWrite(as: String.self)

            XCTAssertEqual(firstRead, "hello")
            XCTAssertEqual(secondRead, "world")

            try await channel.close()
        }
    }

    func testDroppingTheWriterClosesTheWriteSideOfTheChannel() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let closeRecorder = CloseRecorder()
            try await channel.pipeline.addHandler(closeRecorder)

            let inboundReader: NIOInboundChannelStream<Never>

            do {
                let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: Never.self)
                inboundReader = wrapped.inboundStream

                try await channel.testingEventLoop.executeInContext {
                    XCTAssertEqual(0, closeRecorder.outboundCloses)
                }
            }

            try await channel.testingEventLoop.executeInContext {
                XCTAssertEqual(1, closeRecorder.outboundCloses)
            }

            // Just use this to keep the inbound reader alive.
            withExtendedLifetime(inboundReader) { }
            channel.close(promise: nil)
        }
    }

    func testReadsArePropagated() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            try await channel.writeInbound("hello")
            let propagated = try await channel.readInbound(as: String.self)
            XCTAssertEqual(propagated, "hello")

            try await channel.close().get()

            let reads = try await Array(wrapped.inboundStream)
            XCTAssertEqual(reads, ["hello"])
        }
    }

    func testErrorsArePropagatedButAfterReads() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            try await channel.writeInbound("hello")
            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireErrorCaught(TestError.bang)
            }

            let iterator = wrapped.inboundStream.makeAsyncIterator()
            let first = try await iterator.next()
            XCTAssertEqual(first, "hello")

            try await XCTAssertThrowsError(await iterator.next()) { error in
                XCTAssertEqual(error as? TestError, .bang)
            }
        }
    }

    func testErrorsArePropagatedToWriters() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.fireErrorCaught(TestError.bang)
            }

            try await XCTAssertThrowsError(await wrapped.writeAndFlush("hello")) { error in
                XCTAssertEqual(error as? TestError, .bang)
            }
        }
    }

    func testChannelBecomingNonWritableDelaysWriters() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: Never.self, outboundOut: String.self)

            try await channel.testingEventLoop.executeInContext {
                channel.isWritable = false
                channel.pipeline.fireChannelWritabilityChanged()
            }

            let lock = NIOLockedValueBox(false)

            await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await wrapped.writeAndFlush("hello")
                    lock.withLockedValue {
                        XCTAssertTrue($0)
                    }
                }

                group.addTask {
                    // 10ms sleep before we wake the thing up
                    try await Task.sleep(nanoseconds: 10_000_000)

                    try await channel.testingEventLoop.executeInContext {
                        channel.isWritable = true
                        lock.withLockedValue { $0 = true }
                        channel.pipeline.fireChannelWritabilityChanged()
                    }
                }
            }

            try await channel.close().get()
        }
    }

    func testBufferDropsReadsIfTheReaderIsGone() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            try await channel.pipeline.addHandler(CloseSuppressor()).get()
            do {
                // Create the NIOAsyncChannel, then drop it. The handler will still be in the pipeline.
                _ = try await NIOAsyncChannel(wrapping: channel, inboundIn: Sentinel.self, outboundOut: Never.self)
            }

            weak var sentinel: Sentinel? = nil
            do {
                let strongSentinel: Sentinel? = Sentinel()
                sentinel = strongSentinel!
                try await XCTAsyncAssertNotNil(try await channel.pipeline.handler(type: NIOAsyncChannelAdapterHandler<Sentinel>.self).get())
                try await channel.writeInbound(strongSentinel!)
                _ = try await channel.readInbound(as: Sentinel.self)
            }

            XCTAssertNil(sentinel)
        }
    }

    func testRemovingTheHandlerTerminatesTheInboundStream() {
        guard #available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *) else { return }
        XCTAsyncTest(timeout: 5) {
            let channel = NIOAsyncTestingChannel()
            let wrapped = try await NIOAsyncChannel(wrapping: channel, inboundIn: String.self, outboundOut: Never.self)

            try await channel.testingEventLoop.executeInContext {
                channel.pipeline.syncOperations.fireChannelRead(NIOAny("hello"))
                _ = channel.pipeline.context(handlerType: NIOAsyncChannelAdapterHandler<String>.self).flatMap {
                    channel.pipeline.removeHandler(context: $0)
                }
            }
            await channel.testingEventLoop.run()

            let reads = try await Array(wrapped.inboundStream)
            XCTAssertEqual(reads, ["hello"])
        }
    }
}

final class CloseRecorder: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    var outboundCloses = 0

    init() { }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        if case .output = mode {
            self.outboundCloses += 1
        }

        context.close(mode: mode, promise: promise)
    }
}

final class CloseSuppressor: ChannelOutboundHandler {
    typealias OutboundIn = Any
    typealias OutboundOut = Any

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        // We drop the close here.
        promise?.fail(TestError.bang)
    }
}

fileprivate enum TestError: Error {
    case bang
}

extension Array {
    init<AS: AsyncSequence>(_ sequence: AS) async throws where AS.Element == Self.Element {
        self = []

        for try await nextElement in sequence {
            self.append(nextElement)
        }
    }
}

final fileprivate class Sentinel { }


