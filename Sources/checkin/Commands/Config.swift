import ArgumentParser
import CryptCore
import Foundation

/// Inspects and changes Crypt's configuration. `list` is the useful one: it
/// shows the value in force for every setting and which layer supplied it, so
/// a profile that is not doing what an administrator expects is visible.
struct Config: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Show or change Crypt's configuration.",
    subcommands: [List.self, Get.self, Set.self],
    defaultSubcommand: List.self
  )

  struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Show every setting, its value, and where the value came from."
    )

    @Flag(help: "Print the settings as JSON.")
    var json = false

    func run() throws {
      var resolved: [(String, String, String)] = []
      for key in Preference.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
        let (value, source) = getPrefWithSource(key: key)
        resolved.append((key.rawValue, describe(value), source.rawValue))
      }

      if json {
        let payload = resolved.reduce(into: [String: [String: String]]()) { result, entry in
          result[entry.0] = ["value": entry.1, "source": entry.2]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(payload) {
          print(String(data: data, encoding: .utf8) ?? "{}")
        }
        return
      }

      let width = resolved.map(\.0.count).max() ?? 20
      for (name, value, source) in resolved {
        let padded = name.padding(toLength: width, withPad: " ", startingAt: 0)
        print("\(padded)  \(value)  (\(source))")
      }
    }
  }

  struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Print one setting's value.")

    @Argument(help: "The setting to read.")
    var key: String

    func run() throws {
      guard let preference = Preference(rawValue: key) else {
        throw CryptError(.configurationError, "\(key) is not a Crypt setting")
      }
      print(describe(getPref(key: preference)))
    }
  }

  struct Set: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Write one setting into the local preference domain.",
      discussion: """
        A value delivered by a configuration profile takes precedence over
        anything written here, so this changes behaviour only on a machine
        where the setting is not managed.
        """
    )

    @Argument(help: "The setting to write.")
    var key: String

    @Argument(help: "The value. Booleans accept true/false, arrays are comma separated.")
    var value: String

    func run() throws {
      requireRoot()
      guard let preference = Preference(rawValue: key) else {
        throw CryptError(.configurationError, "\(key) is not a Crypt setting")
      }
      let typed = coerce(value, like: Preference.defaultPreferences[preference])
      guard setPref(key: preference, value: typed) else {
        throw CryptError(.configurationError, "failed to write \(key)")
      }
      print("\(key) = \(describe(typed))")
    }
  }
}

func describe(_ value: Any?) -> String {
  switch value {
  case .none: return "(unset)"
  case let text as String: return text.isEmpty ? "(empty)" : text
  case let flag as Bool: return flag ? "true" : "false"
  case let list as [String]: return list.isEmpty ? "(empty)" : list.joined(separator: ", ")
  case let date as Date:
    return date.timeIntervalSince1970 > 0 ? ISO8601DateFormatter().string(from: date) : "never"
  case let number as NSNumber: return number.stringValue
  case let other?: return String(describing: other)
  }
}
