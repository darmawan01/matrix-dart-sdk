# Matrix VoIP Call Flow Analysis

## Overview

This document provides a comprehensive analysis of how normal calls (1:1) and group calls work in the Matrix Dart SDK, along with potential problem areas and debugging recommendations.

## Normal Calls (1:1 Calls)

### Outgoing Call Flow

```
User Initiates Call
    ↓
VoIP.inviteToCall()
    ↓
CallSession.initOutboundCall()
    ↓
_preparePeerConnection() → Create RTCPeerConnection
    ↓
_getUserMedia() → Get camera/microphone access
    ↓
addLocalStream() → Add media tracks to peer connection
    ↓
onNegotiationNeeded() → Triggered when tracks added
    ↓
createOffer() → Generate SDP offer
    ↓
sendInviteToCall() → Send m.call.invite event
    ↓
Wait for Answer → Receive m.call.answer
    ↓
setRemoteDescription() → Process answer SDP
    ↓
ICE Candidates Exchange → m.call.candidates events
    ↓
Connection Established → CallState.kConnected
```

### Incoming Call Flow

```
Receive m.call.invite Event
    ↓
CallSession.initWithInvite()
    ↓
_preparePeerConnection() → Create RTCPeerConnection
    ↓
setRemoteDescription() → Process incoming offer
    ↓
_getUserMedia() → Get camera/microphone access
    ↓
addLocalStream() → Add media tracks
    ↓
createAnswer() → Generate SDP answer
    ↓
sendAnswerCall() → Send m.call.answer event
    ↓
ICE Candidates Exchange → m.call.candidates events
    ↓
Connection Established → CallState.kConnected
```

### Key Components

- **Signaling Events**: `m.call.invite`, `m.call.answer`, `m.call.candidates`, `m.call.hangup`, `m.call.negotiate`
- **WebRTC**: RTCPeerConnection lifecycle, ICE gathering, SDP negotiation
- **Media Management**: getUserMedia, track add/remove, mute/unmute
- **State Management**: CallState transitions, timers (invite/ringing), cleanup

## Group Calls (Mesh Backend)

### Entering a Group Call

```
User Joins Group Call
    ↓
GroupCallSession.enter()
    ↓
backend.initLocalStream() → Initialize local media
    ↓
sendMemberStateEvent() → Send com.famedly.call.member event
    ↓
onMemberStateChanged() → Process existing members
    ↓
setupP2PCallsWithExistingMembers() → Create P2P calls with each member
    ↓
Lexicographical Comparison → Determine who initiates each P2P call
    ↓
For Each Member:
    ├─ If localId > remoteId: Wait for incoming call
    └─ If localId < remoteId: Initiate outgoing call
    ↓
Multiple P2P CallSessions Created → One per participant
    ↓
All Calls Connected → Group call active
```

### New Member Joins Flow

```
Receive com.famedly.call.member Event
    ↓
GroupCallSession.onMemberStateChanged()
    ↓
setupP2PCallWithNewMember() → Create P2P call with new member
    ↓
Lexicographical Comparison → Determine call initiator
    ↓
Create CallSession → Either incoming or outgoing
    ↓
Add to Group Call → Participant joins
```

### Group Call Key Components

- **Member State Events**: `com.famedly.call.member` for signaling participation
- **Mesh Backend**: Manages multiple P2P CallSessions
- **Stream Management**: userMediaStreams, screenshareStreams
- **Active Speaker**: Audio level detection via getStats
- **Periodic Updates**: Member state events with expires_ts bump

## Potential Problem Areas

### A. Media Access Issues

- **getUserMedia() failures** → Camera/microphone permission denied
- **Device constraints** → Hardware not available
- **Browser compatibility** → Different WebRTC implementations
- **Media device changes** → Device disconnected during call

### B. WebRTC Connection Issues

- **ICE gathering failures** → NAT traversal problems
- **STUN/TURN server issues** → Connectivity problems
- **Peer connection state errors** → Network instability
- **SDP negotiation failures** → Codec incompatibilities
- **Glare resolution** → Simultaneous offer collisions

### C. Matrix Event Handling

- **Event ordering** → Race conditions in event processing
- **Encryption/decryption** → E2EE key issues
- **Room state synchronization** → Stale membership data
- **Event delivery failures** → Network issues
- **To-device vs room events** → Different delivery guarantees

