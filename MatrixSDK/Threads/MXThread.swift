// 
// Copyright 2021 The Matrix.org Foundation C.I.C
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

@objcMembers
/// Thread instance. Use `MXThreadingService` to access threads.
public class MXThread: NSObject {
    
    /// Session instance
    public private(set) weak var session: MXSession?
    
    /// Identifier of a thread. It's equal to identifier of the root event
    public let id: String
    
    /// Identifier of the room that the thread is in.
    public let roomId: String
    
    private var _liveTimeline: MXEventTimeline?
    private var eventsMap: [String: MXEvent] = [:]
    private var liveTimelineOperationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.isSuspended = true
        return queue
    }()
    
    internal init(withSession session: MXSession,
                  identifier: String,
                  roomId: String) {
        self.session = session
        self.id = identifier
        self.roomId = roomId
        super.init()
    }
    
    internal init(withSession session: MXSession,
                  rootEvent: MXEvent) {
        self.session = session
        self.id = rootEvent.eventId
        self.roomId = rootEvent.roomId
        self.eventsMap = [rootEvent.eventId: rootEvent]
        super.init()
    }
    
    /// Add an event to the thread
    /// - Parameter event: Event
    /// - Returns: true if handled, false otherwise
    @discardableResult
    internal func addEvent(_ event: MXEvent) -> Bool {
        guard eventsMap[event.eventId] == nil else {
            //  do not re-add the event
            return false
        }
        eventsMap[event.eventId] = event
        updateNotificationsCount()
        if event.sender == session?.myUserId {
            //  the user sent a message to the thread, so mark the thread as read
            markAsRead()
        }
        return true
    }
    
    /// Number of notifications in the thread
    public private(set) var notificationCount: UInt = 0
    
    /// Number of highlights in the thread
    public private(set) var highlightCount: UInt = 0
    
    /// Flag indicating the current user participated in the thread
    public var isParticipated: Bool {
        guard let session = session else {
            return false
        }
        return eventsMap.values.first(where: { $0.sender == session.myUserId }) != nil
    }
    
    /// Root message of the thread
    public var rootMessage: MXEvent? {
        return eventsMap[id] ?? session?.store?.event(withEventId: id, inRoom: roomId)
    }
    
    /// Last message of the thread
    public var lastMessage: MXEvent? {
        //  sort events so that the older is the first
        return eventsMap.values.sorted(by: >).last
    }
    
    /// Number of replies in the thread. Does not count the root event
    public var numberOfReplies: Int {
        return eventsMap.filter({ $0 != id && $1.isInThread() }).count
    }
    
    /// The live events timeline
    /// - Parameter completion: Completion block
    public func liveTimeline(_ completion: @escaping (MXEventTimeline) -> Void) {
        if let timeline = _liveTimeline {
            liveTimelineOperationQueue.addOperation {
                DispatchQueue.main.async {
                    completion(timeline)
                }
            }
        } else if let session = session {
            _liveTimeline = MXThreadEventTimeline(thread: self, andInitialEventId: nil)
            MXRoomState.load(from: session.store, withRoomId: self.roomId, matrixSession: session) { roomState in
                self._liveTimeline?.state = roomState
                self.liveTimelineOperationQueue.isSuspended = false
                if let timeline = self._liveTimeline {
                    completion(timeline)
                }
            }
        }
    }
    
    /// Timeline on a specific event
    /// - Parameter eventId: Event identifier
    /// - Returns: The timeline
    public func timelineOnEvent(_ eventId: String) -> MXEventTimeline {
        return MXThreadEventTimeline(thread: self, andInitialEventId: eventId)
    }
    
    /// Fetches all replies in a thread. Not used right now
    /// - Parameter completion: Completion block to be called at the end of the progress
    public func allReplies(completion: @escaping (MXResponse<[MXEvent]>) -> Void) {
        guard let session = session else {
            completion(.failure(MXThreadingServiceError.sessionNotFound))
            return
        }
        
        session.matrixRestClient.relations(forEvent: id,
                                           inRoom: roomId,
                                           relationType: MXEventRelationTypeThread,
                                           eventType: nil,
                                           from: nil,
                                           limit: nil) { response in
            switch response {
            case .success(let aggregatedResponse):
                completion(.success(aggregatedResponse.chunk))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Mark all messages of thread as read
    internal func markAsRead() {
        notificationCount = 0
        highlightCount = 0
    }
    
    private func updateNotificationsCount() {
        guard let session = session, let store = session.store else {
            return
        }
        
        notificationCount = store.localUnreadEventCount(roomId, threadId: id, withTypeIn: session.unreadEventTypes)
        guard let readReceipt = store.getReceiptInRoom(roomId, forUserId: session.myUserId) else {
            return
        }
        highlightCount = UInt(eventsMap.values
                                .filter { $0.originServerTs > readReceipt.ts }
                                .filter { shouldHighlight(event: $0, in: session) }
                                .count)
    }

    private func shouldHighlight(event: MXEvent, in session: MXSession) -> Bool {
        let displayNameChecker = MXPushRuleDisplayNameCondtionChecker(matrixSession: session,
                                                                      currentUserDisplayName: nil)

        if displayNameChecker.isCondition(nil, satisfiedBy: event, roomState: nil, withJsonDict: nil) {
            return true
        }
        guard let rule = session.notificationCenter.rule(matching: event, roomState: nil) else {
            return false
        }

        var isHighlighted = false

        // Check whether is there an highlight tweak on it
        for ruleAction in rule.actions ?? [] {
            guard let action = ruleAction as? MXPushRuleAction else { continue }
            guard action.actionType == MXPushRuleActionTypeSetTweak else { continue }
            guard action.parameters["set_tweak"] as? String == "highlight" else { continue }
            // Check the highlight tweak "value"
            // If not present, highlight. Else check its value before highlighting
            if nil == action.parameters["value"] || true == (action.parameters["value"] as? Bool) {
                isHighlighted = true
                break
            }
        }

        return isHighlighted
    }
}

//  MARK: - Identifiable

extension MXThread: Identifiable {}

//  MARK: - Comparable

extension MXThread: Comparable {
    
    /// Comparator for thread instances, to compare two threads according to their last message time.
    /// - Parameters:
    ///   - lhs: left operand
    ///   - rhs: right operand
    /// - Returns: true if left operand's last message is newer than the right operand's last message, false otherwise
    public static func < (lhs: MXThread, rhs: MXThread) -> Bool {
        //  thread will be 'smaller' than an other thread if it's last message is newer
        let leftLastMessage = lhs.lastMessage
        let rightLastMessage = rhs.lastMessage
        if let leftLastMessage = leftLastMessage {
            if let rightLastMessage = rightLastMessage {
                return leftLastMessage < rightLastMessage
            } else {
                return false
            }
        } else if rightLastMessage != nil {
            return true
        } else {
            return false
        }
    }
    
}

//  MARK: - MXEvent Extension

extension MXEvent: Comparable {
    
    /// Compare two events according to their time
    /// - Parameters:
    ///   - lhs: Left operand
    ///   - rhs: Right operand
    /// - Returns: true if the left operand is newer than the right one, false otherwise
    public static func < (lhs: MXEvent, rhs: MXEvent) -> Bool {
        if lhs.originServerTs != kMXUndefinedTimestamp && rhs.originServerTs != kMXUndefinedTimestamp {
            //  higher originServerTs means more recent event
            return lhs.originServerTs > rhs.originServerTs
        }
        return lhs.age < rhs.age
    }
    
}
