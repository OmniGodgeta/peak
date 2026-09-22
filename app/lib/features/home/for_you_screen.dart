import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/feed_repository.dart';
import '../feed/feed_screen.dart';

/// A specialized view of the feed that specifically displays 
/// recommended content based on vector similarity.
class ForYouScreen extends ConsumerWidget {
  const ForYouScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FeedScreen(forcedKind: FeedKind.recommendations);
  }
}
