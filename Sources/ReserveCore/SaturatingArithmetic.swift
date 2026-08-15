import Foundation

@inline(__always)
func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  let (value, overflow) = lhs.addingReportingOverflow(rhs)
  if overflow { return rhs >= 0 ? Int64.max : Int64.min }
  return value
}

@inline(__always)
func saturatingNonnegativeSum(_ values: Int64...) -> Int64 {
  values.reduce(0) { saturatingAdd($0, max(0, $1)) }
}

@inline(__always)
func saturatingNonnegativeSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
  let normalizedLHS = max(0, lhs)
  let normalizedRHS = max(0, rhs)
  return normalizedRHS >= normalizedLHS ? 0 : normalizedLHS - normalizedRHS
}
