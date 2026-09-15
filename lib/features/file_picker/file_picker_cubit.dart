import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'package:saf/saf.dart';
import 'file_picker_state.dart';
import '../transfer/transfer_cubit.dart';

class FilePickerCubit extends Cubit<FilePickerState> {
  final TransferCubit _transferCubit;

  FilePickerCubit(this._transferCubit) : super(const FilePickerState());

  Future<void> pickFiles() async {
    emit(state.copyWith(status: FilePickerStatus.picking));
    try {
      final pickedFiles = await _pickFromPlatform();

      if (pickedFiles.isEmpty) {
        emit(state.copyWith(status: FilePickerStatus.picked));
        return;
      }

      // Merge into anything already selected so "Add more files" never drops
      // the user's existing selection.
      final existing = <String>{
        for (final f in state.files) f.path,
      };
      final merged = List<PickedFile>.from(state.files);
      for (final file in pickedFiles) {
        if (existing.contains(file.path)) continue;
        existing.add(file.path);
        merged.add(file);
      }

      emit(state.copyWith(
        status: FilePickerStatus.picked,
        files: merged,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: FilePickerStatus.error,
        errorMessage: 'Failed to pick files: $e',
      ));
    }
  }

  /// Returns the picked files without copying them.
  ///
  /// On Android this uses the Storage Access Framework directly, which hands
  /// back `content://` URIs plus instant metadata. `file_picker` on Android
  /// instead copies the whole file into the app cache before returning, so
  /// multi-gigabyte picks are blocked for tens of seconds — SAF avoids that
  /// while still letting us stream the file during transfer.
  Future<List<PickedFile>> _pickFromPlatform() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        final docs = await Saf().pickFiles(persistablePermission: true);
        return docs.map((d) => PickedFile(
              path: d.uri,
              name: d.name,
              size: d.length,
              mimeType: d.mimeType,
            )).toList();
      } catch (_) {
        // Fall through to file_picker if SAF is unavailable.
      }
    }

    final result = await fp.FilePicker.platform.pickFiles(
      allowMultiple: true,
      type: fp.FileType.any,
    );
    if (result == null) return const [];

    return [
      for (final file in result.files)
        if ((file.path ?? '').isNotEmpty)
          PickedFile(
            path: file.path!,
            name: file.name,
            size: file.size,
          ),
    ];
  }

  Future<void> pickFilesFromPath(List<String> paths) async {
    final pickedFiles = List<PickedFile>.from(state.files);
    final known = <String>{for (final f in pickedFiles) f.path};
    for (final path in paths) {
      if (known.contains(path)) continue;
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
        known.add(path);
        pickedFiles.add(PickedFile(
          path: path,
          name: path.split(Platform.pathSeparator).last,
          size: stat.size,
        ));
      }
    }
    emit(state.copyWith(
      status: FilePickerStatus.picked,
      files: pickedFiles,
    ));
  }

  void removeFile(int index) {
    final files = List<PickedFile>.from(state.files);
    files.removeAt(index);
    if (files.isEmpty) {
      emit(state.copyWith(status: FilePickerStatus.initial, files: []));
    } else {
      emit(state.copyWith(files: files));
    }
  }

  void clearFiles() {
    emit(const FilePickerState());
  }

  void startTransfer() {
    if (state.files.isEmpty) return;
    _transferCubit.startTransfer(state.files);
  }
}
