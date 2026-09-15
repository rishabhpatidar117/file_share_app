import 'dart:io';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:file_picker/file_picker.dart' as fp;
import 'file_picker_state.dart';
import '../transfer/transfer_cubit.dart';

class FilePickerCubit extends Cubit<FilePickerState> {
  final TransferCubit _transferCubit;

  FilePickerCubit(this._transferCubit) : super(const FilePickerState());

  Future<void> pickFiles() async {
    emit(state.copyWith(status: FilePickerStatus.picking));
    try {
      final result = await fp.FilePicker.platform.pickFiles(
        allowMultiple: true,
        type: fp.FileType.any,
      );

      if (result == null || result.files.isEmpty) {
        emit(state.copyWith(status: FilePickerStatus.picked));
        return;
      }

      // Merge into anything already selected so "Add more files" never drops
      // the user's existing selection.
      final existing = <String>{
        for (final f in state.files) f.path,
      };
      final pickedFiles = List<PickedFile>.from(state.files);
      for (final file in result.files) {
        final path = file.path ?? '';
        if (path.isEmpty || existing.contains(path)) continue;
        existing.add(path);
        pickedFiles.add(PickedFile(
          path: path,
          name: file.name,
          size: file.size,
        ));
      }

      emit(state.copyWith(
        status: FilePickerStatus.picked,
        files: pickedFiles,
      ));
    } catch (e) {
      emit(state.copyWith(
        status: FilePickerStatus.error,
        errorMessage: 'Failed to pick files: $e',
      ));
    }
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
