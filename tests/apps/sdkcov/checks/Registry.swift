// sdkcov: every functional check, in run order. Each group lives in its own file (checks/<Group>.swift) and guards
// platform-specific frameworks with #if canImport / #if os, so one source tree builds for iOS, tvOS and watchOS.
enum Registry {
    static var all: [Check] { core + graphics + media + data + services + ui + ml + platform }
}
