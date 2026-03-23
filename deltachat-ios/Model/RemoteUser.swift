import Foundation

struct RemoteUser: Decodable {
    let addr: [String]
    let name: String
    let username: String
    let fingerprint: String
    let publicKey: String?

    enum CodingKeys: String, CodingKey {
        case addr
        case name
        case username
        case fingerprint
        case publicKey = "public_key"
    }
}
