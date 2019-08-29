/*
 * Copyright (c) 2019 Zender & Kurtz GbR.
 *
 * Authors:
 *   Christian Pauly <krille@famedly.com>
 *   Marcel Radzio <mtrnord@famedly.com>
 *
 * This file is part of famedlysdk.
 *
 * famedlysdk is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * famedlysdk is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with famedlysdk.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'package:famedlysdk/src/Client.dart';
import 'package:famedlysdk/src/Event.dart';
import 'package:famedlysdk/src/RoomAccountData.dart';
import 'package:famedlysdk/src/RoomState.dart';
import 'package:famedlysdk/src/responses/ErrorResponse.dart';
import 'package:famedlysdk/src/sync/EventUpdate.dart';
import 'package:famedlysdk/src/utils/ChatTime.dart';
import 'package:famedlysdk/src/utils/MxContent.dart';

import './User.dart';
import 'Connection.dart';
import 'Timeline.dart';

/// Represents a Matrix room.
class Room {
  /// The full qualified Matrix ID for the room in the format '!localid:server.abc'.
  final String id;

  /// Membership status of the user for this room.
  Membership membership;

  /// The count of unread notifications.
  int notificationCount;

  /// The count of highlighted notifications.
  int highlightCount;

  String prev_batch;

  List<String> mHeroes = [];
  int mJoinedMemberCount;
  int mInvitedMemberCount;

  Map<String, RoomState> states = {};

  Map<String, RoomAccountData> roomAccountData = {};

  /// Time when the user has last read the chat.
  ChatTime unread;

  /// ID of the fully read marker event.
  String fullyRead;

  /// The name of the room if set by a participant.
  String get name {
    if (states["m.room.name"] != null &&
        !states["m.room.name"].content["name"].isEmpty)
      return states["m.room.name"].content["name"];
    if (canonicalAlias != null && !canonicalAlias.isEmpty)
      return canonicalAlias.substring(1, canonicalAlias.length).split(":")[0];
    if (mHeroes != null && mHeroes.length > 0) {
      String displayname = "";
      for (int i = 0; i < mHeroes.length; i++) {
        User hero = states[mHeroes[i]] != null
            ? states[mHeroes[i]].asUser
            : User(mHeroes[i]);
        displayname += hero.calcDisplayname() + ", ";
      }
      return displayname.substring(0, displayname.length - 2);
    }
    return "Empty chat";
  }

  /// The topic of the room if set by a participant.
  String get topic => states["m.room.topic"] != null
      ? states["m.room.topic"].content["topic"]
      : "";

  /// The avatar of the room if set by a participant.
  MxContent get avatar {
    if (states["m.room.avatar"] != null)
      return MxContent(states["m.room.avatar"].content["url"]);
    if (mHeroes != null && mHeroes.length == 1 && states[mHeroes[0]] != null)
      return states[mHeroes[0]].asUser.avatarUrl;
    return MxContent("");
  }

  /// The address in the format: #roomname:homeserver.org.
  String get canonicalAlias => states["m.room.canonical_alias"] != null
      ? states["m.room.canonical_alias"].content["alias"]
      : "";

  /// If this room is a direct chat, this is the matrix ID of the user.
  /// Returns null otherwise.
  String get directChatMatrixID {
    String returnUserId = null;
    if (client.directChats is Map<String, dynamic>) {
      client.directChats.forEach((String userId, dynamic roomIds) {
        if (roomIds is List<dynamic>) {
          for (int i = 0; i < roomIds.length; i++)
            if (roomIds[i] == this.id) {
              returnUserId = userId;
              break;
            }
        }
      });
    }
    return returnUserId;
  }

  /// Must be one of [all, mention]
  String notificationSettings;

  Event get lastEvent {
    ChatTime lastTime = ChatTime(0);
    Event lastEvent = null;
    states.forEach((String key, RoomState value) {
      if (value.time > lastTime) lastEvent = value.timelineEvent;
    });
    return lastEvent;
  }

  /// Your current client instance.
  final Client client;

  Room({
    this.id,
    this.membership = Membership.join,
    this.notificationCount = 0,
    this.highlightCount = 0,
    this.prev_batch = "",
    this.client,
    this.notificationSettings,
    this.mHeroes = const [],
    this.mInvitedMemberCount = 0,
    this.mJoinedMemberCount = 0,
    this.states = const {},
    this.roomAccountData = const {},
  });

  /// Calculates the displayname. First checks if there is a name, then checks for a canonical alias and
  /// then generates a name from the heroes.
  String get displayname {
    if (name != null && !name.isEmpty) return name;
    if (canonicalAlias != null &&
        !canonicalAlias.isEmpty &&
        canonicalAlias.length > 3)
      return canonicalAlias.substring(1, canonicalAlias.length).split(":")[0];
    if (mHeroes.length > 0) {
      String displayname = "";
      for (int i = 0; i < mHeroes.length; i++)
        displayname += User(mHeroes[i]).calcDisplayname() + ", ";
      return displayname.substring(0, displayname.length - 2);
    }
    return "Empty chat";
  }

  /// The last message sent to this room.
  String get lastMessage {
    if (lastEvent != null)
      return lastEvent.getBody();
    else
      return "";
  }

  /// When the last message received.
  ChatTime get timeCreated {
    if (lastEvent != null)
      return lastEvent.time;
    else
      return ChatTime.now();
  }

  /// Call the Matrix API to change the name of this room.
  Future<dynamic> setName(String newName) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.PUT,
        action: "/client/r0/rooms/${id}/state/m.room.name",
        data: {"name": newName});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to change the topic of this room.
  Future<dynamic> setDescription(String newName) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.PUT,
        action: "/client/r0/rooms/${id}/state/m.room.topic",
        data: {"topic": newName});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to send a simple text message.
  Future<dynamic> sendText(String message, {String txid = null}) async {
    if (txid == null) txid = "txid${DateTime.now().millisecondsSinceEpoch}";
    final dynamic res = await client.connection.jsonRequest(
        type: HTTPType.PUT,
        action: "/client/r0/rooms/${id}/send/m.room.message/$txid",
        data: {"msgtype": "m.text", "body": message});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  Future<String> sendTextEvent(String message, {String txid = null}) async {
    final String type = "m.room.message";

    // Create new transaction id
    String messageID;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (txid == null) {
      messageID = "msg$now";
    } else
      messageID = txid;

    // Display a *sending* event and store it.
    EventUpdate eventUpdate =
        EventUpdate(type: "timeline", roomID: id, eventType: type, content: {
      "type": type,
      "event_id": messageID,
      "sender": client.userID,
      "status": 0,
      "origin_server_ts": now,
      "content": {
        "msgtype": "m.text",
        "body": message,
      }
    });
    client.connection.onEvent.add(eventUpdate);
    await client.store?.transaction(() {
      client.store.storeEventUpdate(eventUpdate);
      return;
    });

    // Send the text and on success, store and display a *sent* event.
    final dynamic res = await sendText(message, txid: messageID);

    if (res is ErrorResponse || !(res["event_id"] is String)) {
      // On error, set status to -1
      eventUpdate.content["status"] = -1;
      eventUpdate.content["unsigned"] = {"transaction_id": messageID};
      client.connection.onEvent.add(eventUpdate);
      await client.store?.transaction(() {
        client.store.storeEventUpdate(eventUpdate);
        return;
      });
    } else {
      eventUpdate.content["status"] = 1;
      eventUpdate.content["unsigned"] = {"transaction_id": messageID};
      eventUpdate.content["event_id"] = res["event_id"];
      client.connection.onEvent.add(eventUpdate);
      await client.store?.transaction(() {
        client.store.storeEventUpdate(eventUpdate);
        return;
      });
      return res["event_id"];
    }
    return null;
  }

  /// Call the Matrix API to leave this room.
  Future<dynamic> leave() async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST, action: "/client/r0/rooms/${id}/leave");
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to forget this room if you already left it.
  Future<dynamic> forget() async {
    client.store.forgetRoom(id);
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST, action: "/client/r0/rooms/${id}/forget");
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to kick a user from this room.
  Future<dynamic> kick(String userID) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST,
        action: "/client/r0/rooms/${id}/kick",
        data: {"user_id": userID});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to ban a user from this room.
  Future<dynamic> ban(String userID) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST,
        action: "/client/r0/rooms/${id}/ban",
        data: {"user_id": userID});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to unban a banned user from this room.
  Future<dynamic> unban(String userID) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST,
        action: "/client/r0/rooms/${id}/unban",
        data: {"user_id": userID});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Set the power level of the user with the [userID] to the value [power].
  Future<dynamic> setPower(String userID, int power) async {
    if (states["m.room.power_levels"] == null) return null;
    Map<String, int> powerMap = states["m.room.power_levels"].content["users"];
    powerMap[userID] = power;

    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.PUT,
        action: "/client/r0/rooms/$id/state/m.room.power_levels",
        data: {"users": powerMap});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Call the Matrix API to invite a user to this room.
  Future<dynamic> invite(String userID) async {
    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.POST,
        action: "/client/r0/rooms/${id}/invite",
        data: {"user_id": userID});
    if (res is ErrorResponse) client.connection.onError.add(res);
    return res;
  }

  /// Request more previous events from the server.
  Future<void> requestHistory({int historyCount = 100}) async {
    final dynamic resp = await client.connection.jsonRequest(
        type: HTTPType.GET,
        action:
            "/client/r0/rooms/$id/messages?from=${prev_batch}&dir=b&limit=$historyCount");

    if (resp is ErrorResponse) return;

    prev_batch = resp["end"];
    client.store?.storeRoomPrevBatch(this);

    if (!(resp["chunk"] is List<dynamic> &&
        resp["chunk"].length > 0 &&
        resp["end"] is String)) return;

    List<dynamic> history = resp["chunk"];
    client.store?.transaction(() {
      for (int i = 0; i < history.length; i++) {
        EventUpdate eventUpdate = EventUpdate(
          type: "history",
          roomID: id,
          eventType: history[i]["type"],
          content: history[i],
        );
        client.connection.onEvent.add(eventUpdate);
        client.store.storeEventUpdate(eventUpdate);
        client.store.txn.rawUpdate(
            "UPDATE Rooms SET prev_batch=? WHERE room_id=?", [resp["end"], id]);
      }
      return;
    });
    if (client.store == null) {
      for (int i = 0; i < history.length; i++) {
        EventUpdate eventUpdate = EventUpdate(
          type: "history",
          roomID: id,
          eventType: history[i]["type"],
          content: history[i],
        );
        client.connection.onEvent.add(eventUpdate);
      }
    }
  }

  /// Sets this room as a direct chat for this user.
  Future<dynamic> addToDirectChat(String userID) async {
    Map<String, dynamic> directChats = client.directChats;
    if (directChats.containsKey(userID)) if (!directChats[userID].contains(id))
      directChats[userID].add(id);
    else
      return null; // Is already in direct chats
    else
      directChats[userID] = [id];

    final resp = await client.connection.jsonRequest(
        type: HTTPType.PUT,
        action: "/client/r0/user/${client.userID}/account_data/m.direct",
        data: directChats);
    return resp;
  }

  /// Sends *m.fully_read* and *m.read* for the given event ID.
  Future<dynamic> sendReadReceipt(String eventID) async {
    final dynamic resp = client.connection.jsonRequest(
        type: HTTPType.POST,
        action: "/client/r0/rooms/$id/read_markers",
        data: {
          "m.fully_read": eventID,
          "m.read": eventID,
        });
    return resp;
  }

  /// Returns a Room from a json String which comes normally from the store. If the
  /// state are also given, the method will await them.
  static Future<Room> getRoomFromTableRow(
      Map<String, dynamic> row, Client matrix,
      {Future<List<Map<String, dynamic>>> states,
      Future<List<Map<String, dynamic>>> roomAccountData}) async {
    Room newRoom = Room(
      id: row["room_id"],
      membership: Membership.values
          .firstWhere((e) => e.toString() == 'Membership.' + row["membership"]),
      notificationCount: row["notification_count"],
      highlightCount: row["highlight_count"],
      notificationSettings: row["notification_settings"],
      prev_batch: row["prev_batch"],
      mInvitedMemberCount: row["invited_member_count"],
      mJoinedMemberCount: row["joined_member_count"],
      mHeroes: row["heroes"]?.split(",") ?? [],
      client: matrix,
      states: {},
      roomAccountData: {},
    );

    Map<String, RoomState> newStates = {};
    if (states != null) {
      List<Map<String, dynamic>> rawStates = await states;
      for (int i = 0; i < rawStates.length; i++) {
        RoomState newState = RoomState.fromJson(rawStates[i], newRoom);
        newStates[newState.key] = newState;
      }
      newRoom.states = newStates;
    }

    Map<String, RoomAccountData> newRoomAccountData = {};
    if (roomAccountData != null) {
      List<Map<String, dynamic>> rawRoomAccountData = await roomAccountData;
      for (int i = 0; i < rawRoomAccountData.length; i++) {
        RoomAccountData newData =
            RoomAccountData.fromJson(rawRoomAccountData[i], newRoom);
        newRoomAccountData[newData.typeKey] = newData;
      }
      newRoom.roomAccountData = newRoomAccountData;
    }

    return newRoom;
  }

  /// Creates a timeline from the store. Returns a [Timeline] object.
  Future<Timeline> getTimeline(
      {onTimelineUpdateCallback onUpdate,
      onTimelineInsertCallback onInsert}) async {
    List<Event> events = await loadEvents();
    return Timeline(
      room: this,
      events: events,
      onUpdate: onUpdate,
      onInsert: onInsert,
    );
  }

  /// Load all events for a given room from the store. This includes all
  /// senders of those events, who will be added to the participants list.
  Future<List<Event>> loadEvents() async {
    if (client.store != null) return await client.store.getEventList(this);
    return [];
  }

  /// Load all participants for a given room from the store.
  @deprecated
  Future<List<User>> loadParticipants() async {
    return await client.store.loadParticipants(this);
  }

  /// Request the full list of participants from the server. The local list
  /// from the store is not complete if the client uses lazy loading.
  Future<List<User>> requestParticipants() async {
    List<User> participants = [];

    dynamic res = await client.connection.jsonRequest(
        type: HTTPType.GET, action: "/client/r0/rooms/${id}/members");
    if (res is ErrorResponse || !(res["chunk"] is List<dynamic>))
      return participants;

    for (num i = 0; i < res["chunk"].length; i++) {
      User newUser = RoomState.fromJson(res["chunk"][i], this).asUser;
      if (newUser.membership != Membership.leave) participants.add(newUser);
    }

    return participants;
  }

  Future<User> getUserByMXID(String mxID) async {
    if (states[mxID] != null) return states[mxID].asUser;
    final dynamic resp = await client.connection.jsonRequest(
        type: HTTPType.GET,
        action: "/client/r0/rooms/$id/state/m.room.member/$mxID");
    if (resp is ErrorResponse) return null;
    // Somehow we miss the mxid in the response and only get the content of the event.
    resp["matrix_id"] = mxID;
    return RoomState.fromJson(resp, this).asUser;
  }

  /// Searches for the event in the store. If it isn't found, try to request it
  /// from the server. Returns null if not found.
  Future<Event> getEventById(String eventID) async {
    if (client.store != null) {
      final Event storeEvent = await client.store.getEventById(eventID, this);
      if (storeEvent != null) return storeEvent;
    }
    final dynamic resp = await client.connection.jsonRequest(
        type: HTTPType.GET, action: "/client/r0/rooms/$id/event/$eventID");
    if (resp is ErrorResponse) return null;
    return Event.fromJson(resp, this);
  }

  /// Returns the user's own power level.
  int getPowerLevelByUserId(String userId) {
    int powerLevel = 0;
    RoomState powerLevelState = states["m.room.power_levels"];
    if (powerLevelState == null) return powerLevel;
    if (powerLevelState.content["users_default"] is int)
      powerLevel = powerLevelState.content["users_default"];
    if (powerLevelState.content["users"] is Map<String, dynamic> &&
        powerLevelState.content["users"][userId] != null)
      powerLevel = powerLevelState.content["users"][userId];
    return powerLevel;
  }

  /// Returns the user's own power level.
  int get ownPowerLevel => getPowerLevelByUserId(client.userID);

  /// Returns the power levels from all users for this room or null if not given.
  Map<String, int> get powerLevels {
    RoomState powerLevelState = states["m.room.power_levels"];
    if (powerLevelState.content["users"] is Map<String, int>)
      return powerLevelState.content["users"];
    return null;
  }
}
