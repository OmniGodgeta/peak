import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../feed/article_screen.dart' show ArticleBody;

const _docs = <({String title, String asset})>[
  (title: 'Terms of Service', asset: 'assets/legal/TERMS.md'),
  (title: 'Privacy Policy', asset: 'assets/legal/PRIVACY.md'),
  (
    title: 'Community Guidelines',
    asset: 'assets/legal/COMMUNITY_GUIDELINES.md',
  ),
  (title: 'Copyright / DMCA', asset: 'assets/legal/DMCA.md'),
];

/// The list of legal documents.
class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Terms & policies')),
      body: ListView(
        children: [
          for (final d in _docs)
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: Text(d.title),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      LegalDocScreen(title: d.title, asset: d.asset),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One legal document, rendered with the shared tiny-Markdown [ArticleBody].
class LegalDocScreen extends StatelessWidget {
  const LegalDocScreen({super.key, required this.title, required this.asset});
  final String title;
  final String asset;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: FutureBuilder<String>(
        future: rootBundle.loadString(asset),
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [ArticleBody(text: snap.data!)],
          );
        },
      ),
    );
  }
}
