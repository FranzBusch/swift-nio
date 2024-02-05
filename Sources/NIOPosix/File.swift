//import NIOCore
//
//public protocol AsyncWriter {
//    associatedtype Element
//
//    mutating func write(_ element: Element) async throws
//    mutating func flush() async throws
//}
//
//public struct BufferedWriter<Writer: AsyncWriter>: AsyncWriter {
//    public typealias Element = Writer.Element
//    private var writer: Writer
//
//    private var buffer = [Element]()
//
//    public mutating func write(_ element: Element) async throws {
//        self.buffer.append(element)
//    }
//
//    public mutating func flush() async throws {
//        for element in self.buffer {
//            try await self.writer.write(element)
//        }
//        self.buffer.removeAll()
//        try await self.writer.flush()
//    }
//}
//
//@available(macOS 9999, *)
//public struct TCPConnection: AsyncSequence, AsyncWriter {
//    public typealias Element = ByteBuffer
//
//    private let socket: Socket
//    private let selector: Selector<NIORegistration>
//
//    public static func connect(
//        eventLoop: SelectableEventLoop,
//        address: SocketAddress,
//        _ body: (TCPConnection) async throws -> Void
//    ) async throws {
//        try await withTaskExecutorPreference(eventLoop) {
//            eventLoop.assertInEventLoop()
//            let socket = try Socket(
//                protocolFamily: address.protocol,
//               type: .stream,
//               protocolSubtype: .default,
//               setNonBlocking: true
//            )
//
//            let selector = try Selector<NIORegistration>()
//            let connection = try Self.init(socket: socket, selector: selector)
//
//            try await withThrowingTaskGroup(of: Void.self) { group in
//                group.addTask {
//                    try! await withCheckedThrowingContinuation { continuation in
//                        do {
//                            try selector.register(selectable: socket, interested: [.reset]) { eventSet, id in
//                                NIORegistration(channel: .continuation(continuation), interested: eventSet, registrationID: id)
//                            }
//                        } catch {
//                            continuation.resume(with: .failure(error))
//                        }
//                    }
//                }
//
//                // We should switch to an IO executor here
//                do {
//                    try socket.connect(to: address)
//                   try await body(connection)
//                   try socket.close()
//                    try selector.close()
//                } catch {
//                   try socket.close()
//                    try selector.close()
//                    throw error
//                }
//            }
//        }
//    }
//
//    private init(socket: Socket, selector: Selector<NIORegistration>) {
//        self.socket = socket
//        self.selector = selector
//    }
//
//    public func makeAsyncIterator() -> AsyncIterator {
//        return AsyncIterator(socket: self.socket, selector: self.selector)
//    }
//
//    public struct AsyncIterator: AsyncIteratorProtocol {
//        private let socket: Socket
//        private let allocator: ByteBufferAllocator
//        private let selector: Selector<NIORegistration>
//        init(socket: Socket, selector: Selector<NIORegistration>) {
//            self.socket = socket
//            self.selector = selector
//            self.allocator = .init()
//
//        }
//        public mutating func next() async throws -> Element? {
//            print("Reading next")
//            var buffer = self.allocator.buffer(capacity: 1024)
//
//            while true {
//                let result = try buffer.withMutableWritePointer {
//                    try socket.read(pointer: $0)
//                }
//                switch result {
//                case .wouldBlock(let t):
//                    print("woudlbock \(t)")
//                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
//                        do {
//                            try self.selector.reregister(selectable: self.socket, interested: [.read, .reset]) { eventSet, id in
//                                NIORegistration(channel: .continuation(continuation), interested: eventSet, registrationID: id)
//                            }
//                        } catch {
//                            continuation.resume(with: .failure(error))
//                        }
//                    }
//                case .processed(let t):
//                    print("read \(buffer.hexDump(format: .plain))")
//                    return buffer
//                }
//            }
//        }
//    }
//
//    public func write(_ element: ByteBuffer) async throws {
//        print("Writing \(element.hexDump(format: .plain))")
//        do {
//            let result = try element.withUnsafeReadableBytes {
//                try self.socket.write(pointer: $0)
//            }
//
//            switch result {
//            case .wouldBlock(let t):
//                print("writing Would block \(t)")
//            case .processed(let t):
//                print("writing Processed \(t)")
//            }
//        } catch {
//            print(error)
//            throw error
//        }
//    }
//
//    public func flush() async throws {
//        fatalError()
//    }
//}
//
