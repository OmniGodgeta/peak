import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../data/profile_repository.dart';

class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key, required this.profile});
  final Profile profile;

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  late final _name = TextEditingController(text: widget.profile.displayName);
  late final _bio = TextEditingController(text: widget.profile.bio);
  late final _pronouns = TextEditingController(
    text: widget.profile.pronouns ?? '',
  );
  late final _location = TextEditingController(
    text: widget.profile.locationCoarse ?? '',
  );
  late var _links = [...widget.profile.links];
  late var _showCounts = widget.profile.showFollowCounts;
  late var _discoverable = widget.profile.isDiscoverable;

  Uint8List? _avatarBytes;
  String? _avatarMime;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    _pronouns.dispose();
    _location.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    final x = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
    );
    if (x == null) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _avatarBytes = bytes;
      _avatarMime = x.mimeType ?? 'image/jpeg';
    });
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = ref.read(profileRepositoryProvider);
      String? avatarPath;
      if (_avatarBytes != null) {
        avatarPath = await repo.uploadAvatar(_avatarBytes!, _avatarMime!);
      }
      await repo.updateProfile(
        displayName: _name.text,
        bio: _bio.text,
        pronouns: _pronouns.text,
        locationCoarse: _location.text,
        avatarPath: avatarPath,
        links: _links,
        showFollowCounts: _showCounts,
        isDiscoverable: widget.profile.isTeen ? false : _discoverable,
      );
      ref.invalidate(myProfileProvider);
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final repo = ref.read(profileRepositoryProvider);
    final existingAvatar = widget.profile.avatarPath;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Edit profile'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Center(
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: scheme.primaryContainer,
                  backgroundImage: _avatarBytes != null
                      ? MemoryImage(_avatarBytes!)
                      : (existingAvatar != null
                            ? NetworkImage(repo.avatarUrl(existingAvatar))
                            : null),
                  child: (_avatarBytes == null && existingAvatar == null)
                      ? Text(
                          widget.profile.displayNameOrHandle.characters.first
                              .toUpperCase(),
                          style: const TextStyle(fontSize: 32),
                        )
                      : null,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: scheme.primary,
                    child: IconButton(
                      iconSize: 16,
                      icon: Icon(Icons.edit, color: scheme.onPrimary),
                      onPressed: _pickAvatar,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _name,
            maxLength: 80,
            decoration: const InputDecoration(labelText: 'Display name'),
          ),
          TextField(
            controller: _bio,
            maxLength: 500,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: 'Bio'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pronouns,
            maxLength: 40,
            decoration: const InputDecoration(labelText: 'Pronouns'),
          ),
          TextField(
            controller: _location,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Location',
              helperText:
                  'As vague as you like — “Pacific NW”, a city, nothing.',
            ),
          ),
          const SizedBox(height: 16),
          Text('Links', style: Theme.of(context).textTheme.labelLarge),
          for (var i = 0; i < _links.length; i++)
            _LinkRow(
              link: _links[i],
              onChanged: (l) => setState(() => _links[i] = l),
              onRemove: () => setState(() => _links.removeAt(i)),
            ),
          if (_links.length < 5)
            TextButton.icon(
              onPressed: () => setState(
                () =>
                    _links = [..._links, const ProfileLink(label: '', url: '')],
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add link'),
            ),
          const Divider(height: 32),
          SwitchListTile(
            title: const Text('Show follower / following counts'),
            value: _showCounts,
            onChanged: (v) => setState(() => _showCounts = v),
          ),
          SwitchListTile(
            title: const Text('Discoverable in search'),
            subtitle: widget.profile.isTeen
                ? const Text('Teen accounts are always private.')
                : null,
            value: widget.profile.isTeen ? false : _discoverable,
            onChanged: widget.profile.isTeen
                ? null
                : (v) => setState(() => _discoverable = v),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.link,
    required this.onChanged,
    required this.onRemove,
  });
  final ProfileLink link;
  final ValueChanged<ProfileLink> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 2,
          child: TextFormField(
            initialValue: link.label,
            decoration: const InputDecoration(hintText: 'Label', isDense: true),
            onChanged: (v) => onChanged(ProfileLink(label: v, url: link.url)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 3,
          child: TextFormField(
            initialValue: link.url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              hintText: 'https://…',
              isDense: true,
            ),
            onChanged: (v) => onChanged(ProfileLink(label: link.label, url: v)),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close, size: 18),
          onPressed: onRemove,
        ),
      ],
    );
  }
}
