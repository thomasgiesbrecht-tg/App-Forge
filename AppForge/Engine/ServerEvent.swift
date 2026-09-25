import Foundation

/// Die Events aus dem OpenCode-Stream, die AppForge auswertet. Alles andere wird ignoriert.
enum ServerEvent: Sendable {
    case messageUpdated(MessageInfo)
    case messageRemoved(sessionID: String, messageID: String)
    case partUpdated(Part)
    case partDelta(sessionID: String, messageID: String, partID: String, field: String, delta: String)
    case partRemoved(sessionID: String, messageID: String, partID: String)
    case sessionUpdated(Session)
    case sessionDeleted(Session)
    case sessionStatus(sessionID: String, activity: SessionActivity)
    case sessionError(sessionID: String?, message: String)
    case permissionAsked(PermissionRequest)
    case permissionReplied(sessionID: String, requestID: String)
    case sessionDiff(sessionID: String, changes: [FileChange])
    case other(String)

    private struct Header: Decodable { var type: String }
    private struct Envelope<P: Decodable>: Decodable { var properties: P }

    private struct MessageProps: Decodable { var info: MessageInfo }
    private struct MessageRemovedProps: Decodable { var sessionID: String; var messageID: String }
    private struct PartProps: Decodable { var part: Part }
    private struct DeltaProps: Decodable { var sessionID: String; var messageID: String; var partID: String; var field: String; var delta: String }
    private struct PartRemovedProps: Decodable { var sessionID: String; var messageID: String; var partID: String }
    private struct SessionProps: Decodable { var info: Session }
    private struct StatusProps: Decodable {
        struct Status: Decodable { var type: String; var message: String? }
        var sessionID: String
        var status: Status
    }
    private struct IdleProps: Decodable { var sessionID: String }
    private struct ErrorProps: Decodable { var sessionID: String?; var error: JSONValue? }
    private struct RepliedProps: Decodable { var sessionID: String; var requestID: String }
    private struct DiffProps: Decodable { var sessionID: String; var diff: [FileChange] }

    static func decode(_ data: Data) throws -> ServerEvent {
        let decoder = JSONDecoder()
        let type = try decoder.decode(Header.self, from: data).type
        func props<P: Decodable>(_: P.Type) throws -> P { try decoder.decode(Envelope<P>.self, from: data).properties }

        switch type {
        case "message.updated":
            return .messageUpdated(try props(MessageProps.self).info)
        case "message.removed":
            let p = try props(MessageRemovedProps.self)
            return .messageRemoved(sessionID: p.sessionID, messageID: p.messageID)
        case "message.part.updated":
            return .partUpdated(try props(PartProps.self).part)
        case "message.part.delta":
            let p = try props(DeltaProps.self)
            return .partDelta(sessionID: p.sessionID, messageID: p.messageID, partID: p.partID, field: p.field, delta: p.delta)
        case "message.part.removed":
            let p = try props(PartRemovedProps.self)
            return .partRemoved(sessionID: p.sessionID, messageID: p.messageID, partID: p.partID)
        case "session.created", "session.updated":
            return .sessionUpdated(try props(SessionProps.self).info)
        case "session.deleted":
            return .sessionDeleted(try props(SessionProps.self).info)
        case "session.status":
            let p = try props(StatusProps.self)
            let activity: SessionActivity = switch p.status.type {
            case "busy": .busy
            case "retry": .retry(p.status.message ?? "Neuer Versuch …")
            default: .idle
            }
            return .sessionStatus(sessionID: p.sessionID, activity: activity)
        case "session.idle":
            return .sessionStatus(sessionID: try props(IdleProps.self).sessionID, activity: .idle)
        case "session.error":
            let p = try props(ErrorProps.self)
            let message = p.error?["data"]?["message"]?.stringValue ?? p.error?["name"]?.stringValue ?? "Unbekannter Fehler"
            return .sessionError(sessionID: p.sessionID, message: message)
        case "permission.asked":
            return .permissionAsked(try props(PermissionRequest.self))
        case "permission.replied":
            let p = try props(RepliedProps.self)
            return .permissionReplied(sessionID: p.sessionID, requestID: p.requestID)
        case "session.diff":
            let p = try props(DiffProps.self)
            return .sessionDiff(sessionID: p.sessionID, changes: p.diff)
        default:
            return .other(type)
        }
    }
}
