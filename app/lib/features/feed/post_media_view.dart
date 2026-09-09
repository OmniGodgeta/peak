import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../../data/settings_repository.dart';

/// Renders a post's images (animated GIFs included — `Image.network` animates
/// them). One image fills the width at its aspect ratio; 2–4 form a grid.
class PostMediaView extends ConsumerWidget {
  const PostMediaView({super.key, required this.media});
  final List<PostMedia> media;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(feedRepositoryProvider);
    final radius = BorderRadius.circular(10);

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
