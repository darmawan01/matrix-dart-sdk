# Matrix VoIP Group Calls Implementation Guide

This guide explains how to implement Matrix VoIP group calls using the matrix-dart-sdk, based on real-world implementation examples and fixes for common issues.

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Implementation Steps](#implementation-steps)
4. [WebRTC Delegate Implementation](#webrtc-delegate-implementation)
5. [VoIP Service Implementation](#voip-service-implementation)
6. [Group Call Flow](#group-call-flow)
7. [Common Issues and Fixes](#common-issues-and-fixes)
8. [Best Practices](#best-practices)
9. [Troubleshooting](#troubleshooting)

## Overview

Matrix VoIP group calls use WebRTC for real-time communication and Matrix room state events for call coordination. The system supports both mesh (peer-to-peer) and SFU (Selective Forwarding Unit) backends.

### Key Components

- **VoIP**: Main VoIP manager that handles call sessions and group call sessions
- **GroupCallSession**: Manages a specific group call, its state, and participants
- **WebRTCDelegate**: Handles WebRTC-specific operations (audio/video, peer connections)
- **CallBackend**: Abstract class for different call implementations (Mesh, LiveKit, etc.)
- **CallParticipant**: Represents a participant in a call

## Architecture

```
┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
│   Your App      │    │   Matrix SDK     │    │   WebRTC        │
│                 │    │                  │    │                 │
│ VoipService     │◄──►│ VoIP             │◄──►│ WebRTCDelegate  │
│                 │    │ GroupCallSession │    │                 │
│                 │    │ CallBackend      │    │                 │
└─────────────────┘    └──────────────────┘    └─────────────────┘
```

## Implementation Steps

### 1. Initialize VoIP Service

```dart
class VoipService {
  static final VoipService instance = VoipService._();
  VoipService._();

  late final VoIP _voip;
  late final YourWebRTCDelegate _webrtcDelegate;

  void init(Client matrixClient) {
    _webrtcDelegate = YourWebRTCDelegate();
    _voip = VoIP(matrixClient, _webrtcDelegate);
  }
}
```

### 2. Implement WebRTC Delegate

```dart
class YourWebRTCDelegate implements WebRTCDelegate {
  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    // Handle incoming group call
    // Play ringtone, show UI, etc.
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
    // Clean up when group call ends
  }

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) {
    // Create WebRTC peer connection
    return createPeerConnection(configuration, constraints);
  }

  @override
  MediaDevices get mediaDevices => navigator.mediaDevices;

  // ... other required methods
}
```

### 3. Initiate Group Call

```dart
Future<bool> initiateGroupCall(Room room) async {
  try {
    // Check permissions
    final hasPermissions = await _checkVoipPermissions();
    if (!hasPermissions) return false;

    // Generate unique call ID
    final callId = '${DateTime.now().millisecondsSinceEpoch}${room.id}';

    // Create group call session
    final groupCallSession = await _voip.fetchOrCreateGroupCall(
      callId,
      room,
      MeshBackend(), // or LiveKitBackend()
      'm.call',
      'm.room',
      preShareKey: false,
    );

    // Enter the group call
    await groupCallSession.enter();

    return true;
  } catch (e) {
    print('Error initiating group call: $e');
    return false;
  }
}
```

### 4. Handle Incoming Group Call

```dart
@override
Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
  // Store the group call
  _currentGroupCall = groupCall;
  
  // Play incoming ringtone
  await _playIncomingRingtone();
  
  // Show UI to user
  _showIncomingCallUI(groupCall);
}
```

### 5. Answer Group Call

```dart
Future<void> answerGroupCall() async {
  try {
    final groupCall = _currentGroupCall;
    if (groupCall == null) return;

    // Check permissions
    final hasPermissions = await _checkVoipPermissions();
    if (!hasPermissions) return;

    // Enter the group call
    await groupCall.enter();
    
    // Stop ringtone
    await stopRingtone();
  } catch (e) {
    print('Error answering group call: $e');
  }
}
```

## WebRTC Delegate Implementation

### Complete WebRTC Delegate Example

```dart
class YourWebRTCDelegate implements WebRTCDelegate {
  final AudioPlayer player = AudioPlayer();
  bool _isGroupCallOutgoing = false;

  @override
  Future<void> handleNewGroupCall(GroupCallSession groupCall) async {
    if (_isGroupCallOutgoing) {
      await _playOutgoingRingtone();
    } else {
      await _playIncomingRingtone();
    }
  }

  @override
  Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
    await stopRingtone();
  }

  @override
  Future<void> handleNewCall(CallSession session) async {
    switch (session.direction) {
      case CallDirection.kIncoming:
        await _playIncomingRingtone();
        break;
      case CallDirection.kOutgoing:
        await _playOutgoingRingtone();
        break;
    }
  }

  @override
  Future<void> handleCallEnded(CallSession session) async {
    await stopRingtone();
  }

  @override
  Future<void> handleMissedCall(CallSession session) async {
    // Handle missed call
  }

  @override
  bool get canHandleNewCall => true;

  @override
  bool get isWeb => kIsWeb;

  @override
  Future<RTCPeerConnection> createPeerConnection(
    Map<String, dynamic> configuration, [
    Map<String, dynamic> constraints = const {},
  ]) {
    return createPeerConnection(configuration, constraints);
  }

  @override
  MediaDevices get mediaDevices => navigator.mediaDevices;

  @override
  Future<void> playRingtone() async {
    // Implement if needed
  }

  @override
  Future<void> stopRingtone() async {
    await player.stop();
  }

  @override
  EncryptionKeyProvider? get keyProvider => null;

  @override
  Future<void> registerListeners(CallSession session) async {
    session.onCallStateChanged.stream.listen((state) async {
      switch (state) {
        case CallState.kConnected:
          await stopRingtone();
          break;
        case CallState.kEnded:
          await stopRingtone();
          break;
        default:
          break;
      }
    });
  }

  void setGroupCallDirection(bool isOutgoing) {
    _isGroupCallOutgoing = isOutgoing;
  }

  Future<void> _playIncomingRingtone() async {
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(0.8);
    await player.play(AssetSource('audio/incoming-call.wav'));
  }

  Future<void> _playOutgoingRingtone() async {
    await player.setReleaseMode(ReleaseMode.loop);
    await player.setVolume(0.6);
    await player.play(AssetSource('audio/outgoing-call.wav'));
  }
}
```

## VoIP Service Implementation

### Complete VoIP Service Example

```dart
class VoipService {
  static final VoipService instance = VoipService._();
  VoipService._();

  late final VoIP _voip;
  late final YourWebRTCDelegate _webrtcDelegate;

  final _currentGroupCall = Rxn<GroupCallSession>();
  final _groupCallStateStream = StreamController<GroupCallSession>.broadcast();

  Stream<GroupCallSession> get groupCallStateStream => _groupCallStateStream.stream;
  GroupCallSession? get currentGroupCall => _currentGroupCall.value;

  void init(Client matrixClient) {
    _webrtcDelegate = YourWebRTCDelegate();
    _voip = VoIP(matrixClient, _webrtcDelegate);
  }

  Future<bool> initiateGroupCall(Room room) async {
    try {
      // Clear any existing call
      if (_currentGroupCall.value != null) {
        clearCall();
      }

      // Check permissions
      final hasPermissions = await _checkVoipPermissions();
      if (!hasPermissions) return false;

      // Set outgoing direction
      _webrtcDelegate.setGroupCallDirection(true);

      // Generate unique call ID
      final callId = '${DateTime.now().millisecondsSinceEpoch}${room.id}';

      // Create group call session
      final groupCallSession = await _voip.fetchOrCreateGroupCall(
        callId,
        room,
        MeshBackend(),
        'm.call',
        'm.room',
        preShareKey: false,
      );

      // Store and notify
      _currentGroupCall.value = groupCallSession;
      _groupCallStateStream.add(groupCallSession);

      // Enter the group call
      await groupCallSession.enter();

      return true;
    } catch (e) {
      print('Error initiating group call: $e');
      return false;
    }
  }

  Future<void> answerGroupCall() async {
    try {
      final groupCall = _currentGroupCall.value;
      if (groupCall == null) return;

      // Check permissions
      final hasPermissions = await _checkVoipPermissions();
      if (!hasPermissions) return;

      // Enter the group call
      await groupCall.enter();
      
      // Stop ringtone
      await _webrtcDelegate.stopRingtone();
    } catch (e) {
      print('Error answering group call: $e');
    }
  }

  Future<void> hangupGroupCall() async {
    try {
      final groupCall = _currentGroupCall.value;
      if (groupCall == null) return;

      await groupCall.leave();
      _currentGroupCall.value = null;
    } catch (e) {
      print('Error hanging up group call: $e');
    }
  }

  Future<void> setMicrophoneMuted(bool muted) async {
    try {
      final groupCall = _currentGroupCall.value;
      if (groupCall == null) return;

      await groupCall.backend.setDeviceMuted(
        groupCall,
        muted,
        MediaInputKind.audioinput,
      );
    } catch (e) {
      print('Error setting microphone mute: $e');
    }
  }

  Future<void> setCameraMuted(bool muted) async {
    try {
      final groupCall = _currentGroupCall.value;
      if (groupCall == null) return;

      await groupCall.backend.setDeviceMuted(
        groupCall,
        muted,
        MediaInputKind.videoinput,
      );
    } catch (e) {
      print('Error setting camera mute: $e');
    }
  }

  void clearCall() {
    _currentGroupCall.value = null;
    _webrtcDelegate.setGroupCallDirection(false);
  }

  Future<bool> _checkVoipPermissions() async {
    // Implement permission checking
    return true;
  }
}
```

## Group Call Flow

### 1. Call Initiation Flow

```
Device A (Initiator)          Matrix Server          Device B (Receiver)
     |                            |                        |
     |-- Create Group Call ------>|                        |
     |                            |                        |
     |-- Send Member State Event ->|                        |
     |                            |                        |
     |                            |-- Room State Event --->|
     |                            |                        |
     |                            |                        |-- handleNewGroupCall()
     |                            |                        |
     |                            |                        |-- Play Ringtone
     |                            |                        |
     |                            |                        |-- Show UI
```

### 2. Call Answer Flow

```
Device B (Receiver)           Matrix Server          Device A (Initiator)
     |                            |                        |
     |-- Enter Group Call ------->|                        |
     |                            |                        |
     |-- Send Member State Event ->|                        |
     |                            |                        |
     |                            |-- Room State Event --->|
     |                            |                        |
     |                            |                        |-- onMemberStateChanged()
     |                            |                        |
     |                            |                        |-- Setup P2P Connection
     |                            |                        |
     |<-- WebRTC Connection -----|                        |
     |                            |                        |
     |-- Audio/Video Stream ----->|                        |
```

## Common Issues and Fixes

### 1. Participant Detection Issues

**Problem**: Participants are incorrectly marked as "left" instead of being recognized as active.

**Solution**: The SDK now includes robust participant detection with false positive filtering:

```dart
// In GroupCallSession.onMemberStateChanged()
if (anyLeft.isNotEmpty) {
  // Filter out participants that might be false positives
  final confirmedLeft = <CallParticipant>[];
  for (final participant in anyLeft) {
    // Check if this participant is actually still in the room memberships
    final stillInMemberships = memsForCurrentGroupCall.any((mem) =>
        mem.userId == participant.userId && 
        mem.deviceId == participant.deviceId);
    
    if (!stillInMemberships) {
      confirmedLeft.add(participant);
    } else {
      // False positive - participant is still in memberships
    }
  }
  
  // Only process confirmed left participants
  if (confirmedLeft.isNotEmpty) {
    // Handle left participants
  }
}
```

### 2. Lexicographical Ordering Deadlock

**Problem**: Both devices wait for each other to initiate the call due to identical participant IDs.

**Solution**: Enhanced comparison logic with fallback:

```dart
// In MeshBackend.setupP2PCallWithNewMember()
final localId = groupCall.localParticipant!.id;
final remoteId = rp.id;

if (localId.compareTo(remoteId) > 0) {
  // Wait for remote to initiate
  return;
} else if (localId.compareTo(remoteId) == 0) {
  // Fallback: Use session ID for comparison
  final localSessionId = groupCall.voip.currentSessionId;
  final remoteSessionId = mem.membershipId;
  
  if (localSessionId.compareTo(remoteSessionId) > 0) {
    return;
  }
}

// Proceed with call initiation
```

### 3. Room State Event Processing

**Problem**: Room state events not being processed correctly.

**Solution**: Use timeline events instead of room state events:

```dart
// In VoIP constructor
client.onTimelineEvent.stream.listen((event) {
  // Process room state events from timeline
  if (event.type == 'm.call.member') {
    // Handle call member events
  }
});
```

### 4. Permission Issues

**Problem**: Calls fail due to missing permissions.

**Solution**: Always check permissions before call operations:

```dart
Future<bool> _checkVoipPermissions() async {
  final permissions = [
    Permission.microphone,
    Permission.camera,
  ];

  final result = await permissions.request();
  
  for (final permission in permissions) {
    if (result[permission] != PermissionStatus.granted) {
      return false;
    }
  }
  
  return true;
}
```

## Best Practices

### 1. Error Handling

Always wrap call operations in try-catch blocks:

```dart
try {
  await groupCall.enter();
} catch (e, s) {
  print('Failed to enter group call: $e');
  // Handle error appropriately
}
```

### 2. State Management

Keep track of call state and handle transitions properly:

```dart
// Listen to call state changes
groupCall.onGroupCallEvent.stream.listen((event) {
  switch (event) {
    case GroupCallStateChange.participantsChanged:
      // Handle participant changes
      break;
    case GroupCallStateChange.stateChanged:
      // Handle state changes
      break;
  }
});
```

### 3. Resource Cleanup

Always clean up resources when calls end:

```dart
@override
Future<void> handleGroupCallEnded(GroupCallSession groupCall) async {
  await stopRingtone();
  // Clean up any other resources
}
```

### 4. Debugging

Enable verbose logging for debugging:

```dart
// The SDK now includes comprehensive logging
// Look for logs starting with [VOIP] for debugging information
```

## Troubleshooting

### Common Log Messages

- `[VOIP] All memberships found: ...` - Shows all call memberships in the room
- `[VOIP] Memberships for current group call: ...` - Shows memberships for the current call
- `[VOIP] Participant changes detected: ...` - Shows participant join/leave events
- `[VOIP] False positive left detection for: ...` - Indicates false positive detection
- `[VOIP] Lexicographical comparison: ...` - Shows participant ID comparison

### Debugging Steps

1. **Check Logs**: Look for `[VOIP]` prefixed logs to understand the flow
2. **Verify Permissions**: Ensure microphone/camera permissions are granted
3. **Check Room State**: Verify the room has group calls enabled
4. **Monitor Participants**: Watch for participant detection issues
5. **Test Network**: Ensure stable network connection

### Common Error Messages

- `Cannot enter call in the [state] state` - Call is in wrong state
- `Client userID or deviceID is null` - Matrix client not properly initialized
- `Failed to enable group calls` - Permission issues with room
- `Waiting for [participant] to send call invite` - Lexicographical ordering issue

## Conclusion

This guide provides a comprehensive overview of implementing Matrix VoIP group calls. The key to success is:

1. **Proper initialization** of the VoIP service and WebRTC delegate
2. **Robust error handling** throughout the call flow
3. **Correct state management** for call sessions
4. **Permission handling** for media access
5. **Debugging** using the comprehensive logging system

The fixes implemented in the SDK address common issues like participant detection, lexicographical ordering deadlocks, and room state event processing, making group calls more reliable and easier to debug.
