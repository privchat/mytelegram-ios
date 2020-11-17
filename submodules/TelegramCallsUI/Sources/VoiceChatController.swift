import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramPresentationData
import TelegramUIPreferences
import TelegramVoip
import TelegramAudio
import AccountContext
import Postbox
import TelegramCore
import SyncCore
import ItemListPeerItem
import MergeLists
import ItemListUI
import AppBundle
import RadialStatusNode

private final class VoiceChatControllerTitleView: UIView {
    private var theme: PresentationTheme
    
    private let titleNode: ASTextNode
    private let infoNode: ASTextNode
    
    init(theme: PresentationTheme) {
        self.theme = theme
        
        self.titleNode = ASTextNode()
        self.titleNode.displaysAsynchronously = false
        self.titleNode.maximumNumberOfLines = 1
        self.titleNode.truncationMode = .byTruncatingTail
        self.titleNode.isOpaque = false
        
        self.infoNode = ASTextNode()
        self.infoNode.displaysAsynchronously = false
        self.infoNode.maximumNumberOfLines = 1
        self.infoNode.truncationMode = .byTruncatingTail
        self.infoNode.isOpaque = false
        
        super.init(frame: CGRect())
        
        self.addSubnode(self.titleNode)
        self.addSubnode(self.infoNode)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(title: String, subtitle: String) {
        self.titleNode.attributedText = NSAttributedString(string: title, font: Font.medium(17.0), textColor: .white)
        self.infoNode.attributedText = NSAttributedString(string: subtitle, font: Font.regular(13.0), textColor: UIColor.white.withAlphaComponent(0.5))
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        
        let size = self.bounds.size
        
        if size.height > 40.0 {
            let titleSize = self.titleNode.measure(size)
            let infoSize = self.infoNode.measure(size)
            let titleInfoSpacing: CGFloat = 0.0
            
            let combinedHeight = titleSize.height + infoSize.height + titleInfoSpacing
            
            self.titleNode.frame = CGRect(origin: CGPoint(x: floor((size.width - titleSize.width) / 2.0), y: floor((size.height - combinedHeight) / 2.0)), size: titleSize)
            self.infoNode.frame = CGRect(origin: CGPoint(x: floor((size.width - infoSize.width) / 2.0), y: floor((size.height - combinedHeight) / 2.0) + titleSize.height + titleInfoSpacing), size: infoSize)
        } else {
            let titleSize = self.titleNode.measure(CGSize(width: floor(size.width / 2.0), height: size.height))
            let infoSize = self.infoNode.measure(CGSize(width: floor(size.width / 2.0), height: size.height))
            
            let titleInfoSpacing: CGFloat = 8.0
            let combinedWidth = titleSize.width + infoSize.width + titleInfoSpacing
            
            self.titleNode.frame = CGRect(origin: CGPoint(x: floor((size.width - combinedWidth) / 2.0), y: floor((size.height - titleSize.height) / 2.0)), size: titleSize)
            self.infoNode.frame = CGRect(origin: CGPoint(x: floor((size.width - combinedWidth) / 2.0 + titleSize.width + titleInfoSpacing), y: floor((size.height - infoSize.height) / 2.0)), size: infoSize)
        }
    }
}

private final class VoiceChatActionButton: HighlightTrackingButtonNode {
    private let backgroundNode: ASImageNode
    private let foregroundNode: ASImageNode
    
    private var validSize: CGSize?
    private var isOn: Bool?
    
    init() {
        self.backgroundNode = ASImageNode()
        self.foregroundNode = ASImageNode()
        
        super.init()
        
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.foregroundNode)
    }
    
    func updateLayout(size: CGSize, isOn: Bool) {
        if self.validSize != size {
            self.validSize = size
            
            self.backgroundNode.image = generateFilledCircleImage(diameter: size.width, color: UIColor(rgb: 0x1C1C1E))
        }
        if self.isOn != isOn {
            self.isOn = isOn
            self.foregroundNode.image = UIImage(bundleImageName: isOn ? "Call/VoiceChatMicOn" : "Call/VoiceChatMicOff")
        }
        self.backgroundNode.frame = CGRect(origin: CGPoint(), size: size)
        
        if let image = self.foregroundNode.image {
            self.foregroundNode.frame = CGRect(origin: CGPoint(x: floor((size.width - image.size.width) / 2.0), y: floor((size.height - image.size.height) / 2.0)), size: image.size)
        }
    }
}

