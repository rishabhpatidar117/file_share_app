import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:open_file/open_file.dart';
import 'windows_open_with.dart';

/// Opens a file in a system app. On Windows a chooser dialog lists the apps
/// that can handle the file type (scanned from the registry); on other
/// platforms the OS default handler is used.
class FileOpener {
  FileOpener._();

  static Future<void> open(BuildContext context, String filePath) async {
    if (!kIsWeb && Platform.isWindows) {
      await _openWithChooser(context, filePath);
      return;
    }
    await OpenFile.open(filePath);
  }

  static Future<void> _openWithChooser(
    BuildContext context,
    String filePath,
  ) async {
    final apps = WindowsOpenWith.enumerate(filePath);
    final choice = await showDialog<_OpenWithChoice>(
      context: context,
      builder: (ctx) => _OpenWithDialog(
        apps: apps,
        fileName: filePath.split(r'\').last.split('/').last,
      ),
    );
    if (choice == null || !context.mounted) return;

    switch (choice) {
      case _OpenWithChoiceSystem():
        WindowsOpenWith.showSystemChooser(filePath);
      case _OpenWithChoiceApp(:final exePath):
        WindowsOpenWith.launchApp(exePath, filePath);
    }
  }
}

sealed class _OpenWithChoice {
  const _OpenWithChoice();
}

class _OpenWithChoiceApp extends _OpenWithChoice {
  final String exePath;
  const _OpenWithChoiceApp(this.exePath);
}

class _OpenWithChoiceSystem extends _OpenWithChoice {
  const _OpenWithChoiceSystem();
}

class _OpenWithDialog extends StatelessWidget {
  final List<OpenApp> apps;
  final String fileName;

  const _OpenWithDialog({required this.apps, required this.fileName});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AlertDialog(
      backgroundColor: isDark ? const Color(0xFF1E1432) : Colors.white,
      title: const Text('Open with'),
      content: SizedBox(
        width: double.maxFinite,
        height: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              fileName,
              style: TextStyle(
                fontSize: 13,
                color: isDark
                    ? const Color(0xFF9E95B8)
                    : const Color(0xFF6B6280),
              ),
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: apps.isEmpty
                  ? const Center(child: Text('No apps found for this file type.'))
                  : ListView.separated(
                      shrinkWrap: true,
                      itemCount: apps.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final app = apps[index];
                        return ListTile(
                          dense: true,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          leading: Container(
                            width: 36,
                            height: 36,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: app.isDefault
                                  ? const Color(0xFF7C4DFF)
                                  : (isDark
                                      ? const Color(0xFF2A2140)
                                      : const Color(0xFFF0EBFF)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              app.name.isNotEmpty ? app.name[0].toUpperCase() : '?',
                              style: TextStyle(
                                color: app.isDefault
                                    ? Colors.white
                                    : const Color(0xFF7C4DFF),
                                fontWeight: FontWeight.w700,
                                fontSize: 16,
                              ),
                            ),
                          ),
                          title: Text(
                            app.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: app.isDefault
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: isDark
                                  ? const Color(0xFFE8E1F7)
                                  : const Color(0xFF221A33),
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: app.isDefault
                              ? Text(
                                  'Default',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: const Color(0xFF7C4DFF),
                                  ),
                                )
                              : null,
                          onTap: () => Navigator.pop(
                            context,
                            _OpenWithChoiceApp(app.exePath!),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, const _OpenWithChoiceSystem()),
          child: const Text('Choose another app...'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}