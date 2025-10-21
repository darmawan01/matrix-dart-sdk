/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General License for more details.
 *
 *   You should have received a copy of the GNU Affero General License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:core';

import 'package:collection/collection.dart';

import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:matrix/src/voip/models/call_reaction_payload.dart';
import 'package:matrix/src/voip/models/voip_id.dart';
import 'package:matrix/src/voip/utils/stream_helper.dart';

/// Holds methods for managing a group call. This class is also responsible for
/// holding and managing the individual `CallSession`s in a group call.
class GroupCallSession {
  // Config
  final Client client;
  final VoIP voip;
  final Room room;

  /// is a list of backend to allow passing multiple backend in the future
  /// we use the first backend everywhere as of now
  final CallBackend backend;

  /// something like normal calls or thirdroom
  final String? application;

  /// either room scoped or user scoped calls
  final String? scope;

  GroupCallState state = GroupCallState.localCallFeedUninitialized;

  CallParticipant? get localParticipant => voip.localParticipant;

  List<CallParticipant> get participants => List.unmodifiable(_participants);
  final Set<CallParticipant> _participants = {};

  String groupCallId;

  @Deprecated('Use matrixRTCEventStream instead')
  final CachedStreamController<GroupCallState> onGroupCallState =
      CachedStreamController();

  @Deprecated('Use matrixRTCEventStream instead')
  final CachedStreamController<GroupCallStateChange> onGroupCallEvent =
      CachedStreamController();

  final CachedStreamController<MatrixRTCCallEvent> matrixRTCEventStream =
      CachedStreamController();

  Timer? _resendMemberStateEventTimer;

  factory GroupCallSession.withAutoGenId(
    Room room,
    VoIP voip,
    CallBackend backend,
    String? application,
    String? scope,
    String? groupCallId,
  ) {
    return GroupCallSession(
      client: room.client,
      room: room,
      voip: voip,
      backend: backend,
      application: application ?? 'm.call',
      scope: scope ?? 'm.room',
      groupCallId: groupCallId ?? genCallID(),
    );
  }

  GroupCallSession({
    required this.client,
    required this.room,
    required this.voip,
    required this.backend,
    required this.groupCallId,
    required this.application,
    required this.scope,
  });

  String get avatarName =>
      _getUser().calcDisplayname(mxidLocalPartFallback: false);

  String? get displayName => _getUser().displayName;

  User _getUser() {
    return room.unsafeGetUserFromMemoryOrFallback(client.userID!);
  }

  void setState(GroupCallState newState) {
    state = newState;
    // ignore: deprecated_member_use_from_same_package
    onGroupCallState.add(newState);
    // ignore: deprecated_member_use_from_same_package
    onGroupCallEvent.add(GroupCallStateChange.groupCallStateChanged);
    matrixRTCEventStream.add(GroupCallStateChanged(newState));
  }

  bool hasLocalParticipant() {
    return _participants.contains(localParticipant);
  }

  Timer? _reactionsTimer;
  int _reactionsTicker = 0;

  /// enter the group call.
  Future<void> enter({WrappedMediaStream? stream}) async {
    if (!(state == GroupCallState.localCallFeedUninitialized ||
        state == GroupCallState.localCallFeedInitialized)) {
      throw MatrixSDKVoipException('Cannot enter call in the $state state');
    }

    try {
      if (state == GroupCallState.localCallFeedUninitialized) {
        await backend.initLocalStream(this, stream: stream);
      }

      await sendMemberStateEvent();

      setState(GroupCallState.entered);

      Logs().v('Entered group call $groupCallId');

      // Clean up any stale membership events before processing current ones
      await _cleanupStaleMembershipEvents();

      // Set up _participants for the members currently in the call.
      // Other members will be picked up by the RoomState.members event.
      await onMemberStateChanged();

      await backend.setupP2PCallsWithExistingMembers(this);

      voip.currentGroupCID = VoipId(roomId: room.id, callId: groupCallId);

      await voip.delegate.handleNewGroupCall(this);

      // Log successful entry with participant count
      Logs().i(
        '[VOIP] Successfully entered group call $groupCallId with ${_participants.length} participants',
      );

      _reactionsTimer = Timer.periodic(Duration(seconds: 1), (_) {
        if (_reactionsTicker > 0) _reactionsTicker--;
      });
    } catch (e, s) {
      Logs().e('[VOIP] Failed to enter group call', e, s);
      setState(GroupCallState.localCallFeedUninitialized);
      rethrow;
    }
  }

