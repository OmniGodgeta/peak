import 'package:flutter/material.dart';

class VoicePlayerWidget extends StatelessWidget {
  final String filePath;
  final VoidCallback onPlay;

  const VoicePlayerWidget({
    super.key,
    required this.filePath,
    required this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.play_arrow),
      onPressed: onPlay,
    );
  }
}