public final class VoiceChatController: ViewController {
    private final class Node: ViewControllerTracingNode {
        private struct ListTransition {
            let deletions: [ListViewDeleteItem]
            let insertions: [ListViewInsertItem]
            let updates: [ListViewUpdateItem]
            let isLoading: Bool
            let isEmpty: Bool
            let crossFade: Bool
        }
        
        private final class Interaction {
            
        }
        
        private struct PeerEntry: Comparable, Identifiable {
            enum State {
                case inactive
                case listening
                case speaking
            }
            
            var participant: RenderedChannelParticipant
            var activityTimestamp: Int32
            var state: State
            
            var stableId: PeerId {
                return self.participant.peer.id
            }
            
            static func <(lhs: PeerEntry, rhs: PeerEntry) -> Bool {
                if lhs.activityTimestamp != rhs.activityTimestamp {
                    return lhs.activityTimestamp > rhs.activityTimestamp
                }
                return lhs.participant.peer.id < rhs.participant.peer.id
            }
            
            func item(context: AccountContext, presentationData: ItemListPresentationData, interaction: Interaction) -> ListViewItem {
                let peer = self.participant.peer
                
                let text: ItemListPeerItemText
                switch self.state {
                case .inactive:
                    text = .presence
                case .listening:
                    //TODO:localize
                    text = .text("listening", .accent)
                case .speaking:
                    //TODO:localize
                    text = .text("speaking", .constructive)
                }
                
                return ItemListPeerItem(presentationData: presentationData, dateTimeFormat: PresentationDateTimeFormat(timeFormat: .regular, dateFormat: .monthFirst, dateSeparator: ".", decimalSeparator: ".", groupingSeparator: "."), nameDisplayOrder: .firstLast, context: context, peer: peer, height: .peerList, presence: self.participant.presences[self.participant.peer.id], text: text, label: .none, editing: ItemListPeerItemEditing(editable: false, editing: false, revealed: false), revealOptions: ItemListPeerItemRevealOptions(options: [ItemListPeerItemRevealOption(type: .destructive, title: presentationData.strings.Common_Delete, action: {
                    //arguments.deleteIncludePeer(peer.peerId)
                })]), switchValue: nil, enabled: true, selectable: false, sectionId: 0, action: nil, setPeerIdWithRevealedOptions: { lhs, rhs in
                    //arguments.setItemIdWithRevealedOptions(lhs.flatMap { .peer($0) }, rhs.flatMap { .peer($0) })
                }, removePeer: { id in
                    //arguments.deleteIncludePeer(id)
                }, noInsets: true)
            }
        }
        
        private func preparedTransition(from fromEntries: [PeerEntry], to toEntries: [PeerEntry], isLoading: Bool, isEmpty: Bool, crossFade: Bool, context: AccountContext, presentationData: ItemListPresentationData, interaction: Interaction) -> ListTransition {
            let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: fromEntries, rightList: toEntries)
            
