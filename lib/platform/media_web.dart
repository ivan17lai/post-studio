import 'dart:js_interop';
import 'dart:ui' as ui;
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

@JS('postStudioMedia.call')
external JSPromise<JSAny?> _call(JSString operation, JSAny? payload);
Future<JSAny?> invokeMedia(String operation, Map<String, dynamic> payload) =>
    _call(operation.toJS, payload.jsify()).toDart;
Future<Uint8List> readImageBytes(String path) async =>
    (await invokeMedia('read', {'path': path}) as JSUint8Array).toDart;
Future<Uint8List?> readImageBytesIfPresent(String path) async =>
    readImageBytes(path);

class _BrowserImage extends ImageProvider<String> {
  const _BrowserImage(this.path);
  final String path;
  @override
  Future<String> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(path);
  @override
  ImageStreamCompleter loadImage(String key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _decode(key, decode), scale: 1);
  Future<ui.Codec> _decode(String key, ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await readImageBytes(key)));
}

ImageProvider<Object> storedImageProvider(String path) => _BrowserImage(path);
Widget storedImage(
  String path, {
  BoxFit? fit,
  int? cacheWidth,
  int? cacheHeight,
  double? width,
  double? height,
  FilterQuality filterQuality = FilterQuality.medium,
  bool gaplessPlayback = false,
  ImageErrorWidgetBuilder? errorBuilder,
}) => Image(
  image: ResizeImage.resizeIfNeeded(
    cacheWidth,
    cacheHeight,
    storedImageProvider(path),
  ),
  fit: fit,
  width: width,
  height: height,
  filterQuality: filterQuality,
  gaplessPlayback: gaplessPlayback,
  errorBuilder: errorBuilder,
);
Future<Map<String, dynamic>> prepareImageAsset(
  String projectId,
  String path, {
  int maxPreviewSide = 720,
}) async => Map<String, dynamic>.from(
  (await invokeMedia('prepare', {
        'projectId': projectId,
        'path': path,
      })).dartify()!
      as Map,
);
Future<String> writePreviewImage(Uint8List bytes, String name) async =>
    (await invokeMedia('previewFile', {'bytes': bytes}) as JSString).toDart;
final _exports = <({String name, Uint8List bytes})>[];
void beginExportBatch() => _exports.clear();
void cancelExportBatch() => _exports.clear();
Future<bool> saveImage(Uint8List bytes, String name) async {
  _exports.add((name: '$name.jpg', bytes: bytes));
  return true;
}

Future<bool> saveOriginal(String path, String name) async =>
    saveImage(await readImageBytes(path), name);
Future<void> finishExportBatch(String name) async {
  if (_exports.isEmpty) return;
  late Uint8List bytes;
  late String filename;
  late String type;
  if (_exports.length == 1) {
    bytes = _exports.single.bytes;
    filename = _exports.single.name;
    type = 'image/jpeg';
  } else {
    final archive = Archive();
    for (var i = 0; i < _exports.length; i++) {
      final item = _exports[i];
      archive.addFile(
        ArchiveFile(
          '${(i + 1).toString().padLeft(3, '0')}_${item.name}',
          item.bytes.length,
          item.bytes,
        ),
      );
    }
    // JPEGs are already compressed. Store them directly instead of blocking
    // the Flutter UI with another Deflate pass over every selected page.
    bytes = Uint8List.fromList(ZipEncoder().encode(archive, level: 0));
    filename = '${name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')}.zip';
    type = 'application/zip';
  }
  await invokeMedia('download', {
    'bytes': bytes,
    'name': filename,
    'type': type,
  });
  _exports.clear();
}

Future<Uint8List> renderWebPage(Map<String, dynamic> payload) async =>
    (await invokeMedia('render', payload) as JSUint8Array).toDart;
Future<Map<String, dynamic>> webHdrCapabilities() async =>
    Map<String, dynamic>.from(
      (await invokeMedia('capabilities', {})).dartify()! as Map,
    );
Future<bool> webIsHdr(String path) async =>
    (await invokeMedia('inspect', {'path': path}) as JSBoolean).toDart;
