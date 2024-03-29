import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit


public struct ChangeAccountPhoneNumberData: Equatable {
    public let type: SentAuthorizationCodeType
    public let hash: String
    public let timeout: Int32?
    public let nextType: AuthorizationCodeNextType?
    
    public static func ==(lhs: ChangeAccountPhoneNumberData, rhs: ChangeAccountPhoneNumberData) -> Bool {
        if lhs.type != rhs.type {
            return false
        }
        if lhs.hash != rhs.hash {
            return false
        }
        if lhs.timeout != rhs.timeout {
            return false
        }
        if lhs.nextType != rhs.nextType {
            return false
        }
        return true
    }
}

public enum RequestChangeAccountPhoneNumberVerificationError {
    case invalidPhoneNumber
    case limitExceeded
    case phoneNumberOccupied
    case phoneBanned
    case generic
}

func _internal_requestChangeAccountPhoneNumberVerification(account: Account, phoneNumber: String, pushNotificationConfiguration: AuthorizationCodePushNotificationConfiguration?, firebaseSecretStream: Signal<[String: String], NoError>) -> Signal<ChangeAccountPhoneNumberData, RequestChangeAccountPhoneNumberVerificationError> {
    var flags: Int32 = 0
    
    flags |= 1 << 5 //allowMissedCall
    
    var token: String?
    var appSandbox: Api.Bool?
    if let pushNotificationConfiguration = pushNotificationConfiguration {
        flags |= 1 << 7
        flags |= 1 << 8
        token = pushNotificationConfiguration.token
        appSandbox = pushNotificationConfiguration.isSandbox ? .boolTrue : .boolFalse
    }
    
    return account.network.request(Api.functions.account.sendChangePhoneCode(phoneNumber: phoneNumber, settings: .codeSettings(flags: flags, logoutTokens: nil, token: token, appSandbox: appSandbox)), automaticFloodWait: false)
        |> mapError { error -> RequestChangeAccountPhoneNumberVerificationError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .limitExceeded
            } else if error.errorDescription == "PHONE_NUMBER_INVALID" {
                return .invalidPhoneNumber
            } else if error.errorDescription == "PHONE_NUMBER_OCCUPIED" {
                return .phoneNumberOccupied
            } else if error.errorDescription == "PHONE_NUMBER_BANNED" {
                return .phoneBanned
            } else {
                return .generic
            }
        }
        |> mapToSignal { sentCode -> Signal<ChangeAccountPhoneNumberData, RequestChangeAccountPhoneNumberVerificationError> in
            switch sentCode {
            case let .sentCode(_, type, phoneCodeHash, nextType, timeout):
                var parsedNextType: AuthorizationCodeNextType?
                if let nextType = nextType {
                    parsedNextType = AuthorizationCodeNextType(apiType: nextType)
                }
                return .single(ChangeAccountPhoneNumberData(type: SentAuthorizationCodeType(apiType: type), hash: phoneCodeHash, timeout: timeout, nextType: parsedNextType))
            case .sentCodeSuccess:
                return .never()
            }
        }
}

func _internal_requestNextChangeAccountPhoneNumberVerification(account: Account, phoneNumber: String, phoneCodeHash: String) -> Signal<ChangeAccountPhoneNumberData, RequestChangeAccountPhoneNumberVerificationError> {
    return account.network.request(Api.functions.auth.resendCode(phoneNumber: phoneNumber, phoneCodeHash: phoneCodeHash), automaticFloodWait: false)
        |> mapError { error -> RequestChangeAccountPhoneNumberVerificationError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .limitExceeded
            } else if error.errorDescription == "PHONE_NUMBER_INVALID" {
                return .invalidPhoneNumber
            } else if error.errorDescription == "PHONE_NUMBER_OCCUPIED" {
                return .phoneNumberOccupied
            } else {
                return .generic
            }
        }
    |> mapToSignal { sentCode -> Signal<ChangeAccountPhoneNumberData, RequestChangeAccountPhoneNumberVerificationError> in
        switch sentCode {
        case let .sentCode(_, type, phoneCodeHash, nextType, timeout):
            var parsedNextType: AuthorizationCodeNextType?
            if let nextType = nextType {
                parsedNextType = AuthorizationCodeNextType(apiType: nextType)
            }
            return .single(ChangeAccountPhoneNumberData(type: SentAuthorizationCodeType(apiType: type), hash: phoneCodeHash, timeout: timeout, nextType: parsedNextType))
        case .sentCodeSuccess:
            return .never()
        }
    }
}

public enum ChangeAccountPhoneNumberError {
    case generic
    case invalidCode
    case codeExpired
    case limitExceeded
}

func _internal_requestChangeAccountPhoneNumber(account: Account, phoneNumber: String, phoneCodeHash: String, phoneCode: String) -> Signal<Void, ChangeAccountPhoneNumberError> {
    let accountPeerId = account.peerId
    return account.network.request(Api.functions.account.changePhone(phoneNumber: phoneNumber, phoneCodeHash: phoneCodeHash, phoneCode: phoneCode), automaticFloodWait: false)
        |> mapError { error -> ChangeAccountPhoneNumberError in
            if error.errorDescription.hasPrefix("FLOOD_WAIT") {
                return .limitExceeded
            } else if error.errorDescription == "PHONE_CODE_INVALID" {
                return .invalidCode
            } else if error.errorDescription == "PHONE_CODE_EXPIRED" {
                return .codeExpired
            } else {
                return .generic
            }
        }
        |> mapToSignal { result -> Signal<Void, ChangeAccountPhoneNumberError> in
            return account.postbox.transaction { transaction -> Void in
                updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: AccumulatedPeers(transaction: transaction, chats: [], users: [result]))
            } |> mapError { _ -> ChangeAccountPhoneNumberError in }
        }
}
