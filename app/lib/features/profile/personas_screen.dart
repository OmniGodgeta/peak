import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/persona_repository.dart';

/// Faces of this login. Other people are not shown the list.
class PersonasScreen extends ConsumerStatefulWidget {
  const PersonasScreen({super.key});

  @override
  ConsumerState<PersonasScreen> createState() => _PersonasScreenState();
}

class _PersonasScreenState extends ConsumerState<PersonasScreen> {
  final _label = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    setState(() => _error = null);
    try {
      await ref.read(personaRepositoryProvider).create(_label.text);
      _label.clear();
      ref.invalidate(myPersonasProvider);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  Future<void> _use(String id) async {
    await ref.read(personaRepositoryProvider).makeDefault(id);
    ref.invalidate(myPersonasProvider);
  }

  @override
  Widget build(BuildContext context) {
    final personas = ref.watch(myPersonasProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Personas')),
      body: personas.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (list) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'New posts use the persona you select. People still see your '
              'handle. This list is only yours — it is not on your profile.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            RadioGroup<String>(
              groupValue: list
                  .where((e) => e.isDefault)
                  .map((e) => e.id)
                  .firstOrNull,
              onChanged: (id) {
                if (id != null) _use(id);
              },
              child: Column(
                children: [
                  for (final p in list)
                    RadioListTile<String>(
                      value: p.id,
                      title: Text(p.label),
                      subtitle: Text(
                        p.isDefault ? 'Used for new posts' : 'Saved',
                      ),
                    ),
                ],
              ),
            ),
            if (list.length < 5) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _label,
                decoration: const InputDecoration(
                  labelText: 'New persona',
                  hintText: 'A project, a pen name',
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _add(),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: _add, child: const Text('Add')),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
