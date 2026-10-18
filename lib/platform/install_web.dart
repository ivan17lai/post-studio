import 'dart:js_interop';

@JS('postStudioInstall')
external JSPromise<JSString> _requestInstall();

Future<String> requestInstall() async =>
    (await _requestInstall().toDart).toDart;