  Future<void> leave() async {
    Logs().v('[VOIP] Leaving group call $groupCallId');

    // Remove our membership from the room state
    await removeMemberStateEvent();

    // Dispose backend resources
    await backend.dispose(this);

    // Clear local state
    setState(GroupCallState.localCallFeedUninitialized);
    voip.currentGroupCID = null;
    _participants.clear();

    // Remove from group calls registry
    voip.groupCalls.remove(VoipId(roomId: room.id, callId: groupCallId));

    // Notify delegate
    await voip.delegate.handleGroupCallEnded(this);

    // Cancel timers
    _resendMemberStateEventTimer?.cancel();
    _reactionsTimer?.cancel();

    // Set final state
    setState(GroupCallState.ended);

    Logs().v('[VOIP] Successfully left group call $groupCallId');
  }

  Future<void> sendMemberStateEvent() async {
    if (client.userID == null || client.deviceID == null) {
      throw MatrixSDKVoipException('Client userID or deviceID is null');
    }

    try {
      // Get current member event ID to preserve permanent reactions
      final currentMemberships = room.getCallMembershipsForUser(
        client.userID!,
        client.deviceID!,
        voip,
      );

      final currentMembership = currentMemberships.firstWhereOrNull(
        (m) =>
            m.callId == groupCallId &&
            m.deviceId == client.deviceID! &&
            m.application == application &&
            m.scope == scope &&
            m.roomId == room.id,
      );

      // Store permanent reactions from the current member event if it exists
      List<MatrixEvent> permanentReactions = [];
      final membershipExpired = currentMembership?.isExpired ?? false;

      if (currentMembership?.eventId != null && !membershipExpired) {
        permanentReactions = await _getPermanentReactionsForEvent(
          currentMembership!.eventId!,
        );
      }

      final newEventId = await room.updateFamedlyCallMemberStateEvent(
        CallMembership(
          userId: client.userID!,
          roomId: room.id,
          callId: groupCallId,
          application: application,
          scope: scope,
          backend: backend,
          deviceId: client.deviceID!,
          expiresTs: DateTime.now()
              .add(voip.timeouts!.expireTsBumpDuration)
              .millisecondsSinceEpoch,
          membershipId: voip.currentSessionId,
          feeds: backend.getCurrentFeeds(),
          voip: voip,
        ),
      );

      // Copy permanent reactions to the new member event
      if (permanentReactions.isNotEmpty && newEventId != null) {
        await _copyPermanentReactionsToNewEvent(
          permanentReactions,
          newEventId,
        );
      }
    } catch (e, s) {
      Logs().e('[VOIP] Failed to send member state event', e, s);
      rethrow;
    }

    if (_resendMemberStateEventTimer != null) {
      _resendMemberStateEventTimer!.cancel();
    }
    _resendMemberStateEventTimer = Timer.periodic(
      voip.timeouts!.updateExpireTsTimerDuration,
      ((timer) async {
        Logs().d('sendMemberStateEvent updating member event with timer');
        if (state != GroupCallState.ended &&
            state != GroupCallState.localCallFeedUninitialized) {
          await sendMemberStateEvent();
        } else {
          Logs().d(
            '[VOIP] detected groupCall in state $state, removing state event',
          );
          await removeMemberStateEvent();
        }
      }),
    );
  }

  Future<void> removeMemberStateEvent() async {
    if (_resendMemberStateEventTimer != null) {
      Logs().d('resend member event timer cancelled');
      _resendMemberStateEventTimer!.cancel();
      _resendMemberStateEventTimer = null;
    }

    try {
      await room.removeFamedlyCallMemberEvent(
        groupCallId,
        voip,
        application: application,
        scope: scope,
      );
      Logs().v(
        '[VOIP] Successfully removed member state event for call $groupCallId',
      );
    } catch (e, s) {
      Logs().e('[VOIP] Failed to remove member state event', e, s);
      // Don't rethrow as this shouldn't prevent leaving the call
    }
  }

