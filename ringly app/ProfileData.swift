import Foundation

// то, что шифруется и кладётся в encryptedProfile
struct ProfileData: Codable {
    var firstName: String
    var lastName: String
}