            let deletions = deleteIndices.map { ListViewDeleteItem(index: $0, directionHint: nil) }
            let insertions = indicesAndItems.map { ListViewInsertItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, presentationData: presentationData, interaction: interaction), directionHint: nil) }
            let updates = updateIndices.map { ListViewUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(context: context, presentationData: presentationData, interaction: interaction), directionHint: nil) }
            
            return ListTransition(deletions: deletions, insertions: insertions, updates: updates, isLoading: isLoading, isEmpty: isEmpty, crossFade: crossFade)
        }
        
        private weak var controller: VoiceChatController?
        private let sharedContext: SharedAccountContext
        private let context: AccountContext
        private let call: PresentationGroupCall
        private var presentationData: PresentationData
        private var darkTheme: PresentationTheme
        
        private let contentContainer: ASDisplayNode
        private let listNode: ListView
        private let audioOutputNode: CallControllerButtonItemNode
        private let leaveNode: CallControllerButtonItemNode
        private let actionButton: VoiceChatActionButton
        private let radialStatus: RadialStatusNode
        private let statusLabel: ImmediateTextNode
        
        private var enqueuedTransitions: [ListTransition] = []
        
        private var validLayout: (ContainerViewLayout, CGFloat)?
        private var didSetContentsReady: Bool = false
        private var didSetDataReady: Bool = false
        
        private var currentMembers: [RenderedChannelParticipant]?
        private var currentMemberStates: [PeerId: PresentationGroupCallMemberState]?
        
        private var currentEntries: [PeerEntry] = []
        private var peersDisposable: Disposable?
        
        private var peerViewDisposable: Disposable?
        private let leaveDisposable = MetaDisposable()
        
        private var isMutedDisposable: Disposable?
        private var callStateDisposable: Disposable?
        
        private var callState: PresentationGroupCallState?
        
        private var audioOutputStateDisposable: Disposable?
        private var audioOutputState: ([AudioSessionOutput], AudioSessionOutput?)?
        
        private var memberStatesDisposable: Disposable?
        
        private var itemInteraction: Interaction?
        
        init(controller: VoiceChatController, sharedContext: SharedAccountContext, call: PresentationGroupCall) {
            self.controller = controller
            self.sharedContext = sharedContext
            self.context = call.accountContext
            self.call = call
            
            self.presentationData = sharedContext.currentPresentationData.with { $0 }
            self.darkTheme = defaultDarkPresentationTheme
            
            self.contentContainer = ASDisplayNode()
            
            self.listNode = ListView()
            self.listNode.backgroundColor = self.darkTheme.list.itemBlocksBackgroundColor
            self.listNode.verticalScrollIndicatorColor = UIColor(white: 1.0, alpha: 0.3)
            self.listNode.clipsToBounds = true
            self.listNode.cornerRadius = 16.0
            
            self.audioOutputNode = CallControllerButtonItemNode()
            self.leaveNode = CallControllerButtonItemNode()
            self.actionButton = VoiceChatActionButton()
            self.statusLabel = ImmediateTextNode()
            
            self.radialStatus = RadialStatusNode(backgroundNodeColor: .clear)
            
            super.init()
            
            self.itemInteraction = Interaction()
            
            self.backgroundColor = .black
            
            self.contentContainer.addSubnode(self.listNode)
            self.contentContainer.addSubnode(self.audioOutputNode)
            self.contentContainer.addSubnode(self.leaveNode)
            self.contentContainer.addSubnode(self.actionButton)
            self.contentContainer.addSubnode(self.statusLabel)
            self.contentContainer.addSubnode(self.radialStatus)
            
            self.addSubnode(self.contentContainer)
            
            let (disposable, loadMoreControl) = self.context.peerChannelMemberCategoriesContextsManager.recent(postbox: self.context.account.postbox, network: self.context.account.network, accountPeerId: self.context.account.peerId, peerId: self.call.peerId, updated: { [weak self] state in
                Queue.mainQueue().async {
                    guard let strongSelf = self else {
                        return
                    }
                    strongSelf.updateMembers(isMuted: strongSelf.callState?.isMuted ?? true, members: state.list, memberStates: strongSelf.currentMemberStates ?? [:])
                }
            })
            
            self.memberStatesDisposable = (self.call.members
            |> deliverOnMainQueue).start(next: { [weak self] memberStates in
                guard let strongSelf = self else {
                    return
                }
                if let members = strongSelf.currentMembers {
                    strongSelf.updateMembers(isMuted: strongSelf.callState?.isMuted ?? true, members: members, memberStates: memberStates)
                } else {
                    strongSelf.currentMemberStates = memberStates
                }
            })
            
            self.listNode.visibleBottomContentOffsetChanged = { [weak self] offset in
                guard let strongSelf = self else {
                    return
                }
                if case let .known(value) = offset, value < 40.0 {
                    strongSelf.context.peerChannelMemberCategoriesContextsManager.loadMore(peerId: strongSelf.call.peerId, control: loadMoreControl)
                }
            }
            
            self.peersDisposable = disposable
            
            self.peerViewDisposable = (self.context.account.viewTracker.peerView(self.call.peerId)
            |> deliverOnMainQueue).start(next: { [weak self] view in
                guard let strongSelf = self else {
                    return
                }
                
                guard let peer = view.peers[view.peerId] else {
                    return
                }
                var subtitle = "group"
                if let cachedData = view.cachedData as? CachedChannelData {
                    if let memberCount = cachedData.participantsSummary.memberCount {
                        subtitle = strongSelf.presentationData.strings.Conversation_StatusMembers(memberCount)
                    }
                }
                
                let titleView = VoiceChatControllerTitleView(theme: strongSelf.presentationData.theme)
                titleView.set(title: peer.debugDisplayTitle, subtitle: subtitle)
                strongSelf.controller?.navigationItem.titleView = titleView
                
                if !strongSelf.didSetDataReady {
                    strongSelf.didSetDataReady = true
                    strongSelf.controller?.dataReady.set(true)
                }
            })
            
            self.callStateDisposable = (self.call.state
            |> deliverOnMainQueue).start(next: { [weak self] state in
                guard let strongSelf = self else {
                    return
                }
                if strongSelf.callState != state {
                    let wasMuted = strongSelf.callState?.isMuted ?? true
                    strongSelf.callState = state
                    
                    if wasMuted != state.isMuted, let members = strongSelf.currentMembers {
                        strongSelf.updateMembers(isMuted: state.isMuted, members: members, memberStates: strongSelf.currentMemberStates ?? [:])
                    }
                    
                    if let (layout, navigationHeight) = strongSelf.validLayout {
                        strongSelf.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
                    }
                }
            })
            
            self.audioOutputStateDisposable = (call.audioOutputState
            |> deliverOnMainQueue).start(next: { [weak self] state in
                if let strongSelf = self {
                    strongSelf.audioOutputState = state
                    if let (layout, navigationHeight) = strongSelf.validLayout {
                        strongSelf.containerLayoutUpdated(layout, navigationHeight: navigationHeight, transition: .immediate)
                    }
                }
            })
            
            self.leaveNode.addTarget(self, action: #selector(self.leavePressed), forControlEvents: .touchUpInside)
            
            self.actionButton.addTarget(self, action: #selector(self.actionButtonPressed), forControlEvents: .touchUpInside)
            
            self.audioOutputNode.addTarget(self, action: #selector(self.audioOutputPressed), forControlEvents: .touchUpInside)
        }
        
        deinit {
            self.peersDisposable?.dispose()
            self.peerViewDisposable?.dispose()
            self.leaveDisposable.dispose()
            self.isMutedDisposable?.dispose()
            self.callStateDisposable?.dispose()
            self.audioOutputStateDisposable?.dispose()
            self.memberStatesDisposable?.dispose()
        }
        
        @objc private func leavePressed() {
            self.leaveDisposable.set((self.call.leave()
            |> deliverOnMainQueue).start(completed: { [weak self] in
                self?.controller?.dismiss()
            }))
        }
        
        @objc private func actionButtonPressed() {
            self.call.toggleIsMuted()
        }
        
        @objc private func audioOutputPressed() {
            guard let (availableOutputs, currentOutput) = self.audioOutputState else {
                return
            }
            guard availableOutputs.count >= 2 else {
                return
            }
            let hasMute = false
            
            if availableOutputs.count == 2 {
                for output in availableOutputs {
                    if output != currentOutput {
                        self.call.setCurrentAudioOutput(output)
                        break
                    }
                }
            } else {
                let actionSheet = ActionSheetController(presentationData: self.presentationData)
                var items: [ActionSheetItem] = []
                for output in availableOutputs {
                    if hasMute, case .builtin = output {
                        continue
                    }
                    let title: String
                    var icon: UIImage?
                    switch output {
                        case .builtin:
                            title = UIDevice.current.model
                        case .speaker:
                            title = self.presentationData.strings.Call_AudioRouteSpeaker
                            icon = generateScaledImage(image: UIImage(bundleImageName: "Call/CallSpeakerButton"), size: CGSize(width: 48.0, height: 48.0), opaque: false)
                        case .headphones:
                            title = self.presentationData.strings.Call_AudioRouteHeadphones
                        case let .port(port):
                            title = port.name
                            if port.type == .bluetooth {
                                var image = UIImage(bundleImageName: "Call/CallBluetoothButton")
                                let portName = port.name.lowercased()
                                if portName.contains("airpods pro") {
                                    image = UIImage(bundleImageName: "Call/CallAirpodsProButton")
                                } else if portName.contains("airpods") {
                                    image = UIImage(bundleImageName: "Call/CallAirpodsButton")
                                }
                                icon = generateScaledImage(image: image, size: CGSize(width: 48.0, height: 48.0), opaque: false)
                            }
                    }
                    items.append(CallRouteActionSheetItem(title: title, icon: icon, selected: output == currentOutput, action: { [weak self, weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        self?.call.setCurrentAudioOutput(output)
                    }))
                }
                
                if hasMute {
                    items.append(CallRouteActionSheetItem(title: self.presentationData.strings.Call_AudioRouteMute, icon:  generateScaledImage(image: UIImage(bundleImageName: "Call/CallMuteButton"), size: CGSize(width: 48.0, height: 48.0), opaque: false), selected: self.callState?.isMuted ?? true, action: { [weak self, weak actionSheet] in
                        actionSheet?.dismissAnimated()
                        self?.call.toggleIsMuted()
                    }))
                }
                
                actionSheet.setItemGroups([ActionSheetItemGroup(items: items), ActionSheetItemGroup(items: [
                        ActionSheetButtonItem(title: self.presentationData.strings.Call_AudioRouteHide, color: .accent, font: .bold, action: { [weak actionSheet] in
                            actionSheet?.dismissAnimated()
                        })
                    ])
                ])
                self.controller?.present(actionSheet, in: .window(.calls))
            }
        }
        
        func containerLayoutUpdated(_ layout: ContainerViewLayout, navigationHeight: CGFloat, transition: ContainedViewLayoutTransition) {
            let isFirstTime = self.validLayout == nil
            self.validLayout = (layout, navigationHeight)
            
            transition.updateFrame(node: self.contentContainer, frame: CGRect(origin: CGPoint(), size: layout.size))
            
            let bottomAreaHeight: CGFloat = 302.0
            
            let listOrigin = CGPoint(x: 16.0, y: navigationHeight + 10.0)
            let listFrame = CGRect(origin: listOrigin, size: CGSize(width: layout.size.width - 16.0 * 2.0, height: max(1.0, layout.size.height - bottomAreaHeight - listOrigin.y)))
            
            transition.updateFrame(node: self.listNode, frame: listFrame)
            
            let (duration, curve) = listViewAnimationDurationAndCurve(transition: transition)
            let updateSizeAndInsets = ListViewUpdateSizeAndInsets(size: listFrame.size, insets: UIEdgeInsets(top: -1.0, left: -6.0, bottom: -1.0, right: -6.0), scrollIndicatorInsets: UIEdgeInsets(top: 10.0, left: 0.0, bottom: 10.0, right: 0.0), duration: duration, curve: curve)
            
            self.listNode.transaction(deleteIndices: [], insertIndicesAndItems: [], updateIndicesAndItems: [], options: [.Synchronous, .LowLatency], scrollToItem: nil, updateSizeAndInsets: updateSizeAndInsets, stationaryItemRange: nil, updateOpaqueState: nil, completion: { _ in })
            
            let sideButtonSize = CGSize(width: 60.0, height: 60.0)
            let centralButtonSize = CGSize(width: 144.0, height: 144.0)
            let sideButtonInset: CGFloat = 27.0
            
            var audioMode: CallControllerButtonsSpeakerMode = .none
            //var hasAudioRouteMenu: Bool = false
            if let (availableOutputs, maybeCurrentOutput) = self.audioOutputState, let currentOutput = maybeCurrentOutput {
                //hasAudioRouteMenu = availableOutputs.count > 2
                switch currentOutput {
                    case .builtin:
                        audioMode = .builtin
                    case .speaker:
                        audioMode = .speaker
                    case .headphones:
                        audioMode = .headphones
                    case let .port(port):
                        var type: CallControllerButtonsSpeakerMode.BluetoothType = .generic
                        let portName = port.name.lowercased()
                        if portName.contains("airpods pro") {
                            type = .airpodsPro
                        } else if portName.contains("airpods") {
                            type = .airpods
                        }
                        audioMode = .bluetooth(type)
                }
                if availableOutputs.count <= 1 {
                    audioMode = .none
                }
            }
            
            let soundImage: CallControllerButtonItemNode.Content.Image
            var soundAppearance: CallControllerButtonItemNode.Content.Appearance = .color(.grayDimmed)
            switch audioMode {
            case .none, .builtin:
                soundImage = .speaker
            case .speaker:
                soundImage = .speaker
                soundAppearance = .blurred(isFilled: true)
            case .headphones:
                soundImage = .bluetooth
            case let .bluetooth(type):
                switch type {
                case .generic:
                    soundImage = .bluetooth
                case .airpods:
                    soundImage = .airpods
                case .airpodsPro:
                    soundImage = .airpodsPro
                }
            }
            
            //TODO:localize
            self.audioOutputNode.update(size: sideButtonSize, content: CallControllerButtonItemNode.Content(appearance: soundAppearance, image: soundImage), text: "audio", transition: .immediate)
            
            //TODO:localize
            self.leaveNode.update(size: sideButtonSize, content: CallControllerButtonItemNode.Content(appearance: .color(.redDimmed), image: .end), text: "leave", transition: .immediate)
            
            transition.updateFrame(node: self.audioOutputNode, frame: CGRect(origin: CGPoint(x: sideButtonInset, y: layout.size.height - bottomAreaHeight + floor((bottomAreaHeight - sideButtonSize.height) / 2.0)), size: sideButtonSize))
            transition.updateFrame(node: self.leaveNode, frame: CGRect(origin: CGPoint(x: layout.size.width - sideButtonInset - sideButtonSize.width, y: layout.size.height - bottomAreaHeight + floor((bottomAreaHeight - sideButtonSize.height) / 2.0)), size: sideButtonSize))
            
            let actionButtonFrame = CGRect(origin: CGPoint(x: floor((layout.size.width - centralButtonSize.width) / 2.0), y: layout.size.height - bottomAreaHeight + floor((bottomAreaHeight - centralButtonSize.height) / 2.0)), size: centralButtonSize)
            
            var isMicOn = false
            if let callState = callState {
                isMicOn = !callState.isMuted
                
                switch callState.networkState {
                case .connecting:
                    self.radialStatus.isHidden = false
                    
                    self.statusLabel.attributedText = NSAttributedString(string: "Connecting...", font: Font.regular(17.0), textColor: .white)
                case .connected:
                    self.radialStatus.isHidden = true
                    
                    if isMicOn {
                        self.statusLabel.attributedText = NSAttributedString(string: "You're Live", font: Font.regular(17.0), textColor: .white)
                    } else {
                        self.statusLabel.attributedText = NSAttributedString(string: "Unmute", font: Font.regular(17.0), textColor: .white)
                    }
                }
                
                let statusSize = self.statusLabel.updateLayout(CGSize(width: layout.size.width, height: .greatestFiniteMagnitude))
                self.statusLabel.frame = CGRect(origin: CGPoint(x: floor((layout.size.width - statusSize.width) / 2.0), y: actionButtonFrame.maxY + 12.0), size: statusSize)
                
                self.radialStatus.transitionToState(.progress(color: UIColor(rgb: 0x00ACFF), lineWidth: 3.3, value: nil, cancelEnabled: false), animated: false)
                self.radialStatus.frame = actionButtonFrame.insetBy(dx: -3.3, dy: -3.3)
            }
            
            self.actionButton.updateLayout(size: centralButtonSize, isOn: isMicOn)
            transition.updateFrame(node: self.actionButton, frame: actionButtonFrame)
            
            if isFirstTime {
                while !self.enqueuedTransitions.isEmpty {
                    self.dequeueTransition()
                }
            }
        }
        
        func animateIn() {
            self.alpha = 1.0
            self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            
            self.listNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            
            self.actionButton.layer.animateScale(from: 0.1, to: 1.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
            self.audioOutputNode.layer.animateScale(from: 0.1, to: 1.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
            self.leaveNode.layer.animateScale(from: 0.1, to: 1.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
            
            self.contentContainer.layer.animateBoundsOriginYAdditive(from: 80.0, to: 0.0, duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring)
        }
        
        func animateOut(completion: (() -> Void)?) {
            self.alpha = 0.0
            self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, completion: { _ in
                completion?()
            })
        }
        
        private func enqueueTransition(_ transition: ListTransition) {
            self.enqueuedTransitions.append(transition)
            
            if let _ = self.validLayout {
                while !self.enqueuedTransitions.isEmpty {
                    self.dequeueTransition()
                }
            }
        }
        
        private func dequeueTransition() {
            guard let _ = self.validLayout, let transition = self.enqueuedTransitions.first else {
                return
            }
            self.enqueuedTransitions.remove(at: 0)
            
            var options = ListViewDeleteAndInsertOptions()
            if transition.crossFade {
                options.insert(.AnimateCrossfade)
            }
            options.insert(.LowLatency)
            options.insert(.PreferSynchronousResourceLoading)
            
            self.listNode.transaction(deleteIndices: transition.deletions, insertIndicesAndItems: transition.insertions, updateIndicesAndItems: transition.updates, options: options, updateSizeAndInsets: nil, updateOpaqueState: nil, completion: { [weak self] _ in
                guard let strongSelf = self else {
                    return
                }
                if !strongSelf.didSetContentsReady {
                    strongSelf.didSetContentsReady = true
                    strongSelf.controller?.contentsReady.set(true)
                }
            })
        }
        
        private func updateMembers(isMuted: Bool, members: [RenderedChannelParticipant], memberStates: [PeerId: PresentationGroupCallMemberState]) {
            var members = members
            members.sort(by: { lhs, rhs in
                if lhs.peer.id == self.context.account.peerId {
                    return true
                } else if rhs.peer.id == self.context.account.peerId {
                    return false
                }
                let lhsHasState = memberStates[lhs.peer.id] != nil
                let rhsHasState = memberStates[rhs.peer.id] != nil
                if lhsHasState != rhsHasState {
                    if lhsHasState {
                        return true
                    } else {
                        return false
                    }
                }
                return lhs.peer.id < rhs.peer.id
            })
            
            self.currentMembers = members
            self.currentMemberStates = memberStates
            
            let previousEntries = self.currentEntries
            var entries: [PeerEntry] = []
            
            var index: Int32 = 0
            
            for member in members {
                let memberState: PeerEntry.State
                if member.peer.id == self.context.account.peerId {
                    if !isMuted {
                        memberState = .speaking
                    } else {
                        memberState = .listening
                    }
                } else if let _ = memberStates[member.peer.id] {
                    memberState = .listening
                } else {
                    memberState = .inactive
                }
                
                entries.append(PeerEntry(
                    participant: member,
                    activityTimestamp: Int32.max - 1 - index,
                    state: memberState
                ))
                index += 1
            }
            
            self.currentEntries = entries
            
            let presentationData = ItemListPresentationData(theme: self.darkTheme, fontSize: self.presentationData.listsFontSize, strings: self.presentationData.strings)
            
            let transition = preparedTransition(from: previousEntries, to: entries, isLoading: false, isEmpty: false, crossFade: false, context: self.context, presentationData: presentationData, interaction: self.itemInteraction!)
            self.enqueueTransition(transition)
        }
    }
    
    private let sharedContext: SharedAccountContext
    public let call: PresentationGroupCall
    private let presentationData: PresentationData
    
    fileprivate let contentsReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    fileprivate let dataReady = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let _ready = Promise<Bool>(false)
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var didAppearOnce: Bool = false
    private var isDismissed: Bool = false
    
    private var controllerNode: Node {
        return self.displayNode as! Node
    }
    
    public init(sharedContext: SharedAccountContext, accountContext: AccountContext, call: PresentationGroupCall) {
        self.sharedContext = sharedContext
        self.call = call
        self.presentationData = sharedContext.currentPresentationData.with { $0 }
        
        let darkNavigationTheme = NavigationBarTheme(buttonColor: .white, disabledButtonColor: UIColor(rgb: 0x525252), primaryTextColor: .white, backgroundColor: UIColor(white: 0.0, alpha: 0.6), separatorColor: UIColor(white: 0.0, alpha: 0.8), badgeBackgroundColor: .clear, badgeStrokeColor: .clear, badgeTextColor: .clear)
        
        super.init(navigationBarPresentationData: NavigationBarPresentationData(theme: darkNavigationTheme, strings: NavigationBarStrings(presentationStrings: self.presentationData.strings)))
        
        self.supportedOrientations = ViewControllerSupportedOrientations(regularSize: .all, compactSize: .portrait)
        
        let backItem = UIBarButtonItem(backButtonAppearanceWithTitle: "Chat", target: self, action: #selector(self.closePressed))
        self.navigationItem.leftBarButtonItem = backItem
        
        self.statusBar.statusBarStyle = .White
        
        self._ready.set(combineLatest([
            self.contentsReady.get(),
            self.dataReady.get()
        ])
        |> map { values -> Bool in
            for value in values {
                if !value {
                    return false
                }
            }
            return true
        }
        |> filter { $0 })
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    @objc private func closePressed() {
        self.dismiss()
    }
    
    override public func loadDisplayNode() {
        self.displayNode = Node(controller: self, sharedContext: self.sharedContext, call: self.call)
        
        self.displayNodeDidLoad()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.isDismissed = false
        
        if !self.didAppearOnce {
            self.didAppearOnce = true
            
            self.controllerNode.animateIn()
        }
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        if !self.isDismissed {
            self.isDismissed = true
            self.didAppearOnce = false
            
            self.controllerNode.animateOut(completion: { [weak self] in
                completion?()
                self?.presentingViewController?.dismiss(animated: false)
            })
        }
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, navigationHeight: self.navigationHeight, transition: transition)
    }
}
