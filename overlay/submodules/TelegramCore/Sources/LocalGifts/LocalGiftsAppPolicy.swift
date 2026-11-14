import Foundation

/// The build opts into local gifts independently of its visible name and signing identifier.
public enum LocalGiftsAppPolicy {
    public static func isEnabled(infoDictionary: [String: Any]) -> Bool {
        if let enabled = infoDictionary["LocalGiftsEnabled"] as? Bool {
            return enabled
        }
        // Keep compatibility with older LocalGram builds.
        if infoDictionary["CFBundleName"] as? String == "LocalGram"
            || infoDictionary["CFBundleDisplayName"] as? String == "LocalGram" {
            return true
        }
        let urlTypes = infoDictionary["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return urlTypes.contains { urlType in
            let schemes = urlType["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains("localgifts")
        }
    }
}
