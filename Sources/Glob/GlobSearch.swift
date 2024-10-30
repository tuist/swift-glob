import Foundation

/// The result of a custom matcher for searching directory components
public struct MatchResult {
	/// When true, the url will be added to the output
	var matches: Bool
	/// When true, the descendents of a directory will be skipped entirely
	///
	/// This has no effect if the url is not a directory.
	var skipDescendents: Bool
}

/// Recursively search the contents of a directory, filtering by the provided patterns
///
/// Searching is done asynchronously, with each subdirectory searched in parallel. Results are emitted as they are found.
///
/// The results are returned as they are matched and do not have a consistent order to them. If you need the results sorted, wait for the entire search to complete and then sort the results.
///
/// - Parameters:
///   - baseURL: The directory to search, defaults to the current working directory.
///   - include: When provided, only includes results that match these patterns.
///   - exclude: When provided, ignore results that match these patterns. If a directory matches an exclude pattern, none of it's descendents will be matched.
///   - keys: An array of keys that identify the properties that you want pre-fetched for each returned url. The values for these keys are cached in the corresponding URL objects. You may specify nil for this parameter. For a list of keys you can specify, see [Common File System Resource Keys](https://developer.apple.com/documentation/corefoundation/cfurl/common_file_system_resource_keys).
///   - skipHiddenFiles: When true, hidden files will not be returned.
/// - Returns: An async collection of urls.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
public func search(
	directory baseURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
	include: [Pattern] = [],
	exclude: [Pattern] = [],
	includingPropertiesForKeys keys: [URLResourceKey] = [],
	skipHiddenFiles: Bool = true
) -> AsyncThrowingStream<URL, any Error> {
    return AsyncThrowingStream(bufferingPolicy: .unbounded) { continuation in
        let task = Task {
            do {
                for include in include {
                    let (baseURL, include) = switch include.sections.first {
                    case let .constant(constant):
                        (baseURL.appending(path: constant.hasSuffix("/") ? String(constant.dropLast()) : constant), Pattern(sections: Array(include.sections.dropFirst()), options: include.options))
                    default:
                        (baseURL, include)
                    }
                    
                    if include.sections.isEmpty {
                        if FileManager.default.fileExists(atPath: baseURL.absoluteString.replacingOccurrences(of: "%20", with: " ")) {
                            continuation.yield(baseURL)
                        }
                        continue
                    }

                    
                    var isDirectory: ObjCBool = false
                    guard
                        FileManager.default.fileExists(atPath: baseURL.absoluteString.replacingOccurrences(of: "%20", with: " "), isDirectory: &isDirectory),
                        isDirectory.boolValue
                    else { continue }
                    
                    try await search(
                        directory: baseURL,
                        matching: { _, relativePath in
                                guard include.match(relativePath) else {
                                    // for patterns like `**/*.swift`, parent folders won't be matched but we don't want to skip those folder's descendents or we won't find the files that do match
                                    let skipDescendents = !include.sections.contains(where: {
                                        switch $0 {
                                        case .pathWildcard, .componentWildcard:
                                            return true
                                        default:
                                            return false
                                        }
                                    })
                                    return .init(matches: false, skipDescendents: skipDescendents)
                                }
                            
                            for pattern in exclude {
                                if pattern.match(relativePath) {
                                    return .init(matches: false, skipDescendents: true)
                                }
                            }
                            
                            return .init(matches: true, skipDescendents: false)
                        },
                        includingPropertiesForKeys: keys,
                        skipHiddenFiles: skipHiddenFiles,
                        relativePath: "",
                        continuation: continuation
                    )
                }
                
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        
        continuation.onTermination = { _ in
            task.cancel()
        }
    }
}

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
fileprivate func search(
    directory: URL,
    matching: @escaping @Sendable (_ url: URL, _ relativePath: String) throws -> MatchResult,
    includingPropertiesForKeys keys: [URLResourceKey],
    skipHiddenFiles: Bool,
    relativePath relativeDirectoryPath: String,
    continuation: AsyncThrowingStream<URL, any Error>.Continuation
) async throws {
    var options: FileManager.DirectoryEnumerationOptions = [
        .producesRelativePathURLs,
    ]
    if skipHiddenFiles {
        options.insert(.skipsHiddenFiles)
    }
    let contents = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: keys + [.isDirectoryKey],
        options: options
    )
    
    try await withThrowingTaskGroup(of: Void.self) { group in
        for url in contents {
            let relativePath = relativeDirectoryPath + url.lastPathComponent
            
            let matchResult = try matching(url, relativePath)
            
            let foundPath = directory.appending(path: url.relativePath)
            
            if matchResult.matches {
                continuation.yield(foundPath)
            }
            
            guard !matchResult.skipDescendents else { continue }
            
            let resourceValues = try url.resourceValues(forKeys: [.isDirectoryKey])
            if resourceValues.isDirectory == true {
                group.addTask {
                    try await search(
                        directory: foundPath,
                        matching: matching,
                        includingPropertiesForKeys: keys,
                        skipHiddenFiles: skipHiddenFiles,
                        relativePath: relativePath + "/",
                        continuation: continuation
                    )
                }
            }
        }
        
        try await group.waitForAll()
    }
}
