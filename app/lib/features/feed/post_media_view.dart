import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:video_player/video_player.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../data/creator_repository.dart';
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
      if (m.kind == 'audio') {
        return PostAudio(
          url: repo.mediaUrl(m.storagePath),
          durationMs: m.durationMs,
          transcript: m.altText,
        );
      }
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
    this.initialPosition,
    this.onPositionChanged,
    this.captions = const [],
    this.onControllerReady,
  });
  final String url;
  final String? posterUrl;
  final double? aspectRatio;
  final double maxHeight;

  /// Start loading immediately instead of on tap (the watch page).
  final bool autoLoad;

  /// The position to start playing from.
  final Duration? initialPosition;

  /// Callback when the video playback position changes.
  final ValueChanged<Duration>? onPositionChanged;

  /// Timed caption lines; a CC toggle appears when there are any.
  final List<VideoCue> captions;

  /// Hands the ready controller to the parent (e.g. to seek to a chapter).
  final ValueChanged<VideoPlayerController>? onControllerReady;

  @override
  ConsumerState<PostVideo> createState() => _PostVideoState();
}

class _PostVideoState extends ConsumerState<PostVideo> {
  VideoPlayerController? _c;
  bool _loading = false;
  bool _failed = false;
  // Paused because it scrolled out of view — resume it when it comes back.
  bool _pausedByScroll = false;
  bool _showCaptions = true;
  final _visKey = UniqueKey();
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    if (widget.autoLoad) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !ref.read(dataLightProvider)) _load();
      });
    }
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      final controller = _c;
      if (controller != null && controller.value.isInitialized && mounted) {
        widget.onPositionChanged?.call(controller.value.position);
      }
    });
  }

  @override
  void dispose() {
    _positionTimer?.cancel();
    _c?.dispose();
    super.dispose();
  }

  void _onVisibility(double fraction) {
    final c = _c;
    if (c == null || !c.value.isInitialized || !mounted) return;
    if (fraction < 0.25 && c.value.isPlaying) {
      c.pause();
      _pausedByScroll = true;
    } else if (fraction > 0.6 && _pausedByScroll && !c.value.isPlaying) {
      c.play();
      _pausedByScroll = false;
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
      
      // Seek to initial position if provided
      if (widget.initialPosition != null) {
        await c.seekTo(widget.initialPosition!);
      }
      
      _c = c;
      if (!mounted) {
        c.dispose();
        return;
      }
      setState(() => _loading = false);
      widget.onControllerReady?.call(c);
      await c.play();
      _startPositionTimer();
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(10);
    final c = _c;
    final ready = c != null && c.value.isInitialized;

    Widget frame(Widget child) => VisibilityDetector(
      key: _visKey,
      onVisibilityChanged: (info) => _onVisibility(info.visibleFraction),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: widget.maxHeight),
        child: ClipRRect(
          borderRadius: radius,
          child: AspectRatio(aspectRatio: _ratio, child: child),
        ),
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
          if (_showCaptions && widget.captions.isNotEmpty)
            Positioned(
              left: 12,
              right: 12,
              bottom: 44,
              child: IgnorePointer(
                child: ValueListenableBuilder<VideoPlayerValue>(
                  valueListenable: c,
                  builder: (context, v, _) {
                    String? line;
                    for (final cue in widget.captions) {
                      if (cue.covers(v.position)) {
                        line = cue.text;
                        break;
                      }
                    }
                    if (line == null) return const SizedBox.shrink();
                    return Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        color: Colors.black.withValues(alpha: 0.7),
                        child: Text(
                          line,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
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
              if (widget.captions.isNotEmpty)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _showCaptions ? 'Hide captions' : 'Show captions',
                  icon: Icon(
                    _showCaptions
                        ? Icons.closed_caption
                        : Icons.closed_caption_off_outlined,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _showCaptions = !_showCaptions),
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

/// An audio-only post: play/pause, a seek bar, elapsed / total, and the
/// transcript (the attachment's alt text) behind a toggle. Loads on first tap
/// so a feed full of audio posts doesn't open a stream per card.
class PostAudio extends StatefulWidget {
  const PostAudio({
    super.key,
    required this.url,
    this.durationMs,
    this.transcript,
  });

  final String url;
  final int? durationMs;
  final String? transcript;

  @override
  State<PostAudio> createState() => _PostAudioState();
}

class _PostAudioState extends State<PostAudio> {
  ja.AudioPlayer? _player;
  bool _loading = false;
  bool _failed = false;
  bool _showTranscript = false;

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final p = _player;
    if (p != null) {
      p.playing ? await p.pause() : await p.play();
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    final created = ja.AudioPlayer();
    try {
      await created.setUrl(widget.url);
      if (!mounted) {
        await created.dispose();
        return;
      }
      created.playerStateStream.listen((st) {
        if (st.processingState == ja.ProcessingState.completed) {
          created.pause();
          created.seek(Duration.zero);
        }
        if (mounted) setState(() {});
      });
      setState(() {
        _player = created;
        _loading = false;
      });
      await created.play();
    } catch (_) {
      await created.dispose();
      if (mounted) {
        setState(() {
          _loading = false;
          _failed = true;
        });
      }
    }
  }

  static String _fmt(Duration d) =>
      '${d.inMinutes}:${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = _player;
    final known = widget.durationMs == null
        ? null
        : Duration(milliseconds: widget.durationMs!);
    final transcript = widget.transcript?.trim() ?? '';

    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconButton(
                tooltip: p?.playing == true ? 'Pause' : 'Play',
                onPressed: _loading ? null : _toggle,
                icon: _loading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        _failed
                            ? Icons.error_outline
                            : (p?.playing == true
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled),
                        size: 36,
                        color: scheme.primary,
                      ),
              ),
              Expanded(
                child: p == null
                    ? Row(
                        children: [
                          Icon(Icons.graphic_eq, color: scheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Text(
                            _failed
                                ? "Couldn't load audio"
                                : (known == null ? 'Audio' : _fmt(known)),
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        ],
                      )
                    : StreamBuilder<Duration>(
                        stream: p.positionStream,
                        builder: (context, snap) {
                          final pos = snap.data ?? Duration.zero;
                          final total = p.duration ?? known ?? Duration.zero;
                          final max = total.inMilliseconds.toDouble();
                          return Row(
                            children: [
                              Expanded(
                                child: Slider(
                                  value: pos.inMilliseconds
                                      .clamp(0, total.inMilliseconds)
                                      .toDouble(),
                                  max: max > 0 ? max : 1,
                                  onChanged: max > 0
                                      ? (v) => p.seek(
                                          Duration(milliseconds: v.round()),
                                        )
                                      : null,
                                ),
                              ),
                              Text(
                                '${_fmt(pos)} / ${_fmt(total)}',
                                style: Theme.of(context).textTheme.labelSmall,
                              ),
                            ],
                          );
                        },
                      ),
              ),
            ],
          ),
          if (transcript.isNotEmpty) ...[
            TextButton.icon(
              onPressed: () =>
                  setState(() => _showTranscript = !_showTranscript),
              icon: Icon(
                _showTranscript ? Icons.expand_less : Icons.subject,
                size: 18,
              ),
              label: Text(_showTranscript ? 'Hide transcript' : 'Transcript'),
            ),
            if (_showTranscript)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 0, 8),
                child: SelectableText(transcript),
              ),
          ],
        ],
      ),
    );
  }
}