  /// Clean up stale membership events from room state
  Future<void> _cleanupStaleMembershipEvents() async {
    try {
      Logs().v(
        '[VOIP] Cleaning up stale membership events for call $groupCallId',
      );

      // Get all membership events in the room
      final allMemberships = room
          .getCallMembershipsFromRoom(voip)
          .values
          .expand((element) => element)
          .toList();

      // Find memberships that are expired or from different calls
      final staleMemberships = allMemberships.where((membership) {
        final isExpired = membership.isExpired;
        final isDifferentCall = membership.callId != groupCallId;
        final isDifferentRoom = membership.roomId != room.id;

        return isExpired || isDifferentCall || isDifferentRoom;
      }).toList();

      if (staleMemberships.isNotEmpty) {
        Logs().v(
          '[VOIP] Found ${staleMemberships.length} stale memberships to clean up',
        );

        // Group by user to clean up their membership events
        final staleByUser = <String, List<CallMembership>>{};
        for (final membership in staleMemberships) {
          final key = '${membership.userId}:${membership.deviceId}';
          staleByUser.putIfAbsent(key, () => []).add(membership);
        }

        // Clean up each user's stale memberships
        for (final entry in staleByUser.entries) {
          final userId = entry.key.split(':')[0];
          final deviceId = entry.key.split(':')[1];
          final staleMembershipsForUser = entry.value;

          Logs().v(
            '[VOIP] Cleaning up ${staleMembershipsForUser.length} stale memberships for $userId:$deviceId',
          );

          // This would require implementing a method to clean up specific memberships
          // For now, we'll just log the stale memberships
          for (final membership in staleMembershipsForUser) {
            Logs().v(
              '[VOIP] Stale membership: ${membership.userId}:${membership.deviceId} (callId: ${membership.callId}, expired: ${membership.isExpired})',
            );
          }
        }
      }
    } catch (e, s) {
      Logs().e('[VOIP] Failed to cleanup stale membership events', e, s);
    }
  }

