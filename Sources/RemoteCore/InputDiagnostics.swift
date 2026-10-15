import Foundation

public enum InputDiagnostics {
    private static let enabled = ProcessInfo.processInfo.environment["IREMOTE_INPUT_DIAGNOSTICS"] == "1"

    public static func record(_ event: String, _ values: [String: Int] = [:]) {
        guard enabled else { return }
        let fields = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: " ")
        let line = "[input \(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))] \(event) \(fields)\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
