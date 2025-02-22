//
//  Copyright (c) 2022 Open Whisper Systems. All rights reserved.
//

import Foundation
import SignalRingRTC
import SignalServiceKit

// All Observer methods will be invoked from the main thread.
public protocol CallObserver: AnyObject {
    func individualCallStateDidChange(_ call: SignalCall, state: CallState)
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool)
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool)
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool)
    func individualCallRemoteSharingScreenDidChange(_ call: SignalCall, isRemoteSharingScreen: Bool)
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool)

    func groupCallLocalDeviceStateChanged(_ call: SignalCall)
    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall)
    func groupCallPeekChanged(_ call: SignalCall)
    func groupCallRequestMembershipProof(_ call: SignalCall)
    func groupCallRequestGroupMembers(_ call: SignalCall)
    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason)

    /// Invoked if a call message failed to send because of a safety number change
    /// UI observing call state may choose to alert the user (e.g. presenting a SafetyNumberConfirmationSheet)
    func callMessageSendFailedUntrustedIdentity(_ call: SignalCall)
}

public extension CallObserver {
    func individualCallStateDidChange(_ call: SignalCall, state: CallState) {}
    func individualCallLocalVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallLocalAudioMuteDidChange(_ call: SignalCall, isAudioMuted: Bool) {}
    func individualCallRemoteVideoMuteDidChange(_ call: SignalCall, isVideoMuted: Bool) {}
    func individualCallRemoteSharingScreenDidChange(_ call: SignalCall, isRemoteSharingScreen: Bool) {}
    func individualCallHoldDidChange(_ call: SignalCall, isOnHold: Bool) {}

    func groupCallLocalDeviceStateChanged(_ call: SignalCall) {}
    func groupCallRemoteDeviceStatesChanged(_ call: SignalCall) {}
    func groupCallPeekChanged(_ call: SignalCall) {}
    func groupCallRequestMembershipProof(_ call: SignalCall) {}
    func groupCallRequestGroupMembers(_ call: SignalCall) {}
    func groupCallEnded(_ call: SignalCall, reason: GroupCallEndReason) {}

    func callMessageSendFailedUntrustedIdentity(_ call: SignalCall) {}
}

@objc
public class SignalCall: NSObject, CallManagerCallReference {
    public let mode: Mode
    public enum Mode {
        case individual(IndividualCall)
        case group(GroupCall)
    }

    public let audioActivity: AudioActivity

    @objc
    var isGroupCall: Bool {
        switch mode {
        case .group: return true
        case .individual: return false
        }
    }

    var groupCall: GroupCall! {
        owsAssertDebug(isGroupCall)
        guard case .group(let call) = mode else {
            owsFailDebug("Missing group call")
            return nil
        }
        return call
    }

    @objc
    var isIndividualCall: Bool {
        switch mode {
        case .group: return false
        case .individual: return true
        }
    }

    @objc
    var individualCall: IndividualCall! {
        owsAssertDebug(isIndividualCall)
        guard case .individual(let call) = mode else {
            owsFailDebug("Missing individual call")
            return nil
        }
        return call
    }

    private(set) lazy var videoCaptureController = VideoCaptureController()

    // Should be used only on the main thread
    public var connectedDate: Date? {
        didSet { AssertIsOnMainThread() }
    }

    @objc
    public let thread: TSThread

    public var error: CallError?
    public enum CallError: Error {
        case providerReset
        case disconnected
        case externalError(underlyingError: Error)
        case timeout(description: String)
        case signaling
    }

    var participantAddresses: [SignalServiceAddress] {
        switch mode {
        case .group(let call):
            return call.remoteDeviceStates.values.map { $0.address }
        case .individual(let call):
            return [call.remoteAddress]
        }
    }

    init(groupCall: GroupCall, groupThread: TSGroupThread) {
        mode = .group(groupCall)
        audioActivity = AudioActivity(
            audioDescription: "[SignalCall] with group \(groupThread.groupModel.groupId)",
            behavior: .call
        )
        thread = groupThread
        super.init()
        groupCall.delegate = self
    }

    init(individualCall: IndividualCall) {
        mode = .individual(individualCall)
        audioActivity = AudioActivity(
            audioDescription: "[SignalCall] with individual \(individualCall.remoteAddress)",
            behavior: .call
        )
        thread = individualCall.thread
        super.init()
        individualCall.delegate = self
    }

    public class func groupCall(thread: TSGroupThread) -> SignalCall? {
        owsAssertDebug(thread.groupModel.groupsVersion == .V2)

        let videoCaptureController = VideoCaptureController()
        let sfuURL = DebugFlags.callingUseTestSFU.get() ? TSConstants.sfuTestURL : TSConstants.sfuURL

        guard let groupCall = Self.callService.callManager.createGroupCall(
            groupId: thread.groupModel.groupId,
            sfuUrl: sfuURL,
            hkdfExtraInfo: Data.init(),
            audioLevelsIntervalMillis: nil,
            videoCaptureController: videoCaptureController
        ) else {
            owsFailDebug("Failed to create group call")
            return nil
        }

        let call = SignalCall(groupCall: groupCall, groupThread: thread)
        call.videoCaptureController = videoCaptureController
        return call
    }

    public class func outgoingIndividualCall(localId: UUID, thread: TSContactThread) -> SignalCall {
        let individualCall = IndividualCall(
            direction: .outgoing,
            localId: localId,
            state: .dialing,
            thread: thread,
            sentAtTimestamp: Date.ows_millisecondTimestamp(),
            callAdapterType: .default
        )
        return SignalCall(individualCall: individualCall)
    }

