import Foundation

public enum MactopFormat {
  public static func string(_ format: String, _ arguments: CVarArg...) -> String {
    var result = ""
    var index = format.startIndex
    var argumentIndex = 0
    while index < format.endIndex {
      if format[index] != "%" {
        result.append(format[index])
        index = format.index(after: index)
        continue
      }
      index = format.index(after: index)
      if index < format.endIndex, format[index] == "%" {
        result.append("%")
        index = format.index(after: index)
        continue
      }
      while index < format.endIndex, format[index].isNumber { index = format.index(after: index) }
      var precision: Int?
      if index < format.endIndex, format[index] == "." {
        index = format.index(after: index)
        let start = index
        while index < format.endIndex, format[index].isNumber { index = format.index(after: index) }
        precision = Int(format[start..<index]) ?? 0
      }
      guard index < format.endIndex, argumentIndex < arguments.count else { break }
      let argument = arguments[argumentIndex]
      argumentIndex += 1
      switch format[index] {
      case "@": result += String(describing: argument)
      case "d": result += String(Int64(String(describing: argument)) ?? 0)
      case "f":
        let value = Double(String(describing: argument)) ?? 0
        result += value.formatted(
          .number.locale(Locale(identifier: "en_US_POSIX")).grouping(.never).precision(
            .fractionLength(precision ?? 6)))
      default: result.append(format[index])
      }
      index = format.index(after: index)
    }
    return result
  }
}