  /// completely rebuilds the local _participants list
  Future<void> onMemberStateChanged() async {
    try {
      // Ensure room is fully loaded before processing member state changes
      await room.postLoad();

      // Add a small delay to ensure all events are processed
      await Future.delayed(Duration(milliseconds: 50));

      // The member events may be received for another room, which we will ignore.
      final mems = room
          .getCallMembershipsFromRoom(voip)
          .values
          .expand((element) => element);

      Logs().v(
        '[VOIP] All memberships found: ${mems.map((m) => '${m.userId}:${m.deviceId} (callId: ${m.callId}, expired: ${m.isExpired})').toList()}',
      );

      final memsForCurrentGroupCall = mems.where((element) {
        // Strict validation: all conditions must match exactly
        final callIdMatches = element.callId == groupCallId;
        final notExpired = !element.isExpired;
        final appMatches = element.application == application;
        final scopeMatches = element.scope == scope;
        final roomMatches = element.roomId == room.id;

        final matches = callIdMatches &&
            notExpired &&
            appMatches &&
            scopeMatches &&
            roomMatches;

        Logs().v(
          '[VOIP] Membership check: ${element.userId}:${element.deviceId} - callId: ${element.callId} (expected: $groupCallId), expired: ${element.isExpired}, app: ${element.application} (expected: $application), scope: ${element.scope} (expected: $scope), roomId: ${element.roomId} (expected: ${room.id}), matches: $matches',
        );

        if (!matches) {
          String reason = '';
          if (!callIdMatches) reason += 'callId mismatch; ';
          if (!notExpired) reason += 'expired; ';
          if (!appMatches) reason += 'app mismatch; ';
          if (!scopeMatches) reason += 'scope mismatch; ';
          if (!roomMatches) reason += 'room mismatch; ';

          Logs().v(
            '[VOIP] Membership filtered out: ${element.userId}:${element.deviceId} (${reason.trim()})',
          );
        }

        return matches;
      }).toList();

      Logs().v(
        '[VOIP] Memberships for current group call: ${memsForCurrentGroupCall.map((m) => '${m.userId}:${m.deviceId}').toList()}',
      );

      // Debug: Check current participants
      Logs().v(
        '[VOIP] Current participants: ${_participants.map((p) => p.id).toList()}',
      );

      final Set<CallParticipant> newP = {};

      // Always include the local participant if it exists
      if (localParticipant != null) {
        newP.add(localParticipant!);
        Logs().v(
          '[VOIP] Added local participant: ${localParticipant!.id}',
        );
      }

      for (final mem in memsForCurrentGroupCall) {
        final rp = CallParticipant(
          voip,
          userId: mem.userId,
          deviceId: mem.deviceId,
        );

        Logs().v(
          '[VOIP] Processing member: userId=${mem.userId}, deviceId=${mem.deviceId}, participantId=${rp.id}, isLocal=${rp.isLocal}',
        );

        // Always add the participant to the set
        newP.add(rp);

        // Skip local participant setup as it's handled in enter()
        if (rp.isLocal) continue;

        if (state != GroupCallState.entered) continue;

        try {
          await backend.setupP2PCallWithNewMember(this, rp, mem);
        } catch (e, s) {
          Logs().e(
            '[VOIP] Failed to setup P2P call with new member ${rp.id}',
            e,
            s,
          );
          // Continue with other members even if one fails
        }
      }
      final newPcopy = Set<CallParticipant>.from(newP);
      final oldPcopy = Set<CallParticipant>.from(_participants);
      final anyJoined = newPcopy.difference(oldPcopy);
      final anyLeft = oldPcopy.difference(newPcopy);

      Logs().v(
        '[VOIP] Participant comparison: oldParticipants=${oldPcopy.map((p) => p.id).toList()}, newParticipants=${newPcopy.map((p) => p.id).toList()}',
      );
      Logs().v(
        '[VOIP] Group call state: $state, Group call ID: $groupCallId',
      );

      if (anyJoined.isNotEmpty || anyLeft.isNotEmpty) {
        Logs().v(
          '[VOIP] Participant changes detected: anyJoined=${anyJoined.map((e) => e.id).toList()}, anyLeft=${anyLeft.map((e) => e.id).toList()}',
        );

        if (anyJoined.isNotEmpty) {
          final nonLocalAnyJoined = Set<CallParticipant>.from(anyJoined)
            ..remove(localParticipant);
          if (nonLocalAnyJoined.isNotEmpty && state == GroupCallState.entered) {
            Logs().v(
              'nonLocalAnyJoined: ${nonLocalAnyJoined.map((e) => e.id).toString()} roomId: ${room.id} groupCallId: $groupCallId',
            );
            try {
              // Process new participants sequentially to avoid race conditions
              for (final participant in nonLocalAnyJoined) {
                try {
                  // Check if we already have a call for this participant
                  final existingCall =
                      backend.getCallForParticipant(this, participant);
                  if (existingCall != null) {
                    Logs().v(
                      '[VOIP] Skipping P2P setup for ${participant.id} - call already exists: ${existingCall.callId}',
                    );
                    continue;
                  }

                  await backend.setupP2PCallWithNewMember(
                    this,
                    participant,
                    memsForCurrentGroupCall.firstWhere(
                      (m) =>
                          m.userId == participant.userId &&
                          m.deviceId == participant.deviceId,
                    ),
                  );
                } catch (e, s) {
                  Logs().e(
                    '[VOIP] Failed to setup P2P call with new participant ${participant.id}',
                    e,
                    s,
                  );
                  // Continue with other participants
                }
              }
              await backend.onNewParticipant(this, nonLocalAnyJoined.toList());
            } catch (e, s) {
              Logs().e('[VOIP] Failed to handle new participant', e, s);
            }
          }
          _participants.addAll(anyJoined);
          matrixRTCEventStream
              .add(ParticipantsJoinEvent(participants: anyJoined.toList()));
        }
        if (anyLeft.isNotEmpty) {
          // Filter out participants that might be false positives
          // (e.g., due to timing issues with room state event processing)
          final confirmedLeft = <CallParticipant>[];
          for (final participant in anyLeft) {
            // Check if this participant is actually still in the room memberships
            final stillInMemberships = memsForCurrentGroupCall.any(
              (mem) =>
                  mem.userId == participant.userId &&
                  mem.deviceId == participant.deviceId,
            );

            if (!stillInMemberships) {
              // Add additional delay to prevent false positives
              await Future.delayed(Duration(milliseconds: 100));

              // Double-check after delay
              final doubleCheckMemberships = room
                  .getCallMembershipsFromRoom(voip)
                  .values
                  .expand((element) => element)
                  .where((element) {
                return element.callId == groupCallId &&
                    !element.isExpired &&
                    element.application == application &&
                    element.scope == scope &&
                    element.roomId == room.id;
              }).any(
                (mem) =>
                    mem.userId == participant.userId &&
                    mem.deviceId == participant.deviceId,
              );

              if (!doubleCheckMemberships) {
                confirmedLeft.add(participant);
                Logs()
                    .v('[VOIP] Confirmed participant left: ${participant.id}');
              } else {
                Logs().v(
                  '[VOIP] False positive left detection for: ${participant.id} - still in memberships after double check',
                );
              }
            } else {
              Logs().v(
                '[VOIP] False positive left detection for: ${participant.id} - still in memberships',
              );
            }
          }

          if (confirmedLeft.isNotEmpty) {
            final nonLocalAnyLeft = Set<CallParticipant>.from(confirmedLeft)
              ..remove(localParticipant);
            if (nonLocalAnyLeft.isNotEmpty && state == GroupCallState.entered) {
              Logs().v(
                'nonLocalAnyLeft: ${nonLocalAnyLeft.map((e) => e.id).toString()} roomId: ${room.id} groupCallId: $groupCallId',
              );
              try {
                await backend.onLeftParticipant(this, nonLocalAnyLeft.toList());
              } catch (e, s) {
                Logs().e('[VOIP] Failed to handle left participant', e, s);
              }
            }
            _participants.removeAll(confirmedLeft);
            matrixRTCEventStream
                .add(ParticipantsLeftEvent(participants: confirmedLeft));

            // Check if we should automatically leave the group call
            // If only the local participant remains, leave the call
            final remainingParticipants =
                _participants.where((p) => !p.isLocal).toList();
            if (remainingParticipants.isEmpty &&
                state == GroupCallState.entered) {
              Logs().v(
                '[VOIP] All other participants have left, automatically leaving group call',
              );
              try {
                await leave();
              } catch (e, s) {
                Logs()
                    .e('[VOIP] Failed to automatically leave group call', e, s);
              }
            }
          }
        }

        // ignore: deprecated_member_use_from_same_package
        onGroupCallEvent.add(GroupCallStateChange.participantsChanged);
      }
    } catch (e, s) {
      Logs().e('[VOIP] Failed to process member state changes', e, s);
      rethrow;
    }
  }

