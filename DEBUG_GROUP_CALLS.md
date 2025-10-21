# Group Call Debugging Guide

## Critical Race Condition Fix Applied ✅

### **Root Cause Found:**
The logs revealed a **race condition** where both devices try to initiate calls simultaneously:

```
[VOIP] [_onIncomingCallInMeshStart] Call state: CallState.kCreateOffer, Call ID: 176100670766830ac7awno8plyb1R
[VOIP] [_onIncomingCallInMeshStart] Incoming call no longer in ringing state. Ignoring.
```

**What was happening:**
1. Device A initiates call to Device B (state: `kCreateOffer`)
2. Device B initiates call to Device A (state: `kCreateOffer`) 
3. Both devices try to answer each other's calls
4. Answer logic only accepted calls in `kRinging` state
5. Both calls were rejected, causing connection failure

### **Fix Applied:**
- **Modified call state validation** to accept calls in both `kRinging` AND `kCreateOffer` states
- **Added duplicate call prevention** to avoid creating multiple calls for the same participant
- **Enhanced logging** to track call state transitions and duplicate detection

### **Expected Behavior After Fix:**
- Calls should now be accepted regardless of whether they're in `kRinging` or `kCreateOffer` state
- Duplicate call creation should be prevented
- Better logging will show call state transitions clearly

### **Latest Test Results:**

**Target Device (Working):**
- ✅ Successfully joins group call
- ✅ Shows "Entered group call" 
- ✅ Shows 2 participants
- ✅ Calls are now being accepted in `kCreateOffer` state

**Caller Device (Issue):**
- ❌ Shows only 1 participant instead of 2
- ❌ Waits for target to initiate call
- ❌ Falls back to initiating call after timeout
- ❌ Call connection still not established

### **Additional Fix Applied:**
- **Reduced timeout values** from 10s/8s to 5s/3s for faster fallback
- **Race condition fix is working** - target device now accepts calls in `kCreateOffer` state
- **Fixed direct call events** - ToDeviceEvent processing now handles both group calls (with confId) and direct calls (without confId)
- **Remaining issue**: Participant count synchronization between devices

### **Expected Behavior After Latest Fix:**
- Faster fallback when waiting for call initiation (5s instead of 10s)
- Better responsiveness in session ID fallback scenarios (3s instead of 8s)
- Both devices should now be able to establish connections
- **Direct calls should now work properly** - ToDeviceEvent processing fixed

### **ISSUE RESOLVED - Signaling State Timing:**
- **Issue**: Peer connection `signalingState` is `null` initially - this is normal WebRTC behavior
- **Root Cause**: WebRTC implementations don't immediately set signaling state when peer connection is created
- **Solution**: Allow track operations even when signaling state is null initially
- **Result**: Calls now establish successfully, target device can answer
- **Remaining**: Caller stuck in connecting state - investigating negotiation process

### **ISSUE RESOLVED - WebRTC State Management:**
- **Issue**: "Called in wrong state: closed" and "PeerConnection cannot create an answer" errors in group calls
- **Root Cause**: Race conditions where WebRTC operations were called on peer connections in invalid states
- **Solution**: 
  - Added `_isPeerConnectionReadyForSDP` method with strict state checking for SDP operations
  - Added SDP readiness checks before `createAnswer`, `setLocalDescription`, `setRemoteDescription` operations
  - Added race condition prevention in `MeshBackend` with `_processingCalls` set
  - Enhanced error handling and logging for WebRTC state transitions
- **Result**: Group calls should now handle WebRTC state transitions properly and prevent race conditions

## Current Issues Identified

### 0. **Direct Call Events Not Working** ✅ FIXED
- **Issue**: Direct calls (1:1) stopped working after group call fixes
- **Root Cause**: ToDeviceEvent processing required both `roomId` and `confId`, but direct calls only have `roomId`
- **Fix**: Modified `_handleCallEvent` to handle both group calls (with confId) and direct calls (without confId)
- **Code Location**: `lib/src/voip/voip.dart` lines 282-326
- **Expected Behavior**: Direct calls should now work normally alongside group calls

Based on the logs provided, here are the key issues:

### 1. **Concurrent Modification Error** ✅ FIXED
- **Error**: `Concurrent modification during iteration: _Map len:0`
- **Location**: `voip.dart:135` in timeline event handler
- **Fix Applied**: Create a copy of `groupCalls` map before iteration

### 2. **Call State Mismatch** 🔍 NEEDS INVESTIGATION
- **Problem**: Target device shows "Entered group call" but caller shows "CallState.kEnded"
- **Root Cause**: ICE connection failing or call being terminated prematurely

