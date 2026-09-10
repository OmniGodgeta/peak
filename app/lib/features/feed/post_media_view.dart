import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../data/feed_repository.dart';
import '../../data/settings_repository.dart';

/// Renders a post's images (animated GIFs included — `Image.network` animates
/// them) or a single video. One image fills the width at its aspect ratio; 2–4
/// form a grid.
class PostMediaView extends ConsumerWidget {
  const PostMediaView({super.key, required this.media});
  final List<PostMedia> media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(feedRepositoryProvider);
    final radius = BorderRadius.circular(10);

    for (final m in media) {
      if (m.kind == 'video') {
        return PostVideo(
          url: repo.mediaUrl(m.storagePath),
          posterUrl: m.posterPath == null ? null : repo.mediaUrl(m.posterPath!),
          aspectRatio: m.aspectRatio,
        );
      }
    }

    if (media.length == 1) {
      final m = media.single;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 440),
        child: ClipRRect(
          borderRadius: radius,
          child: AspectRatio(
            aspectRatio: (m.aspectRatio ?? 4 / 3).clamp(0.7, 1.9),
            child: _Img(url: repo.mediaUrl(m.storagePath), alt: m.altText),
          ),
        ),
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
        childAspectRatio: media.length == 2 ? 1.0 : 1.2,
        children: [
          for (final m in media)
            _Img(url: repo.mediaUrl(m.storagePath), alt: m.altText),
        ],
      ),
    );
  }
}

class _Img extends ConsumerStatefulWidget {
  const _Img({required this.url, this.alt});
  final String url;
  final String? alt;

  @override
  ConsumerState<_Img> createState() => _ImgState();
}

class _ImgState extends ConsumerState<_Img> {
  bool _tappedToLoad = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final alt = widget.alt;

    if (ref.watch(dataLightProvider) && !_tappedToLoad) {
      return GestureDetector(
        onTap: () => setState(() => _tappedToLoad = true),
        child: Container(
          color: scheme.surfaceContainerHigh,
          alignment: Alignment.center,
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_outlined, color: scheme.onSurfaceVariant),
              const SizedBox(height: 4),
              Text(
                alt?.isNotEmpty == true ? alt! : 'Tap to load image',
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelMedium
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return Semantics(
      label: alt,
      image: true,
      child: Image.network(
        widget.url,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) => progress == null
            ? child
            : Container(color: scheme.surfaceContainerHigh),
        errorBuilder: (context, _, _) => Container(
          color: scheme.surfaceContainerHigh,
          alignment: Alignment.center,
          child: Icon(
            Icons.broken_image_outlined,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A single video. Doesn't autoplay: shows a poster with a play button, loads
/// and plays on tap, then offers scrub + mute. Honours the data-saver setting.
class PostVideo extends ConsumerStatefulWidget {
  const PostVideo({
    super.key,
    required this.url,
    this.posterUrl,
    this.aspectRatio,
    this.maxHeight = 440,
    this.autoLoad = false,
  });
  final String url;
  final String? posterUrl;
  final double? aspectRatio;
  final double maxHeight;

  /// Start loading immediately instead of on tap (the watch page).
  final bool autoLoad;

  @override
  ConsumerState<PostVideo> createState() => _PostVideoState();
}

class _PostVideoState extends ConsumerState<PostVideo> {
  VideoPlayerController? _c;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ref.read(dataLightProvider)) _load();
      });
    }
  }

  double get _ratio {
    final c = _c;
    if (c != null && c.value.isInitialized && c.value.aspectRatio > 0) {
      return c.value.aspectRatio.clamp(0.6, 1.9);
    }
    return (widget.aspectRatio ?? 16 / 9).clamp(0.6, 1.9);
  }

  Future<void> _load() async {
    if (_loading || _c != null) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    final c = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    try {
      await c.initialize();
      await c.setLooping(true);
      _c = c;
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _loading = false);
      await c.play();
    } on Exception {
      await c.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(10);
    final c = _c;
    final ready = c != null && c.value.isInitialized;

    Widget frame(Widget child) => ConstrainedBox(
      constraints: BoxConstraints(maxHeight: widget.maxHeight),
      child: ClipRRect(
        borderRadius: radius,
        child: AspectRatio(aspectRatio: _ratio, child: child),
      ),
    );

    if (!ready) {
      final dataLight = ref.watch(dataLightProvider);
      final poster = widget.posterUrl;
      return frame(
        GestureDetector(
          onTap: _loading ? null : _load,
          child: Stack(
            fit: StackFit.expand,
            alignment: Alignment.center,
            children: [
              Container(color: Colors.black87),
              if (poster != null && !dataLight)
                Image.network(
                  poster,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              if (_loading)
                const CircularProgressIndicator()
              else
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _failed ? Icons.error_outline : Icons.play_circle_fill,
                      color: Colors.white,
                      size: 52,
                      shadows: const [Shadow(blurRadius: 12)],
                    ),
                    if (_failed || dataLight) ...[
                      const SizedBox(height: 6),
                      Text(
                        _failed ? "Couldn't load video" : 'Tap to play video',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      );
    }

    return frame(
      Stack(
        alignment: Alignment.bottomCenter,
        children: [
          GestureDetector(
            onTap: () =>
                setState(() => c.value.isPlaying ? c.pause() : c.play()),
            child: VideoPlayer(c),
          ),
          if (!c.value.isPlaying)
            const IgnorePointer(
              child: Icon(
                Icons.play_circle_fill,
                size: 56,
                color: Colors.white70,
              ),
            ),
          Row(
            children: [
              Expanded(
                child: VideoProgressIndicator(
                  c,
                  allowScrubbing: true,
                  colors: VideoProgressColors(
                    playedColor: scheme.primary,
                    bufferedColor: Colors.white38,
                    backgroundColor: Colors.white24,
                  ),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: Icon(
                  c.value.volume == 0 ? Icons.volume_off : Icons.volume_up,
                  color: Colors.white,
                  size: 20,
                ),
                onPressed: () =>
                    setState(() => c.setVolume(c.value.volume == 0 ? 1 : 0)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
