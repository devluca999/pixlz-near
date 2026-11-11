import PixlzCore

/// Where the Pixl is, from this device's record: nil = here (owned). Anything else means it isn't
/// on screen here and can't be sent from here.
public enum Whereabouts {
    public static let arriving = "arriving"
    public static let unknown = "another device"

    public static func awayOn(_ record: StoredPet?) -> String? {
        switch record {
        case .owned?: nil
        case .away(_, _, let name, _, _)?: name.isEmpty ? unknown : name
        case .pendingArrival?: arriving
        case nil: unknown
        }
    }
}
