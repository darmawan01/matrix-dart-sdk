import 'package:matrix/matrix.dart';
import 'package:matrix/src/utils/client_init_exception.dart';
import 'package:test/test.dart';

import 'fake_client.dart';
import 'fake_database.dart';

void main() {
  for (final preserve in [true, false]) {
    test('init failure ${preserve ? 'preserves' : 'clears'} stored session',
        () async {
      final database = await getDatabase();
      await database.insertClient(
        'init-failure', 'https://example.org', 'stored-token', null, null,
        '@user:example.org', 'DEVICE', 'phone', 'stored-batch', null,
      );
      final client = preserve
          ? Client('init-failure', database: database,
              httpClient: FakeMatrixApi(), clearOnInitFailure: false)
          : Client('init-failure', database: database,
              httpClient: FakeMatrixApi());
      final errors = <Object>[];
      final states = <InitState>[];
      final loginStates = <LoginState>[];
      final subscription = client.onLoginStateChanged.stream.listen(
        loginStates.add, onError: (Object error) => errors.add(error),
      );
      final failure = StateError('simulated init failure');
      await expectLater(client.init(
        waitForFirstSync: false,
        onInitStateChanged: (state) {
          states.add(state);
          if (state == InitState.settingUpEncryption) throw failure;
        },
      ), throwsA(isA<ClientInitException>()));
      final row = await database.getClient('init-failure');
      if (preserve) {
        expect(row?['token'], 'stored-token');
        expect(row?['user_id'], '@user:example.org');
        expect(row?['prev_batch'], 'stored-batch');
        expect(loginStates, isNot(contains(LoginState.loggedOut)));
      } else {
        expect(row, isNull);
      }
      expect(states.last, InitState.error);
      expect(errors, contains(failure));
      await subscription.cancel();
      await client.dispose();
    });
  }
}
