import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import 'text_generator.dart';

Future<Uint8List?> downsizeImageIfNeeded(File source) async {
  const maxEdge = 1024;
  final buffer = await ui.ImmutableBuffer.fromFilePath(source.path);
  try {
    final descriptor = await ui.ImageDescriptor.encoded(buffer);
    try {
      final width = descriptor.width;
      final height = descriptor.height;
      final longestEdge = math.max(width, height);
      if (longestEdge <= maxEdge) return null;

      final codec = await descriptor.instantiateCodec(
        targetWidth: math.max(1, (width * maxEdge / longestEdge).round()),
        targetHeight: math.max(1, (height * maxEdge / longestEdge).round()),
      );
      try {
        final frame = await codec.getNextFrame();
        try {
          final bytes = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (bytes == null) {
            throw StateError('Could not encode the resized image.');
          }
          return bytes.buffer.asUint8List(
            bytes.offsetInBytes,
            bytes.lengthInBytes,
          );
        } finally {
          frame.image.dispose();
        }
      } finally {
        codec.dispose();
      }
    } finally {
      descriptor.dispose();
    }
  } finally {
    buffer.dispose();
  }
}

class MediaInput {
  Directory? _directory;
  AudioRecorder? _recorder;

  Future<Directory> _storage() async {
    return _directory ??= await (await getTemporaryDirectory()).createTemp(
      'llm_input_',
    );
  }

  Future<PromptAttachment?> pick(
    AttachmentKind kind, {
    bool downsizeImages = false,
  }) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: kind == AttachmentKind.image
          ? ['jpg', 'jpeg', 'png', 'bmp', 'gif']
          : ['wav', 'mp3', 'flac'],
    );
    if (file == null) return null;
    final extension = file.extension?.toLowerCase();
    if (extension == null) {
      throw StateError('The selected file has no extension.');
    }
    final target = File(
      '${(await _storage()).path}/${DateTime.now().microsecondsSinceEpoch}.$extension',
    );
    final output = target.openWrite();
    try {
      await output.addStream(file.readAsByteStream());
    } finally {
      await output.close();
    }
    var prepared = target;
    if (kind == AttachmentKind.image && downsizeImages) {
      final resized = await downsizeImageIfNeeded(target);
      if (resized != null) {
        prepared = File('${target.path}.png');
        await prepared.writeAsBytes(resized);
        await target.delete();
      }
    }
    return PromptAttachment(kind: kind, path: prepared.path, name: file.name);
  }

  Future<void> startRecording() async {
    final recorder = _recorder ??= AudioRecorder();
    if (!await recorder.hasPermission()) {
      throw StateError('Microphone permission was denied.');
    }
    final path =
        '${(await _storage()).path}/${DateTime.now().microsecondsSinceEpoch}.wav';
    await recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: path,
    );
  }

  Future<PromptAttachment> stopRecording() async {
    final path = await _recorder?.stop();
    if (path == null) throw StateError('No recording was produced.');
    return PromptAttachment(
      kind: AttachmentKind.audio,
      path: path,
      name: 'Microphone recording',
    );
  }

  Future<void> clear() async {
    final directory = _directory;
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
    _directory = null;
  }

  Future<void> dispose() async {
    await _recorder?.dispose();
    await clear();
  }
}
