/// The version with semver build metadata appended when there is any, so a
/// local build reads as e.g. `5.1.0+d0a4bc2.dirty` and a release as `5.1.0`.
public var toolsFullVersion: String {
    toolsBuildMetadata.map { "\(toolsVersion)+\($0)" } ?? toolsVersion
}

// `make install` compiles with TOOLS_DEV_BUILD and generates
// BuildMetadata.generated.swift, which defines `toolsBuildMetadata` from the
// git hash. Every other build, including the release workflow's, gets none.
#if !TOOLS_DEV_BUILD
public let toolsBuildMetadata: String? = nil
#endif
