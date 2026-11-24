import 'dart:io';

import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_database.dart';

void main() {
  group('reloadPrevBatch', () {
    Logs().level = Level.error;
    late Directory dir;
    late MatrixSdkDatabase writer;
    late MatrixSdkDatabase reader;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('prev_batch_test');
      final path = '${dir.path}/shared.sqlite';
      writer = await getMatrixSdkDatabase(path: path);
      await writer.insertClient(
        'testclient',
        'https://example.org',
        'token',
        null,
        null,
        '@test:example.org',
        'DEVICE',
        null,
        null,
        null,
      );
      await writer.storePrevBatch('s1');
      reader = await getMatrixSdkDatabase(path: path);
    });

    tearDown(() async {
      await writer.close();
      await reader.close();
      await dir.delete(recursive: true);
    });

    test('getStoredPrevBatch sees a position written by another instance',
        () async {
      // Warm the reader's cache with the old position.
      expect((await reader.getClient('testclient'))?['prev_batch'], 's1');

      await writer.storePrevBatch('s2');

      // The cached read still returns the old one; that is the bug.
      expect((await reader.getClient('testclient'))?['prev_batch'], 's1');
      expect(await reader.getStoredPrevBatch(), 's2');
    });

    test('Client.reloadPrevBatch picks up the stored position', () async {
      await writer.storePrevBatch('s3');
      final client = Client('testclient', database: reader);

      final result = await client.reloadPrevBatch();

      expect(result.before, isNull);
      expect(result.after, 's3');
      expect(client.prevBatch, 's3');
    });
  });
}