  /// Send a reaction event to the group call
  ///
  /// [emoji] - The reaction emoji (e.g., '🖐️' for hand raise)
  /// [name] - The reaction name (e.g., 'hand raise')
  /// [isEphemeral] - Whether the reaction is ephemeral (default: true)
  ///
  /// Returns the event ID of the sent reaction event
  Future<String> sendReactionEvent({
    required String emoji,
    bool isEphemeral = true,
  }) async {
    if (isEphemeral && _reactionsTicker > 10) {
      throw Exception(
        '[sendReactionEvent] manual throttling, too many ephemral reactions sent',
      );
    }

    Logs().d('Group call reaction selected: $emoji');

    final memberships =
        room.getCallMembershipsForUser(client.userID!, client.deviceID!, voip);
    final membership = memberships.firstWhereOrNull(
      (m) =>
          m.callId == groupCallId &&
          m.deviceId == client.deviceID! &&
          m.roomId == room.id &&
          m.application == application &&
          m.scope == scope,
    );

    if (membership == null) {
      throw Exception(
        '[sendReactionEvent] No matching membership found to send group call emoji reaction from ${client.userID!}',
      );
    }

    final payload = ReactionPayload(
      key: emoji,
      isEphemeral: isEphemeral,
      callId: groupCallId,
      deviceId: client.deviceID!,
      relType: RelationshipTypes.reference,
      eventId: membership.eventId!,
    );

    // Send reaction as unencrypted event to avoid decryption issues
    final txid = client.generateUniqueTransactionId();
    _reactionsTicker++;
    return await client.sendMessage(
      room.id,
      EventTypes.GroupCallMemberReaction,
      txid,
      payload.toJson(),
    );
  }

  /// Remove a reaction event from the group call
  ///
  /// [eventId] - The event ID of the reaction to remove
  ///
  /// Returns the event ID of the removed reaction event
  Future<String?> removeReactionEvent({required String eventId}) async {
    return await client.redactEventWithMetadata(
      room.id,
      eventId,
      client.generateUniqueTransactionId(),
      metadata: {
        'device_id': client.deviceID,
        'call_id': groupCallId,
        'redacts_type': EventTypes.GroupCallMemberReaction,
      },
    );
  }

