import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:youtube_player_iframe/youtube_player_iframe.dart';

import '../../data/link_preview_repository.dart';
import '../../data/settings_repository.dart';
import 'post_media_view.dart';

/// A post's text with tappable links, and — for the first interesting URL —
/// a rich preview card below it (a YouTube webcast plays inline on tap).
class PostBody extends ConsumerWidget {
  const PostBody({super.key, required this.text, this.showPreview = true});

  final String text;
  final bool showPreview;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final previewUrl = showPreview ? previewUrlFor(text) : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (text.trim().isNotEmpty) _LinkifiedText(text: text),
        if (previewUrl != null) ...[
          const SizedBox(height: 8),
          LinkPreview(url: previewUrl),
        ],
      ],
    );
  }
}

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({required this.text});
  final String text;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();

    final linkStyle = TextStyle(
      color: Theme.of(context).colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final re = RegExp(r'''https?://[^\s<>()"']+''');
    final spans = <InlineSpan>[];
    var i = 0;
    for (final m in re.allMatches(widget.text)) {
      if (m.start > i) {
        spans.add(TextSpan(text: widget.text.substring(i, m.start)));
      }
      var url = m.group(0)!;
      final trail = RegExp(r'[.,;:!?)\]]+$').firstMatch(url)?.group(0) ?? '';
      if (trail.isNotEmpty) url = url.substring(0, url.length - trail.length);
      final rec = TapGestureRecognizer()
        ..onTap = () =>
            launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      _recognizers.add(rec);
      spans.add(
        TextSpan(text: _shorten(url), style: linkStyle, recognizer: rec),
      );
      if (trail.isNotEmpty) spans.add(TextSpan(text: trail));
      i = m.end;
    }
    if (i < widget.text.length) {
      spans.add(TextSpan(text: widget.text.substring(i)));
    }

    return Text.rich(
      TextSpan(style: DefaultTextStyle.of(context).style, children: spans),
    );
  }

  static String _shorten(String url) {
    final u = url.replaceFirst(RegExp(r'^https?://(www\.)?'), '');
    return u.length <= 48 ? u : '${u.substring(0, 47)}…';
  }
}

class LinkPreview extends ConsumerWidget {
  const LinkPreview({super.key, required this.url});
  final String url;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(linkPreviewProvider(url));
    final data = async.asData?.value;
    if (data == null || !data.ok) return const SizedBox.shrink();

    if (data.isDirectVideo) {
      return PostVideo(url: data.finalUrl ?? url);
    }
    if (data.isYoutube) {
      return _YoutubeEmbed(data: data);
    }
    if (!data.hasCard) return const SizedBox.shrink();

    if (ref.watch(dataLightProvider)) {
      return _CompactLink(data: data);
    }
    return _LinkCard(data: data);
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.data});
  final LinkPreviewData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => launchUrl(
        Uri.parse(data.finalUrl ?? data.url),
        mode: LaunchMode.externalApplication,
      ),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(10),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (data.imageUrl != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: AspectRatio(
                  aspectRatio: 1.91,
                  child: Image.network(
                    data.imageUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (data.siteName ?? Uri.parse(data.url).host).toUpperCase(),
                    style: Theme.of(context).textTheme.labelSmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (data.title != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      data.title!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ],
                  if (data.description != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      data.description!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompactLink extends StatelessWidget {
  const _CompactLink({required this.data});
  final LinkPreviewData data;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return OutlinedButton.icon(
      onPressed: () => launchUrl(
        Uri.parse(data.finalUrl ?? data.url),
        mode: LaunchMode.externalApplication,
      ),
      icon: const Icon(Icons.link, size: 16),
      label: Text(
        data.title ?? data.siteName ?? Uri.parse(data.url).host,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      style: OutlinedButton.styleFrom(
        alignment: Alignment.centerLeft,
        foregroundColor: scheme.onSurface,
      ),
    );
  }
}

class _YoutubeEmbed extends StatefulWidget {
  const _YoutubeEmbed({required this.data});
  final LinkPreviewData data;

  @override
  State<_YoutubeEmbed> createState() => _YoutubeEmbedState();
}

class _YoutubeEmbedState extends State<_YoutubeEmbed> {
  YoutubePlayerController? _controller;

  void _play() {
    setState(() {
      _controller = YoutubePlayerController.fromVideoId(
        videoId: widget.data.videoId!,
        autoPlay: true,
        params: const YoutubePlayerParams(
          showControls: true,
          showFullscreenButton: true,
          enableCaption: true,
        ),
      );
    });
  }

  @override
  void dispose() {
    _controller?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(10);
    final c = _controller;
    if (c != null) {
      return ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: YoutubePlayer(controller: c),
        ),
      );
    }
    return InkWell(
      onTap: _play,
      child: ClipRRect(
        borderRadius: radius,
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Container(color: Colors.black87),
              if (widget.data.imageUrl != null)
                Image.network(
                  widget.data.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              const Center(
                child: Icon(
                  Icons.play_circle_fill,
                  size: 54,
                  color: Colors.white,
                  shadows: [Shadow(blurRadius: 12)],
                ),
              ),
              const Positioned(
                left: 8,
                bottom: 8,
                child: _Pill(text: 'YouTube'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text});
  final String text;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black87,
      borderRadius: BorderRadius.circular(4),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    ),
  );
}
