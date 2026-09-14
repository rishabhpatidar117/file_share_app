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
        emit(state.copyWith(status: FilePickerStatus.initial));
        return;
      }

      final pickedFiles = result.files.map((file) {
        return PickedFile(
          path: file.path ?? '',
          name: file.name,
          size: file.size,
        );
      }).toList();

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
    final pickedFiles = <PickedFile>[];
    for (final path in paths) {
      final file = File(path);
      if (await file.exists()) {
        final stat = await file.stat();
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