### D. Group Call Specific Issues

- **Lexicographical comparison edge cases** → Same participant IDs
- **Member state synchronization** → Timing issues with member events
- **P2P call management** → Multiple simultaneous connections
- **Fallback mechanisms** → When other participant doesn't initiate call
- **Participant cleanup** → Handling left participants reliably

### E. State Management Issues

- **Call state transitions** → Invalid state changes
- **Resource cleanup** → Memory leaks from streams/connections
- **Timer management** → Expired events not handled properly
- **Concurrent operations** → Race conditions
- **Timeout handling** → Call invite/answer timeouts

### F. Error Handling

- **Retry mechanisms** → Failed operations not retried
- **Error propagation** → Errors not properly surfaced
- **Recovery strategies** → No fallback when calls fail
- **Graceful degradation** → Partial failures not handled

## Critical Failure Points

1. **Media Stream Initialization** - If getUserMedia fails, entire call fails
2. **Peer Connection Creation** - WebRTC setup failures
3. **SDP Exchange** - Offer/answer negotiation failures
4. **ICE Connectivity** - NAT traversal failures
5. **Matrix Event Delivery** - Network/encryption issues
6. **Group Call Member Synchronization** - State consistency issues
7. **Resource Management** - Memory leaks from uncleaned resources

## Debugging Recommendations

### 1. Add Comprehensive Logging

```dart
// At each step of the call flow
Logs().v('[VOIP] Step: ${stepName} - State: ${currentState}');
Logs().e('[VOIP] Error in ${stepName}', error, stackTrace);
```

### 2. Implement Health Checks

```dart
// Monitor peer connection and media stream health
bool isPeerConnectionHealthy() {
  return pc?.connectionState == RTCPeerConnectionState.RTCPeerConnectionStateConnected;
}

bool isMediaStreamActive() {
  return localUserMediaStream?.stream?.getTracks().isNotEmpty ?? false;
}
```

### 3. Add Timeout and Retry Mechanisms

```dart
// Retry failed operations with exponential backoff
Future<T> retryWithBackoff<T>(Future<T> Function() operation, int maxRetries) async {
  for (int i = 0; i < maxRetries; i++) {
    try {
      return await operation();
    } catch (e) {
      if (i == maxRetries - 1) rethrow;
      await Future.delayed(Duration(milliseconds: 500 * pow(2, i)));
    }
  }
  throw Exception('Max retries exceeded');
}
```

### 4. Monitor Resource Usage

```dart
// Track and cleanup resources
void trackResource(String resourceId, dynamic resource) {
  _activeResources[resourceId] = resource;
}

void cleanupResource(String resourceId) {
  final resource = _activeResources.remove(resourceId);
  resource?.dispose();
}
```

### 5. Implement Graceful Degradation

```dart
// Handle partial failures gracefully
Future<void> handlePartialFailure(String operation, dynamic error) async {
  Logs().w('[VOIP] Partial failure in $operation: $error');
  // Continue with reduced functionality
  await notifyDelegateOfDegradedState();
}
```

### 6. Add Metrics Collection

```dart
// Track call success/failure rates
class CallMetrics {
  static int _successfulCalls = 0;
  static int _failedCalls = 0;
  
  static void recordCallSuccess() => _successfulCalls++;
  static void recordCallFailure() => _failedCalls++;
  
  static double get successRate => _successfulCalls / (_successfulCalls + _failedCalls);
}
```

## Key Files to Monitor

- `lib/src/voip/call_session.dart` - Core 1:1 call logic
- `lib/src/voip/group_call_session.dart` - Group call management
- `lib/src/voip/backend/mesh_backend.dart` - Mesh backend implementation
- `lib/src/voip/voip.dart` - Main VoIP coordinator

## Common Issues and Solutions

### Issue: Call fails to connect
**Check**: ICE gathering, STUN/TURN servers, network connectivity

### Issue: Group call participants not syncing
**Check**: Member state events, lexicographical comparison, timing

### Issue: Media not working
**Check**: getUserMedia permissions, device availability, track states

### Issue: Memory leaks
**Check**: Resource cleanup in dispose methods, stream management

