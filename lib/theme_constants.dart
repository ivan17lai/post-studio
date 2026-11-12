import 'package:flutter/material.dart';

import 'app_settings.dart';

Color get kPrimaryAccentColor => AppSettingsController.instance.primaryColor;
Color accentForeground(Color accent) =>
    accent.computeLuminance() > 0.179 ? Colors.black : Colors.white;
const Color kDeleteConfirmColor = Color(0xFFFF4747);