    public class func incomingIndividualCall(
        localId: UUID,
        thread: TSContactThread,
        sentAtTimestamp: UInt64,
        offerMediaType: TSRecentCallOfferType
    ) -> SignalCall {
        // If this is a video call, we want to use in the in app call screen
        // because CallKit has poor support for video calls. On iOS 14+ we
        // always use CallKit, because as of iOS 14 AVAudioPlayer is no longer
        // able to start playing sounds in the background.
        let callAdapterType: CallAdapterType
        if #available(iOS 14, *) {
            callAdapterType = .default
        } else if offerMediaType == .video {
            callAdapterType = .nonCallKit
        } else {
            callAdapterType = .default
        }

        let individualCall = IndividualCall(
            direction: .incoming,
            localId: localId,
            state: .answering,
            thread: thread,
            sentAtTimestamp: sentAtTimestamp,
            callAdapterType: callAdapterType
        )
        individualCall.offerMediaType = offerMediaType
        return SignalCall(individualCall: individualCall)
    }

    // MARK: -

    private var observers: WeakArray<CallObserver> = []

    public func addObserverAndSyncState(observer: CallObserver) {
        AssertIsOnMainThread()

        observers.append(observer)

        // Synchronize observer with current call state
        switch mode {
        case .individual(let individualCall):
            observer.individualCallStateDidChange(self, state: individualCall.state)
        case .group:
            observer.groupCallLocalDeviceStateChanged(self)
            observer.groupCallRemoteDeviceStatesChanged(self)
        }
    }

    public func removeObserver(_ observer: CallObserver) {
        AssertIsOnMainThread()

        observers.removeAll { $0 === observer }
    }

    public func removeAllObservers() {
        AssertIsOnMainThread()

        observers = []
    }

    public func publishSendFailureUntrustedParticipantIdentity() {
        observers.elements.forEach { $0.callMessageSendFailedUntrustedIdentity(self) }
    }

    // MARK: -

    // This method should only be called when the call state is "connected".
    public func connectionDuration() -> TimeInterval {
        guard let connectedDate = connectedDate else {
            owsFailDebug("Called connectionDuration before connected.")
            return 0
        }
        return -connectedDate.timeIntervalSinceNow
    }
}

extension SignalCall: GroupCallDelegate {
    public func groupCall(onLocalDeviceStateChanged groupCall: GroupCall) {
        if groupCall.localDeviceState.joinState == .joined, connectedDate == nil {
            connectedDate = Date()

            // make sure we don't terminate audio session during call
            audioSession.isRTCAudioEnabled = true
            owsAssertDebug(audioSession.startAudioActivity(audioActivity))
        }

        observers.elements.forEach { $0.groupCallLocalDeviceStateChanged(self) }
    }

    public func groupCall(onRemoteDeviceStatesChanged groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRemoteDeviceStatesChanged(self) }
    }

    public func groupCall(onAudioLevels groupCall: GroupCall) {
        // TODO: Implement audio level handling for group calls.
    }

    public func groupCall(onPeekChanged groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallPeekChanged(self) }
    }

    public func groupCall(requestMembershipProof groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRequestMembershipProof(self) }
    }

    public func groupCall(requestGroupMembers groupCall: GroupCall) {
        observers.elements.forEach { $0.groupCallRequestGroupMembers(self) }
    }

    public func groupCall(onEnded groupCall: GroupCall, reason: GroupCallEndReason) {
        observers.elements.forEach { $0.groupCallEnded(self, reason: reason) }
    }
}

extension SignalCall: IndividualCallDelegate {
    public func individualCallStateDidChange(_ call: IndividualCall, state: CallState) {
        if case .connected = state, connectedDate == nil {
            connectedDate = Date()
        }

        observers.elements.forEach { $0.individualCallStateDidChange(self, state: state) }
    }

    public func individualCallLocalVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        observers.elements.forEach { $0.individualCallLocalVideoMuteDidChange(self, isVideoMuted: isVideoMuted) }
    }

    public func individualCallLocalAudioMuteDidChange(_ call: IndividualCall, isAudioMuted: Bool) {
        observers.elements.forEach { $0.individualCallLocalAudioMuteDidChange(self, isAudioMuted: isAudioMuted) }
    }

    public func individualCallHoldDidChange(_ call: IndividualCall, isOnHold: Bool) {
        observers.elements.forEach { $0.individualCallHoldDidChange(self, isOnHold: isOnHold) }
    }

    public func individualCallRemoteVideoMuteDidChange(_ call: IndividualCall, isVideoMuted: Bool) {
        observers.elements.forEach { $0.individualCallRemoteVideoMuteDidChange(self, isVideoMuted: isVideoMuted) }
    }

    public func individualCallRemoteSharingScreenDidChange(_ call: IndividualCall, isRemoteSharingScreen: Bool) {
        observers.elements.forEach { $0.individualCallRemoteSharingScreenDidChange(self, isRemoteSharingScreen: isRemoteSharingScreen) }
    }
}

extension GroupCall {
    public var isFull: Bool {
        guard let peekInfo = peekInfo, let maxDevices = peekInfo.maxDevices else { return false }
        return peekInfo.deviceCount >= maxDevices
    }
    public var maxDevices: UInt32? {
        guard let peekInfo = peekInfo, let maxDevices = peekInfo.maxDevices else { return nil }
        return maxDevices
    }
}