  /// Get all reactions of a specific type for all participants in the call
  ///
  /// [emoji] - The reaction emoji to filter by (e.g., '🖐️')
  ///
  /// Returns a list of [MatrixEvent] objects representing the reactions
  Future<List<MatrixEvent>> getAllReactions({required String emoji}) async {
    final reactions = <MatrixEvent>[];

    final memberships = room
        .getCallMembershipsFromRoom(
          voip,
        )
        .values
        .expand((e) => e);

    final membershipsForCurrentGroupCall = memberships
        .where(
          (m) =>
              m.callId == groupCallId &&
              m.application == application &&
              m.scope == scope &&
              m.roomId == room.id,
        )
        .toList();

    for (final membership in membershipsForCurrentGroupCall) {
      if (membership.eventId == null) continue;

      // this could cause a problem in large calls because it would make
      // n number of /relations requests where n is the number of participants
      // but turns our synapse does not rate limit these so should be fine?
      final eventsToProcess =
          (await client.getRelatingEventsWithRelTypeAndEventType(
        room.id,
        membership.eventId!,
        RelationshipTypes.reference,
        EventTypes.GroupCallMemberReaction,
        recurse: false,
        limit: 100,
      ))
              .chunk;

      reactions.addAll(
        eventsToProcess.where((event) => event.content['key'] == emoji),
      );
    }

    return reactions;
  }

  /// Get all permanent reactions for a specific member event ID
  ///
  /// [eventId] - The member event ID to get reactions for
  ///
  /// Returns a list of [MatrixEvent] objects representing permanent reactions
  Future<List<MatrixEvent>> _getPermanentReactionsForEvent(
    String eventId,
  ) async {
    final permanentReactions = <MatrixEvent>[];

    try {
      final events = await client.getRelatingEventsWithRelTypeAndEventType(
        room.id,
        eventId,
        RelationshipTypes.reference,
        EventTypes.GroupCallMemberReaction,
        recurse: false,
        // makes sure that if you make too many reactions, permanent reactions don't miss out
        // hopefully 100 is a good value
        limit: 100,
      );

      for (final event in events.chunk) {
        final content = event.content;
        final isEphemeral = content['is_ephemeral'] as bool? ?? false;
        final isRedacted = event.redacts != null;

        if (!isEphemeral && !isRedacted) {
          permanentReactions.add(event);
          Logs().d(
            '[VOIP] Found permanent reaction to preserve: ${content['key']} from ${event.senderId}',
          );
        }
      }
    } catch (e, s) {
      Logs().e(
        '[VOIP] Failed to get permanent reactions for event $eventId',
        e,
        s,
      );
    }

    return permanentReactions;
  }

  /// Copy permanent reactions to the new member event
  ///
  /// [permanentReactions] - List of permanent reaction events to copy
  /// [newEventId] - The event ID of the new membership event
  Future<void> _copyPermanentReactionsToNewEvent(
    List<MatrixEvent> permanentReactions,
    String newEventId,
  ) async {
    // Re-send each permanent reaction with the new event ID
    for (final reactionEvent in permanentReactions) {
      try {
        final content = reactionEvent.content;
        final reactionKey = content['key'] as String?;

        if (reactionKey == null) {
          Logs().w(
            '[VOIP] Skipping permanent reaction copy: missing reaction key',
          );
          continue;
        }

        // Build new reaction event with updated event ID
        final payload = ReactionPayload(
          key: reactionKey,
          isEphemeral: false,
          callId: groupCallId,
          deviceId: client.deviceID!,
          relType: RelationshipTypes.reference,
          eventId: newEventId,
        );

        // Send the permanent reaction with new event ID
        final txid = client.generateUniqueTransactionId();
        await client.sendMessage(
          room.id,
          EventTypes.GroupCallMemberReaction,
          txid,
          payload.toJson(),
        );

        Logs().d(
          '[VOIP] Copied permanent reaction $reactionKey to new member event $newEventId',
        );
      } catch (e, s) {
        Logs().e(
          '[VOIP] Failed to copy permanent reaction',
          e,
          s,
        );
      }
    }
  }
}