### Issue: Race conditions
**Check**: Event ordering, state transitions, concurrent operations

## Testing Recommendations

1. **Unit Tests**: Test individual components in isolation
2. **Integration Tests**: Test call flows end-to-end
3. **Network Tests**: Test with poor network conditions
4. **Device Tests**: Test with different devices and browsers
5. **Load Tests**: Test with multiple simultaneous calls
6. **Error Injection**: Test error handling and recovery

## Recent Stability Fixes (Applied)

### 1. Fixed Race Conditions in VoIP Constructor
- **Problem**: Multiple `unawaited` calls in constructor caused race conditions
- **Solution**: Created `_initializeGroupCalls()` method with proper sequential processing and error handling
- **Impact**: Prevents initialization conflicts and ensures stable startup

### 2. Improved Lexicographical Comparison Logic
- **Problem**: Deadlocks when both participants wait for each other
- **Solution**: 
  - Added robust participant ID comparison with session ID fallback
  - Reduced timeout for session ID fallback (8s vs 10s)
  - Better logging for debugging comparison decisions
- **Impact**: Eliminates deadlock scenarios and improves call initiation reliability

### 3. Removed Arbitrary Delays and Improved Event Processing
- **Problem**: 100ms arbitrary delay caused timing issues
- **Solution**: 
  - Replaced arbitrary delay with proper `room.postLoad()` calls
  - Added sequential processing instead of `unawaited` calls
  - Enhanced error handling for individual membership processing
- **Impact**: More predictable event processing and better error recovery

### 4. Added Circuit Breakers to Prevent Cascade Failures
- **Problem**: Single call failures could cascade and destabilize entire group call
- **Solution**: 
  - Added circuit breaker pattern with configurable thresholds (5 failures, 2min timeout)
  - Tracks call success/failure rates
  - Prevents new call attempts when circuit breaker is open
  - Automatic reset after timeout or successful calls
- **Impact**: Prevents cascade failures and improves overall group call stability

### 5. Enhanced Member State Synchronization
- **Problem**: Race conditions in participant join/leave processing
- **Solution**: 
  - Added small delay (50ms) to ensure event processing completion
  - Sequential processing of new participants instead of parallel
  - Better error handling for individual participant setup failures
  - Improved participant change detection logic
- **Impact**: More reliable participant management and reduced synchronization issues

### 6. Fixed WebRTC State Management Issues
- **Problem**: "Called in wrong state: closed" and "PeerConnection cannot create an answer" errors in group calls
- **Solution**: 
  - Added `_isPeerConnectionReadyForSDP` method with strict state checking for SDP operations
  - Added SDP readiness checks before `createAnswer`, `setLocalDescription`, `setRemoteDescription` operations
  - Added race condition prevention in `MeshBackend` with `_processingCalls` set
  - Enhanced error handling and logging for WebRTC state transitions
- **Impact**: Group calls now handle WebRTC state transitions properly and prevent race conditions

### 7. Fixed Concurrent Modification Errors
- **Problem**: Concurrent modification during iteration over remote candidates
- **Solution**: Created copies of candidate lists before iteration in `onAnswerReceived` and `answer` methods
- **Impact**: Prevents crashes during WebRTC candidate processing

### 8. Fixed Direct Call Event Processing
- **Problem**: Direct calls (1:1) stopped working after group call fixes
- **Solution**: Modified `_handleCallEvent` to handle both group calls (with confId) and direct calls (without confId)
- **Impact**: Direct calls now work properly alongside group calls

### 9. Fixed Signaling State Timing Issues
- **Problem**: Peer connection `signalingState` is `null` initially - this is normal WebRTC behavior
- **Solution**: Allow track operations even when signaling state is null initially
- **Impact**: Calls now establish successfully without waiting for signaling state initialization

### Testing Recommendations for Fixes

1. **Race Condition Testing**: Test rapid group call joins/leaves
2. **Deadlock Testing**: Test with participants having similar IDs
3. **Circuit Breaker Testing**: Simulate network failures to trigger circuit breaker
4. **Event Timing Testing**: Test with slow network conditions
5. **Member Sync Testing**: Test rapid participant changes

This analysis should help identify and resolve issues in the Matrix VoIP implementation.
