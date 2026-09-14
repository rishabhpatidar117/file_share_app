import 'package:flutter_test/flutter_test.dart';
import 'package:swiftshare/features/transfer/session/transfer_session.dart';

void main() {
  group('TransferSession', () {
    test('JSON round-trip preserves all fields', () {
      final session = TransferSession(
        id: 'abc-123',
        remoteDeviceName: 'Pixel 8',
        isSender: true,
        status: SessionStatus.transferring,
        files: [
          TransferFileManifest(
            fileName: 'photo.jpg',
            filePath: '/tmp/photo.jpg',
            fileSize: 2048,
            status: FileTransferStatus.transferring,
            chunksSent: 2,
            totalChunks: 4,
            lastAckedChunk: 1,
          ),
          TransferFileManifest(
            fileName: 'doc.pdf',
            filePath: '/tmp/doc.pdf',
            fileSize: 5000,
            status: FileTransferStatus.pending,
            totalChunks: 10,
          ),
        ],
        createdAt: DateTime(2026, 1, 1, 12, 30),
        completedAt: null,
      );

      final restored = TransferSession.fromJson(session.toJson());
      expect(restored.id, session.id);
      expect(restored.remoteDeviceName, session.remoteDeviceName);
      expect(restored.isSender, session.isSender);
      expect(restored.status, session.status);
      expect(restored.files.length, 2);
      expect(restored.files[0].fileName, 'photo.jpg');
      expect(restored.files[0].chunksSent, 2);
      expect(restored.files[0].lastAckedChunk, 1);
      expect(restored.files[0].status, FileTransferStatus.transferring);
      expect(restored.files[1].fileName, 'doc.pdf');
      expect(restored.createdAt, DateTime(2026, 1, 1, 12, 30));
    });

    test('progress computed from file bytes', () {
      final session = TransferSession(
        id: '1',
        isSender: true,
        files: [
          TransferFileManifest(
            fileName: 'a.bin',
            filePath: '/a.bin',
            fileSize: 4000,
            totalChunks: 4,
            chunksSent: 4,
            status: FileTransferStatus.completed,
          ),
          TransferFileManifest(
            fileName: 'b.bin',
            filePath: '/b.bin',
            fileSize: 6000,
            totalChunks: 6,
            chunksSent: 3,
            status: FileTransferStatus.transferring,
          ),
        ],
        createdAt: DateTime.now(),
      );

      // 4000 + 3000 = 7000 of 10000
      expect(session.totalBytes, 10000);
      expect(session.transferredBytes, 7000);
      expect(session.progress, closeTo(0.7, 0.0001));
    });

    test('isCompleted true when all files completed', () {
      final session = TransferSession(
        id: '1',
        isSender: true,
        files: [
          TransferFileManifest(
            fileName: 'a',
            filePath: '/a',
            fileSize: 1,
            status: FileTransferStatus.completed,
          ),
          TransferFileManifest(
            fileName: 'b',
            filePath: '/b',
            fileSize: 1,
            status: FileTransferStatus.completed,
          ),
        ],
        createdAt: DateTime.now(),
      );
      expect(session.isCompleted, isTrue);
      expect(session.hasFailed, isFalse);
    });

    test('copyWith updates status without losing identity', () {
      final session = TransferSession(
        id: '1',
        isSender: true,
        files: const [],
        createdAt: DateTime.now(),
      );
      final updated = session.copyWith(
        status: SessionStatus.completed,
        completedAt: DateTime.now(),
        remoteDeviceName: 'Laptop',
      );
      expect(updated.id, '1');
      expect(updated.status, SessionStatus.completed);
      expect(updated.remoteDeviceName, 'Laptop');
      expect(updated.completedAt, isNotNull);
    });
  });

  group('TransferFileManifest', () {
    test('progress calculated from chunks', () {
      const manifest = TransferFileManifest(
        fileName: 'x',
        filePath: '/x',
        fileSize: 1000,
        chunksSent: 5,
        totalChunks: 10,
      );
      expect(manifest.progress, 0.5);
      expect(manifest.bytesTransferred, 500);
    });
  });
}