import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _gallery = MethodChannel('igapp/gallery');
Future<Uint8List> readImageBytes(String path) => File(path).readAsBytes();
Future<Uint8List?> readImageBytesIfPresent(String path) async =>
    await File(path).exists() ? File(path).readAsBytes() : null;
ImageProvider<Object> storedImageProvider(String path) => FileImage(File(path));
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
}) async =>
    await _gallery.invokeMapMethod<String, dynamic>('prepareImageAsset', {
      'projectId': projectId,
      'sourcePath': path,
      'maxPreviewSide': maxPreviewSide,
    }) ??
    <String, dynamic>{};
Future<String> writePreviewImage(Uint8List bytes, String name) async {
  final directory = await getTemporaryDirectory();
  final file = File('${directory.path}/$name');
  await file.writeAsBytes(bytes, flush: true);
  return file.path;
}

void beginExportBatch() {}
Future<void> finishExportBatch(String name) async {}
void cancelExportBatch() {}
Future<bool> saveImage(Uint8List bytes, String name) async =>
    await _gallery.invokeMethod<bool>('saveJpgToGallery', {
      'bytes': bytes,
      'name': name,
    }) ??
    false;
Future<bool> saveOriginal(String path, String name) async =>
    await _gallery.invokeMethod<bool>('saveOriginalToGallery', {
      'path': path,
      'name': name,
    }) ??
    false;
Future<Uint8List> renderWebPage(Map<String, dynamic> payload) =>
    throw UnsupportedError('Web renderer');
Future<Map<String, dynamic>> webHdrCapabilities() async => {
  'supportsGainmap': false,
};
Future<bool> webIsHdr(String path) async => false;
