import 'package:flutter/material.dart';
import 'app_strings.dart';
import 'platform/install_stub.dart'
    if (dart.library.js_interop) 'platform/install_web.dart';

class InstallAppButton extends StatefulWidget {
  const InstallAppButton({super.key});

  @override
  State<InstallAppButton> createState() => _InstallAppButtonState();
}

class _InstallAppButtonState extends State<InstallAppButton> {
  bool _busy = false;

  Future<void> _install() async {
    setState(() => _busy = true);
    var result = 'manual';
    try {
      result = await requestInstall();
    } catch (_) {
      // Browsers without an installation API still offer manual instructions.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (result == 'accepted' || result == 'dismissed') return;
    final strings = AppStrings.of(context);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          strings.t(result == 'installed' ? 'appInstalled' : 'installWebApp'),
        ),
        content: SingleChildScrollView(
          child: Text(
            strings.t(
              result == 'installed' ? 'appInstalledHelp' : 'installAppSteps',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(strings.t('installGotIt')),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FilledButton.tonalIcon(
    onPressed: _busy ? null : _install,
    icon: const Icon(Icons.install_mobile_rounded, size: 18),
    label: Text(AppStrings.of(context).t('installAppButton')),
  );
}
