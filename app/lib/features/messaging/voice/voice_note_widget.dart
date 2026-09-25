import 'package:flutter/material.dart';

class VoiceNoteWidget extends StatelessWidget {
  final String conversationId;
  final VoidCallback onRecordStarted;
  final VoidCallback onRecordStopped;

  const VoiceNoteWidget({
    super.key,
    required this.conversationId,
    required this.onRecordStarted,
    required this.onRecordStopped,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.mic),
      onPressed: onRecordStarted,
    );
  }
}
