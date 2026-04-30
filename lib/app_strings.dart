import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

class AppStrings {
  const AppStrings._();

  static const Map<String, String> _zh = <String, String>{
    'allProjects': '所有專案',
    'projectMeta': '建立時間 {date} ・ 總頁數 {count}',
    'createProject': '新增專案',
    'enterProjectName': '輸入專案名稱',
    'cancel': '取消',
    'create': '建立',
    'page': '頁面',
    'template': '模板',
    'elements': '元素',
    'imageSource': '圖片來源',
    'imageSettings': '圖片設定',
    'imageSnap': '圖片吸附',
    'keepAtLeastOnePage': '至少保留一頁',
    'deletePage': '刪除頁面',
    'deleteProject': '刪除專案',
    'confirmDeleteCurrentPage': '確定要刪除目前頁面嗎？',
    'confirmDeleteCurrentProject': '確定要刪除這個專案嗎？',
    'imagePickerNotReady': '圖片選擇器尚未載入，請完整重啟 App 後再試一次。',
    'exportCanvasNotFound': '找不到可匯出的畫布',
    'canvasConvertFailed': '畫布轉換失敗',
    'imageDecodeFailed': '圖片解碼失敗',
    'exportedJpg': '已匯出 JPG：{path}',
    'exportFailedTryAgain': '匯出失敗，請再試一次。',
    'prepareExport': '準備匯出',
    'prepareImages': '準備圖片 {current}/{total}',
    'prepareImagesDone': '圖片準備完成',
    'renderPages': '正在合成頁面',
    'exportPageProgress': '匯出第 {current}/{total} 頁',
    'exportPageDone': '已完成 {current}/{total} 頁',
    'exportedToGallery': '已匯出到手機相簿',
    'partialExportFailed': '部分頁面匯出失敗',
    'saving': '儲存中',
    'saved': '已儲存',
    'pageIndicator': '第 {current} / {total} 頁',
    'fill': '填滿',
    'stackedImages': '上下雙圖',
    'image': '圖片',
    'text': '文字',
    'uploadPhoto': '上傳照片',
    'replaceImage': '更換圖片',
    'importImages': '匯入圖片',
    'originalSize': '原始尺寸',
    'snapToGuides': '位置吸附',
    'snapAll': '全部吸附',
    'snapPageEdges': '頁面邊界',
    'snapPageCenter': '頁面中心',
    'snapImageLines': '圖片軸線',
    'snapImageEdges': '圖片貼邊',
    'pageTitle': '第 {index} 頁',
    'attachedPhotos': '附帶 {count} 張照片',
  };

  static const Map<String, String> _en = <String, String>{
    'allProjects': 'All Projects',
    'projectMeta': 'Created {date} · {count} pages',
    'createProject': 'Create Project',
    'enterProjectName': 'Enter project name',
    'cancel': 'Cancel',
    'create': 'Create',
    'page': 'Page',
    'template': 'Template',
    'elements': 'Elements',
    'imageSource': 'Image Source',
    'imageSettings': 'Image Settings',
    'imageSnap': 'Snap',
    'keepAtLeastOnePage': 'Keep at least one page',
    'deletePage': 'Delete Page',
    'deleteProject': 'Delete Project',
    'confirmDeleteCurrentPage': 'Delete the current page?',
    'confirmDeleteCurrentProject': 'Delete this project?',
    'imagePickerNotReady':
        'The image picker is not ready yet. Please fully restart the app and try again.',
    'exportCanvasNotFound': 'Export canvas not found',
    'canvasConvertFailed': 'Canvas conversion failed',
    'imageDecodeFailed': 'Image decode failed',
    'exportedJpg': 'Exported JPG: {path}',
    'exportFailedTryAgain': 'Export failed. Please try again.',
    'prepareExport': 'Preparing export',
    'prepareImages': 'Preparing images {current}/{total}',
    'prepareImagesDone': 'Images ready',
    'renderPages': 'Rendering pages',
    'exportPageProgress': 'Exporting page {current}/{total}',
    'exportPageDone': 'Completed {current}/{total}',
    'exportedToGallery': 'Exported to gallery',
    'partialExportFailed': 'Some pages failed to export',
    'saving': 'Saving',
    'saved': 'Saved',
    'pageIndicator': 'Page {current} / {total}',
    'fill': 'Fill',
    'stackedImages': 'Top & Bottom',
    'image': 'Image',
    'text': 'Text',
    'uploadPhoto': 'Upload Photo',
    'replaceImage': 'Replace Image',
    'importImages': 'Import Images',
    'originalSize': 'Original Size',
    'snapToGuides': 'Snap',
    'snapAll': 'All Snap',
    'snapPageEdges': 'Page Edges',
    'snapPageCenter': 'Page Center',
    'snapImageLines': 'Image Lines',
    'snapImageEdges': 'Image Edges',
    'pageTitle': 'Page {index}',
    'attachedPhotos': '{count} attached photos',
  };

  static AppStrings of(BuildContext context) {
    return const AppStrings._();
  }

  static AppStrings get system {
    return const AppStrings._();
  }

  String t(String key, {Map<String, String> args = const <String, String>{}}) {
    var value = _zh[key] ?? key;
    for (final entry in args.entries) {
      value = value.replaceAll('{${entry.key}}', entry.value);
    }
    return value;
  }
}
