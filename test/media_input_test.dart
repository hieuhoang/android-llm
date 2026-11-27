import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llm_text_app/media_input.dart';
import 'package:llm_text_app/text_generator.dart';

base class TestPlatformFile extends PlatformFile {
  TestPlatformFile(this.file);

  final File file;

  @override
  String get name => 'selected.png';
  @override
  Uri get uri => file.uri;
  @override
  Never get xFile => throw UnsupportedError('Not used by this test');
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() async => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

class TestFilePicker extends FilePickerPlatform {
  TestFilePicker(this.file);

  final PlatformFile file;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus status)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => file;
}

Future<Uint8List> makeImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    ui.Paint()..color = const ui.Color(0xffff0000),
  );
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(width, height);
    try {
      final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

Future<(int, int)> imageSize(File file) async {
  final buffer = await ui.ImmutableBuffer.fromFilePath(file.path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      return (descriptor.width, descriptor.height);
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async => directory = await Directory.systemTemp.createTemp());
  tearDown(() async => directory.delete(recursive: true));

  for (final (width, height) in [(640, 480), (1024, 400)]) {
    test('keeps ${width}x$height images unchanged', () async {
      final source = File('${directory.path}/image.png');
      final original = await makeImage(width, height);
      await source.writeAsBytes(original);

      expect(await downsizeImageIfNeeded(source), isNull);
      expect(await source.readAsBytes(), original);
    });
  }

  for (final (width, height, expectedWidth, expectedHeight) in [
    (1025, 513, 1024, 512),
    (2048, 1024, 1024, 512),
    (500, 2000, 256, 1024),
    (4096, 1, 1024, 1),
  ]) {
    test(
      'resizes ${width}x$height without changing its aspect ratio',
      () async {
        final source = File('${directory.path}/image.png');
        await source.writeAsBytes(await makeImage(width, height));

        final result = await downsizeImageIfNeeded(source);
        expect(result, isNotNull);
        final resized = File('${directory.path}/resized.png');
        await resized.writeAsBytes(result!);
        expect(await imageSize(resized), (expectedWidth, expectedHeight));
        expect(await source.exists(), isTrue);
      },
    );
  }

  test('reports invalid image data without deleting the source', () async {
    final source = File('${directory.path}/invalid.png');
    await source.writeAsBytes([1, 2, 3]);
    await expectLater(downsizeImageIfNeeded(source), throwsA(isA<Exception>()));
    expect(await source.exists(), isTrue);
  });

  test('selected images are resized only when requested', () async {
    final original = File('${directory.path}/original.png');
    final originalBytes = await makeImage(2048, 1024);
    await original.writeAsBytes(originalBytes);
    final previousPicker = FilePickerPlatform.instance;
    FilePickerPlatform.instance = TestFilePicker(TestPlatformFile(original));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getTemporaryDirectory') return directory.path;
          throw MissingPluginException();
        });
    final media = MediaInput();
    addTearDown(() async {
      await media.dispose();
      FilePickerPlatform.instance = previousPicker;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final unchanged = await media.pick(AttachmentKind.image);
    final resized = await media.pick(
      AttachmentKind.image,
      downsizeImages: true,
    );
    expect(await imageSize(File(unchanged!.path)), (2048, 1024));
    expect(await imageSize(File(resized!.path)), (1024, 512));
    expect(resized.name, 'selected.png');
    expect(await original.readAsBytes(), originalBytes);
    final codec = await ui.instantiateImageCodec(
      await File(resized.path).readAsBytes(),
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final pixels = (await frame.image.toByteData())!;
        expect(pixels.buffer.asUint8List().take(4), [255, 0, 0, 255]);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  });
}
