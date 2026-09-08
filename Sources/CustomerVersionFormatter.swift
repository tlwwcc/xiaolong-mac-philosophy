enum CustomerVersionFormatter {
  static func customerVersion(_ technicalVersion: String) -> String {
    let components = technicalVersion.split(separator: ".", omittingEmptySubsequences: false)
    guard components.count == 3,
      components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
      components[2] == "0",
      components[0] != "0"
    else {
      return technicalVersion
    }
    return "\(components[0]).\(components[1])"
  }

  private static func usesFullCustomerVersion(_ version: String) -> Bool {
    let components = version.split(separator: ".", omittingEmptySubsequences: false)
    return components.count == 3 && components[0] == "1" && components[1] == "0"
      && (Int(components[2]).map { $0 > 0 } ?? false)
  }

  static func appVersion(version: String, build: String) -> String {
    let customer = customerVersion(version)
    if customer != version || usesFullCustomerVersion(version) {
      return customer
    }
    return "v\(customer) (\(build))"
  }

  static func accessibilityVersion(version: String, build: String) -> String {
    let customer = customerVersion(version)
    if customer != version || usesFullCustomerVersion(version) {
      return "版本 \(customer)"
    }
    return "版本 \(customer)，构建 \(build)"
  }

  static func updateVersion(_ displayVersion: String) -> String {
    customerVersion(displayVersion)
  }

  static func backupVersion(version: String, build: String) -> String {
    let customer = customerVersion(version)
    if customer != version || usesFullCustomerVersion(version) {
      return customer
    }
    return "\(customer) (\(build))"
  }

  static func featureVersion(
    version: String?,
    build: String?
  ) -> (version: String?, build: String?) {
    guard let version else { return (nil, build) }
    let customer = customerVersion(version)
    return (customer, customer == version && !usesFullCustomerVersion(version) ? build : nil)
  }
}
