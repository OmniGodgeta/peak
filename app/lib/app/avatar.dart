import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/profile_repository.dart';

/// A circular avatar: the person's image if they have one, otherwise their
/// initial on the brand container colour. All avatars live in the `avatars`
/// storage bucket, so [path] is just the object path.
class AvatarCircle extends ConsumerWidget {
  const AvatarCircle({
    super.key,
    required this.name,
    this.path,
    this.radius = 18,
  });

  final String name;
  final String? path;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final url = (path != null && path!.isNotEmpty)
        ? ref.read(profileRepositoryProvider).avatarUrl(path!)
        : null;
    return CircleAvatar(
      radius: radius,
      backgroundColor: scheme.primaryContainer,
      foregroundImage: url == null ? null : NetworkImage(url),
      child: Text(
        (name.isNotEmpty ? name : '?').characters.first.toUpperCase(),
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontSize: radius * 0.9,
        ),
      ),
    );
  }
}
