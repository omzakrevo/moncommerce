import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';

class PhotoPicker extends FilePickerPlatform {
  FilePickerResult? result;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'photo choisie dans les fichiers et conservée dans le stockage de l’application',
    () async {
      final original = FilePickerPlatform.instance;
      final picker = PhotoPicker();
      FilePickerPlatform.instance = picker;
      addTearDown(() => FilePickerPlatform.instance = original);
      final support = await Directory(
        'tmp/photo-selection',
      ).absolute.create(recursive: true);
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => support.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final source = File('assets/branding/moncommerce_logo.png').absolute;
      picker.result = FilePickerResult([
        PlatformFile(
          name: 'photo.png',
          size: await source.length(),
          path: source.path,
        ),
      ]);
      final selected = await selectProductPhoto();
      expect(selected, startsWith(support.path));
      expect(selected, isNot(source.path));
      expect(await File(selected!).exists(), isTrue);
      expect(await File(selected).length(), greaterThan(0));
      picker.result = null;
      expect(await selectProductPhoto(), isNull);
    },
  );
}
