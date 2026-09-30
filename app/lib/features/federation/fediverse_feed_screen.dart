import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/federation_repository.dart';
import 'federation_screen.dart';
import 'remote_note_card.dart';

final fediverseFeedProvider = FutureProvider<List<RemoteNote>>(
  (ref) => ref.watch(federationRepositoryProvider).feed(),
);

/// Posts from people you follow on other servers, newest first.
class FediverseFeedScreen extends ConsumerWidget {
  const FediverseFeedScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(fediverseFeedProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fediverse'),
        actions: [
          IconButton(
            tooltip: 'Federation settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const FederationScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(fediverseFeedProvider),
        child: feed.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text("Couldn't load: $e"),
              ),
            ],
          ),
          data: (notes) => notes.isEmpty
              ? ListView(
                  children: const [
                    Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Nothing here yet. Follow people on other servers '
                        '(Mastodon and friends) from Federation settings, '
                        'and their public posts show up here.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                )
              : ListView.separated(
                  itemCount: notes.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => RemoteNoteCard(note: notes[i]),
                ),
        ),
      ),
    );
  }
}
