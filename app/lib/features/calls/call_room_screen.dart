import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A stub signaling service to simulate room joining and event exchange.
/// In a real implementation, this would interface with WebRTC via a native plugin.
class CallSignalingStub {
  final String roomId;
  final String userId;

  CallSignalingStub({required this.roomId, required this.userId});

  // Simulates joining the room
  Future<void> joinRoom() async {
    await Future.delayed(const Duration(seconds: 1));
    debugPrint('Joined room $roomId as $userId');
  }

  // Simulates sending a signal (e.g., SDP offer/answer or ICE candidate)
  Future<void> sendSignal(String type, Map<String, dynamic> data) async {
    await Future.delayed(const Duration(milliseconds: 500));
    debugPrint('Sent signal [$type] in $roomId: $data');
  }

  // Stream of incoming signals from others
  Stream<Map<String, dynamic>> get signalStream => Stream.periodic(
        const Duration(seconds: 5),
        (i) => {
          'type': 'ice-candidate',
          'senderId': 'other-user-$i',
          'data': {'candidate': 'dummy-sdp-data'}
        },
      );
}

/// Riverpod provider for the signaling stub.
final callSignalingProvider = Provider.family<CallSignalingStub, String>((ref, roomId) {
  return CallSignalingStub(roomId: roomId, userId: 'local-user'); // In real app, use actual user ID
});

/// A UI screen representing a call room.
class CallRoomScreen extends ConsumerStatefulWidget {
  final String roomId;
  final String title;

  const CallRoomScreen({super.key, required this.roomId, required this.title});

  @override
  ConsumerState<CallRoomScreen> createState() => _CallRoomScreenState();
}

class _CallRoomScreenState extends ConsumerState<CallRoomScreen> {
  bool _isInCall = false;
  final List<String> _participants = ['You'];

  @override
  void initState() {
    super.initState();
    _setupCall();
  }

  Future<void> _setupCall() async {
    final signaling = ref.read(callSignalingProvider(widget.roomId));
    await signaling.joinRoom();
    if (mounted) {
      setState(() {
        _isInCall = true;
        // Simulate another person joining after 3 seconds
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) {
            setState(() {
              _participants.add('Remote User');
            });
          }
        });
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.call_end, color: Colors.red),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
      body: Center(
        child: !_isInCall
            ? const CircularProgressIndicator()
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.mic, size: 80, color: Colors.white54),
                  const SizedBox(height: 24),
                  const Text(
                    'Connected to Room',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Participants: ${_participants.length}'),
                  const SizedBox(height: 48),
                  Wrap(
                    spacing: 20,
                    children: [
                      _buildActionButton(Icons.mic, 'Mute', true),
                      _buildActionButton(Icons.videocam_off, 'Video Off', false),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.all(24),
                      itemCount: _participants.length,
                      itemBuilder: (context, index) {
                        return ListTile(
                          leading: CircleAvatar(child: Text(_participants[index][0])),
                          title: Text(_participants[index]),
                          subtitle: const Text('In Call'),
                        );
                      },
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildActionButton(IconData icon, String label, bool isPrimary) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircleAvatar(
          radius: 28,
          backgroundColor: Colors.white12,
          child: IconButton(
            icon: Icon(icon, color: Colors.white),
            onPressed: () {},
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}
