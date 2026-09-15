enum FileTransferStatus {
  pending,
  transferring,
  completed,
  failed,
  paused,
}

class TransferFileManifest {
  final String fileName;
  final String filePath;
  final int fileSize;
  final String? expectedHash;
  final FileTransferStatus status;
  final int chunksSent;
  final int totalChunks;
  final int lastAckedChunk;
  final String? actualHash;

  const TransferFileManifest({
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    this.expectedHash,
    this.status = FileTransferStatus.pending,
    this.chunksSent = 0,
    this.totalChunks = 0,
    this.lastAckedChunk = -1,
    this.actualHash,
  });

  double get progress => totalChunks > 0 ? chunksSent / totalChunks : 0;
  int get bytesTransferred => (fileSize * progress).round();

  TransferFileManifest copyWith({
    FileTransferStatus? status,
    int? chunksSent,
    int? totalChunks,
    int? lastAckedChunk,
    String? actualHash,
  }) {
    return TransferFileManifest(
      fileName: fileName,
      filePath: filePath,
      fileSize: fileSize,
      expectedHash: expectedHash,
      status: status ?? this.status,
      chunksSent: chunksSent ?? this.chunksSent,
      totalChunks: totalChunks ?? this.totalChunks,
      lastAckedChunk: lastAckedChunk ?? this.lastAckedChunk,
      actualHash: actualHash ?? this.actualHash,
    );
  }

  Map<String, dynamic> toJson() => {
    'fileName': fileName,
    'filePath': filePath,
    'fileSize': fileSize,
    'expectedHash': expectedHash,
    'status': status.index,
    'chunksSent': chunksSent,
    'totalChunks': totalChunks,
    'lastAckedChunk': lastAckedChunk,
    'actualHash': actualHash,
  };

  factory TransferFileManifest.fromJson(Map<String, dynamic> json) =>
      TransferFileManifest(
        fileName: json['fileName'],
        filePath: json['filePath'],
        fileSize: json['fileSize'],
        expectedHash: json['expectedHash'],
        status: FileTransferStatus.values[json['status'] ?? 0],
        chunksSent: json['chunksSent'] ?? 0,
        totalChunks: json['totalChunks'] ?? 0,
        lastAckedChunk: json['lastAckedChunk'] ?? -1,
        actualHash: json['actualHash'],
      );
}

enum SessionStatus {
  created,
  discovering,
  connecting,
  transferring,
  paused,
  completed,
  failed,
  resumed,
}

class TransferSession {
  final String id;
  final String? remoteDeviceName;
  final bool isSender;
  final SessionStatus status;
  final List<TransferFileManifest> files;
  final DateTime createdAt;
  final DateTime? completedAt;
  final bool isArchived;

  const TransferSession({
    required this.id,
    this.remoteDeviceName,
    required this.isSender,
    this.status = SessionStatus.created,
    this.files = const [],
    required this.createdAt,
    this.completedAt,
    this.isArchived = false,
  });

  int get totalBytes => files.fold(0, (sum, f) => sum + f.fileSize);
  int get transferredBytes =>
      files.fold(0, (sum, f) => sum + f.bytesTransferred);
  double get progress =>
      totalBytes > 0 ? transferredBytes / totalBytes : 0;

  bool get isCompleted =>
      files.every((f) => f.status == FileTransferStatus.completed);
  bool get hasFailed =>
      files.any((f) => f.status == FileTransferStatus.failed);

  TransferSession copyWith({
    String? remoteDeviceName,
    SessionStatus? status,
    List<TransferFileManifest>? files,
    DateTime? completedAt,
    bool? isArchived,
  }) {
    return TransferSession(
      id: id,
      remoteDeviceName: remoteDeviceName ?? this.remoteDeviceName,
      isSender: isSender,
      status: status ?? this.status,
      files: files ?? this.files,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      isArchived: isArchived ?? this.isArchived,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'remoteDeviceName': remoteDeviceName,
        'isSender': isSender,
        'status': status.index,
        'files': files.map((f) => f.toJson()).toList(),
        'createdAt': createdAt.toIso8601String(),
        'completedAt': completedAt?.toIso8601String(),
        'isArchived': isArchived,
      };

  factory TransferSession.fromJson(Map<String, dynamic> json) =>
      TransferSession(
        id: json['id'],
        remoteDeviceName: json['remoteDeviceName'],
        isSender: json['isSender'] ?? true,
        status: SessionStatus.values[json['status'] ?? 0],
        files: (json['files'] as List?)
                ?.map((f) => TransferFileManifest.fromJson(f))
                .toList() ??
            [],
        createdAt: DateTime.parse(json['createdAt']),
        completedAt: json['completedAt'] != null
            ? DateTime.parse(json['completedAt'])
            : null,
        isArchived: json['isArchived'] ?? false,
      );
}