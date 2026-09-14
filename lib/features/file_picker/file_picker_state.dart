class PickedFile {
  final String path;
  final String name;
  final int size;
  final String? mimeType;

  const PickedFile({
    required this.path,
    required this.name,
    required this.size,
    this.mimeType,
  });
}

enum FilePickerStatus {
  initial,
  picking,
  picked,
  error,
}

class FilePickerState {
  final FilePickerStatus status;
  final List<PickedFile> files;
  final String? errorMessage;

  const FilePickerState({
    this.status = FilePickerStatus.initial,
    this.files = const [],
    this.errorMessage,
  });

  int get totalSize => files.fold(0, (sum, f) => sum + f.size);

  FilePickerState copyWith({
    FilePickerStatus? status,
    List<PickedFile>? files,
    String? errorMessage,
    bool clearError = false,
  }) {
    return FilePickerState(
      status: status ?? this.status,
      files: files ?? this.files,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}
