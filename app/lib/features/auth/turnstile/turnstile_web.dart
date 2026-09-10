import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:ui_web' as ui_web;

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

const _scriptSrc =
    'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';

int _seq = 0;
bool _scriptRequested = false;

@JS('turnstile')
external JSObject? get _turnstile;

Widget turnstileView({
  required String siteKey,
  required void Function(String? token) onToken,
}) {
  return _TurnstileView(siteKey: siteKey, onToken: onToken);
}

class _TurnstileView extends StatefulWidget {
  const _TurnstileView({required this.siteKey, required this.onToken});
  final String siteKey;
  final void Function(String?) onToken;

  @override
  State<_TurnstileView> createState() => _TurnstileViewState();
}

class _TurnstileViewState extends State<_TurnstileView> {
  late final String _viewType = 'cf-turnstile-${_seq++}';

  @override
  void initState() {
    super.initState();
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final host = (web.document.createElement('div') as web.HTMLDivElement)
        ..style.width = '300px'
        ..style.height = '65px';
      _ensureScript();
      _renderWhenReady(host);
      return host;
    });
  }

  void _renderWhenReady(web.HTMLElement host) {
    var tries = 0;
    Timer.periodic(const Duration(milliseconds: 200), (t) {
      tries++;
      final ts = _turnstile;
      if (ts != null) {
        t.cancel();
        final opts = JSObject();
        opts.setProperty('sitekey'.toJS, widget.siteKey.toJS);
        opts.setProperty(
          'callback'.toJS,
          ((JSString token) => widget.onToken(token.toDart)).toJS,
        );
        opts.setProperty(
          'error-callback'.toJS,
          (() => widget.onToken(null)).toJS,
        );
        opts.setProperty(
          'expired-callback'.toJS,
          (() => widget.onToken(null)).toJS,
        );
        ts.callMethodVarArgs('render'.toJS, [host as JSAny, opts]);
      } else if (tries > 50) {
        t.cancel();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 300,
      height: 72,
      child: HtmlElementView(viewType: _viewType),
    );
  }
}

void _ensureScript() {
  if (_scriptRequested) return;
  _scriptRequested = true;
  final s = web.document.createElement('script') as web.HTMLScriptElement
    ..src = _scriptSrc
    ..async = true
    ..defer = true;
  web.document.head?.appendChild(s);
}