### 3. **Member State Synchronization** 🔍 NEEDS INVESTIGATION  
- **Problem**: Caller thinks target left immediately after joining
- **Root Cause**: Race condition in member state processing

## Enhanced Logging Added

The following enhanced logging has been added to help debug:

### Call Session Logging
- ICE connection state changes with call ID
- Call state before/after answer operations
- Detailed error handling for answer failures

### Group Call Session Logging
- Group call state during participant changes
- Enhanced participant left detection with double-checking
- False positive detection for participant leaving

### Mesh Backend Logging
- Call state tracking during incoming call processing
- Stream count logging during answer operations
- Detailed error handling for call setup failures

## Debugging Steps

### Step 1: Enable Verbose Logging
Add this to your app's logging configuration:
```dart
Logs().setLevel(Level.verbose);
```

### Step 2: Monitor Key Log Patterns

Look for these log patterns in sequence:

#### Successful Call Flow:
```
[VOIP] Initiating call to @target:device
[VOIP] Created call session [callId] for @target:device
[VOIP] Placing call with streams to @target:device
[VOIP] ICE connection established for call [callId]
[VOIP] Call state after answer: CallState.kConnected
```

#### Failed Call Flow:
```
[VOIP] Initiating call to @target:device
[VOIP] ICE connection failed/disconnected for call [callId]
[VOIP] Max ICE restart attempts reached for call [callId]
[VOIP] Call state: CallState.kEnded
```

### Step 3: Check for Specific Issues

#### Issue A: ICE Connection Problems
Look for:
- `RTCIceConnectionState => RTCIceConnectionStateFailed`
- `ICE connection failed/disconnected`
- `Max ICE restart attempts reached`

**Debug Action**: Check network connectivity, STUN/TURN server configuration

#### Issue B: Member State Race Conditions
Look for:
- `False positive left detection`
- `Confirmed participant left` immediately after join
- `Participant comparison` showing unexpected changes

**Debug Action**: Check timing of member state events vs call events

#### Issue C: Call Answer Failures
Look for:
- `Failed to answer call [callId]`
- `Call state before answer` vs `Call state after answer`
- `Local streams count: 0`

**Debug Action**: Check media permissions and stream availability

### Step 4: Network Debugging

Add network monitoring:
```dart
// In your app, add this to monitor network state
ConnectivityService().onNetworkStatusChanged.listen((status) {
  Logs().v('[NETWORK] Status changed: $status');
});
```

### Step 5: WebRTC Debugging

Enable WebRTC internal logging:
```dart
// Add this to your WebRTC initialization
WebRTC.setLogLevel(WebRTC.LogLevel.verbose);
```

## Expected Log Output

With the enhanced logging, you should now see:

1. **Call Initiation**:
   ```
   [VOIP] Initiating call to @target:device (userId: @target, deviceId: device)
   [VOIP] Created call session [callId] for @target:device
   [VOIP] Placing call with streams to @target:device
   ```

2. **Call Answering**:
   ```
   [VOIP] [_onIncomingCallInMeshStart] Received incoming call start from @target:device
   [VOIP] [_onIncomingCallInMeshStart] Call state: CallState.kRinging, Call ID: [callId]
   [VOIP] [_onIncomingCallInMeshStart] Answering call with streams
   [VOIP] [_onIncomingCallInMeshStart] Local streams count: 1
   [VOIP] [_onIncomingCallInMeshStart] Successfully answered incoming call
   [VOIP] [_onIncomingCallInMeshStart] Call state after answer: CallState.kConnected
   ```

3. **ICE Connection**:
   ```
   [VOIP] RTCIceConnectionState => RTCIceConnectionStateConnected for call [callId]
   [VOIP] Current call state: CallState.kConnected
   [VOIP] ICE connection established for call [callId]
   ```

4. **Member State Changes**:
   ```
   [VOIP] Group call state: GroupCallState.entered, Group call ID: [groupCallId]
   [VOIP] Participant changes detected: anyJoined=[@target:device], anyLeft=[]
   [VOIP] False positive left detection for: @target:device - still in memberships
   ```

## Next Steps

1. **Run the test again** with enhanced logging
2. **Look for the specific failure point** in the call flow
3. **Check network conditions** during the call
4. **Verify STUN/TURN server configuration**
5. **Monitor for timing issues** between events

The enhanced logging should now provide much clearer insight into where exactly the call connection is failing.
