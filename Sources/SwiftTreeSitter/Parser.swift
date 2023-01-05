import Foundation
import tree_sitter

enum ParserError: Error {
    case languageIncompatible
    case languageFailure
    case languageInvalid
    case unsupportedEncoding(String.Encoding)
}

class DotProcessHandler {
	// Hold a reference to the parser so it survives
	fileprivate var parser: Parser? = nil
	private let internalParser: OpaquePointer
	private let dotProcess: Process
	private let dotInPipe = Pipe()
	private let dotOutPipe = Pipe()
	private let outputFileURL: URL

	init(internalParser: OpaquePointer, dotToolURL: URL, outputFolderURL: URL) {
		self.internalParser = internalParser

		try? FileManager.default.createDirectory(at: outputFolderURL, withIntermediateDirectories: true)

		self.dotProcess = Process()
		self.dotProcess.executableURL = dotToolURL
		self.dotProcess.arguments = ["-Tsvg"]

		self.dotProcess.standardInput = self.dotInPipe
		self.dotProcess.standardOutput = self.dotOutPipe

		let uniqueOutputFileName = UUID().uuidString.appending(".html")
		self.outputFileURL = outputFolderURL.appendingPathComponent(uniqueOutputFileName)

		var gotBytes = false

		self.dotOutPipe.fileHandleForReading.readabilityHandler = { [weak self] file in
			guard let strongSelf = self else { return }

			let data = file.availableData
			guard data.count > 0 else { return }

			if gotBytes == false {
				FileManager.default.createFile(atPath: strongSelf.outputFileURL.path, contents: "<!DOCTYPE html>\n<style>svg { width: 100%; }</style>\n\n".data(using: .utf8))
				gotBytes = true
			}
			
			do {
				let outputFileHandle = try FileHandle(forWritingTo: strongSelf.outputFileURL)
				outputFileHandle.seekToEndOfFile()
				outputFileHandle.write(file.availableData)
				outputFileHandle.closeFile()
			}
			catch {
				NSLog("Failed with \(error)")
			}
		}

		do {
			let copyFd = self.dotInPipe.fileHandleForWriting.fileDescriptor
			ts_parser_print_dot_graphs(self.internalParser, copyFd)
			try self.dotProcess.run()
		}
		catch {
			NSLog("Failed to launch dot - do you have graphviz installed?")
		}
	}

	func finishHandler() {
		self.dotInPipe.fileHandleForWriting.closeFile()
		self.dotProcess.waitUntilExit()
	}

	deinit {
		self.dotProcess.waitUntilExit()
	}
}

public class Parser {
    private let internalParser: OpaquePointer
    private let encoding: String.Encoding

#if DEBUG
	// In DEBUG builds, pipe debug information from tree-sitter to a
	// dot command that will convert it to SVG for easy viewing in a browser.
	public var dotToolURL: URL = URL(fileURLWithPath: "/opt/homebrew/bin/dot")
	public var dotFilesFolderURL = URL(fileURLWithPath: "/tmp/TreeSitterDebug")
	private let dotProcessHandler: DotProcessHandler?
#endif

    public init() {
        self.internalParser = ts_parser_new()
        self.encoding = String.nativeUTF16Encoding

#if DEBUG
		self.dotProcessHandler = DotProcessHandler(internalParser: self.internalParser, dotToolURL: self.dotToolURL, outputFolderURL: self.dotFilesFolderURL)
		//self.dotProcessHandler?.parser = self
#else
		self.dotProcessHandler = nil
#endif
    }

    deinit {
		self.dotProcessHandler?.finishHandler()
		RunLoop.current.run(until: Date(timeIntervalSinceNow: 2))
        ts_parser_delete(internalParser)
    }
}

extension Parser {
    public func setLanguage(_ language: Language) throws {
        try setLanguage(language.tsLanguage)
    }

    public func setLanguage(_ language: UnsafePointer<TSLanguage>) throws {
        let success = ts_parser_set_language(internalParser, language)

        if success == false {
            throw ParserError.languageFailure
        }
    }

	/// The ranges this parser will operate on.
	///
	/// This defaults to the entire document. This is useful
	/// for working with embedded languages.
	public var includedRanges: [TSRange] {
		get {
			var count: UInt32 = 0
			let tsRangePointer = ts_parser_included_ranges(internalParser, &count)

			let tsRangeBuffer = UnsafeBufferPointer<tree_sitter.TSRange>(start: tsRangePointer, count: Int(count))

			return tsRangeBuffer.map({ TSRange(internalRange: $0) })
		}
		set {
			let ranges = newValue.map({ $0.internalRange })

			ranges.withUnsafeBytes { bufferPtr in
				let count = newValue.count

				guard let ptr = bufferPtr.baseAddress?.bindMemory(to: tree_sitter.TSRange.self, capacity: count) else {
					preconditionFailure("unable to convert pointer")
				}

				ts_parser_set_included_ranges(internalParser, ptr, UInt32(count))
			}
		}
	}

	/// The maximum time interval the parser can run before halting.
	public var timeout: TimeInterval {
		get {
			let us = ts_parser_timeout_micros(internalParser)

			return TimeInterval(us) / 1000.0 / 1000.0
		}
		set {
			let us = UInt64(newValue * 1000.0 * 1000.0)

			ts_parser_set_timeout_micros(internalParser, us)
		}
	}
}

extension Parser {
    public typealias ReadBlock = (Int, Point) -> Data?

    public func parse(_ string: String) -> Tree? {
        guard let data = string.data(using: encoding) else { return nil }

        let dataLength = data.count

        let optionalTreePtr = data.withUnsafeBytes({ (byteBuffer) -> OpaquePointer? in
            guard let ptr = byteBuffer.baseAddress?.bindMemory(to: Int8.self, capacity: dataLength) else {
                return nil
            }

            return ts_parser_parse_string_encoding(internalParser, nil, ptr, UInt32(dataLength), TSInputEncodingUTF16)
        })

        return optionalTreePtr.flatMap({ Tree(internalTree: $0) })
    }

    public func parse(tree: Tree?, readBlock: @escaping ReadBlock) -> Tree? {
        let input = Input(encoding: TSInputEncodingUTF16, readBlock: readBlock)

        guard let internalInput = input.internalInput else {
            return nil
        }

        guard let newTree = ts_parser_parse(internalParser, tree?.internalTree, internalInput) else {
            return nil
        }

        return Tree(internalTree: newTree)
    }

    public func parse(tree: Tree?, string: String, limit: Int? = nil, chunkSize: Int = 2048) -> Tree? {
        let readFunction = Parser.readFunction(for: string, limit: limit, chunkSize: chunkSize)

        return parse(tree: tree, readBlock: readFunction)
    }

    public static func readFunction(for string: String, limit: Int? = nil, chunkSize: Int = 2048) -> Parser.ReadBlock {
        let usableLimit = limit ?? string.utf16.count
        let encoding = String.nativeUTF16Encoding

        return { (start, _) -> Data? in
            return string.data(at: start,
                               limit: usableLimit,
                               using: encoding,
                               chunkSize: chunkSize)
        }
    }
}
