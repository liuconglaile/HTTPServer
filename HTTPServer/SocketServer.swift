//
//  SocketServer.swift
//  HTTPServer
//
//  Created by Daniel Eggert on 03/02/2015.
//  Copyright (c) 2015 objc.io. All rights reserved.
//

import Foundation
import SocketHelpers



public enum SocketError : ErrorType {
    case Error(POSIXError, String)
    case NoPortAvailable
}



private func posixResult(functionName: String, call: () -> CInt) throws -> CInt {
    let result = call()
    if 0 <= result {
        return result
    }
    throw SocketError.Error(POSIXError(rawValue: errno)!, functionName)
}



private let INADDR_ANY = in_addr(s_addr: in_addr_t(0))


public class SocketServer {
    
    public typealias Accept = (dispatch_io_t, SocketAddress) -> ()
    
    public let port: UInt16
    
    /// The accept handler will be called with a suspended dispatch I/O channel and the client's 'struct sockaddr' wrapped in an SocketAddress.
    public static func withAcceptHandler(handler: Accept) throws -> SocketServer {
        let serverSocket = try posixResult("socket(2)") { socket(PF_INET, SOCK_STREAM, IPPROTO_TCP) }
        let port = try SocketServer.bindSocketToPort(serverSocket)
        try posixResult("fcntl(2) F_SETFL") { SocketHelper_fcntl_setFlag(serverSocket, O_NONBLOCK) }
        return SocketServer(serverSocket: serverSocket, port: port, handler: handler)
    }
    
    let serverSocket: Int32
    let acceptSource: dispatch_source_t
    
    private init(serverSocket ss: Int32, port p: UInt16, handler: Accept) {
        serverSocket = ss
        port = p
        acceptSource = SocketServer.createDispatchSourceWithSocket(ss, port: p, handler: handler)
        
        // Resume the source:
        dispatch_resume(acceptSource);
        
        // Listen on the socket:
        let listenResult = listen(serverSocket, SOMAXCONN);
        assert(listenResult == 0, "Failed to listen(): \(String.fromCString(strerror(errno))) (\(errno))")
    }
    
    private static func createDispatchSourceWithSocket(socket: Int32, port: UInt16, handler: Accept) -> dispatch_source_t {
        let queueName = "server on port \(port)"
        let queue = dispatch_queue_create(queueName, DISPATCH_QUEUE_CONCURRENT);
        let source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, UInt(socket), 0, queue)
        
        dispatch_source_set_event_handler(source) {
            //            [unowned self] in
            let pendingConnectionCount = dispatch_source_get_data(source)
            for _ in 0..<pendingConnectionCount {
                
                if let (clientAddress, clientSocket) = SocketServer.acceptOnSocket(socket) {
                    let clientChannel = dispatch_io_create(DISPATCH_IO_STREAM, clientSocket, queue) {
                        (error) in
                        if error != 0 {
                            print("Error on socket \(clientSocket): \(strerror(error)) (\(error))")
                        }
                    }
                    handler(clientChannel, SocketAddress(data: clientAddress))
                }
            }
        }
        return source
    }
    
    /// Calls accept(2) and returns the resulting sockaddr_in
    private static func acceptOnSocket(socket: Int32) -> (NSData,Int32)? {
        // Since accept(2) takes a pointer to a buffer, and returns the length by reference
        // we need to set up mutable data and a mutable pointer:
        let clientAddress = NSMutableData(length: Int(SOCK_MAXADDRLEN))!
        let p = UnsafeMutablePointer<sockaddr>(clientAddress.bytes)
        let lengthPointer = UnsafeMutablePointer<socklen_t>.alloc(1)
        lengthPointer.initialize(socklen_t(sizeof(sockaddr_in)))
        let clientSocket = accept(socket, p, lengthPointer)
        let length = Int(lengthPointer.memory)
        lengthPointer.destroy()
        
        switch clientSocket {
        case -1:
            print("Failed to accept() a connection: \(String.fromCString(strerror(errno))) (\(errno))")
            return nil
        default:
            clientAddress.length = length
            return (clientAddress, clientSocket)
        }
    }
    
    private static func bindSocketToPort(socket: Int32) throws -> UInt16 {
        // We'll loop through some ports and pick the first one that's available:
        for p in UInt16(8000 + arc4random_uniform(1000))...10000 {
            let portN = in_port_t(CFSwapInt16HostToBig(p))
            let addr = UnsafeMutablePointer<sockaddr_in>.alloc(1)
            addr.initialize(sockaddr_in(sin_len: 0, sin_family: sa_family_t(AF_INET), sin_port: portN, sin_addr: INADDR_ANY, sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)))
            defer { addr.destroy() }
            let addrP = UnsafePointer<sockaddr>(addr)
            do {
                try posixResult("bind(2)") { bind(socket, addrP, socklen_t(sizeof(sockaddr))) }
                return p
            } catch SocketError.Error(POSIXError.EADDRINUSE, _) {
                continue
            }
        }
        throw SocketError.NoPortAvailable
    }
    
    
    deinit {
        dispatch_source_cancel(acceptSource)
        close(serverSocket)
    }
    
    /// A socket address. Wraps a sockaddr_in.
    public struct SocketAddress : CustomStringConvertible {
        init(data: NSData) {
            self.addressData = data
        }
        let addressData: NSData
    
        public var description: String {
            if let addr = inAddrDescription, let port = inPortDescription {
                switch inFamily {
                case sa_family_t(AF_INET6):
                    return "[" + addr + "]:" + port
                case sa_family_t(AF_INET):
                    return addr + ":" + port
                default:
                    break
                }
            }
            return "<unknown>"
        }
    }
}

extension SocketServer.SocketAddress {
    private var inFamily: sa_family_t {
        let pointer = UnsafePointer<sockaddr_in>(addressData.bytes)
        return pointer.memory.sin_family
    }
    private var inAddrDescription: String? {
        let pointer = UnsafePointer<sockaddr_in>(addressData.bytes)
        switch inFamily {
        case sa_family_t(AF_INET6):
            fallthrough
        case sa_family_t(AF_INET):
            let data = NSMutableData(length: Int(INET6_ADDRSTRLEN))!
            let inAddr = (UnsafePointer<UInt8>(pointer) + offsetOf__sin_addr__in__sockaddr_in())
            if inet_ntop(AF_INET, inAddr, UnsafeMutablePointer<Int8>(data.mutableBytes), socklen_t(data.length)) != UnsafePointer<Int8>() {
                return (NSString(data: data, encoding: NSUTF8StringEncoding)! as String)                }
            return nil
        default:
            return nil
        }
    }
    private var inPortDescription: String? {
        let pointer = UnsafePointer<sockaddr_in>(addressData.bytes)
        switch inFamily {
        case sa_family_t(AF_INET6):
            fallthrough
        case sa_family_t(AF_INET):
            return "\(CFSwapInt16BigToHost(UInt16(pointer.memory.sin_port)))"
        default:
            return nil
        }
    }
}
