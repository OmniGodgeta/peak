import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

/// A screen that displays a real-time list of active gaming rooms
/// by connecting to the arcade-netplay signaling server.
class ArcadeLobbyScreen extends ConsumerStatefulWidget {
  const ArcadeLobbyScreen({super.key});

  @override
  ConsumerState<ArcadeLobbyScreen> createState() => _ArcadeLobbyScreenState();
}

class _ArcadeLobbyScreenState extends ConsumerState<ArcadeLobbyScreen> {
  late io.Socket _socket;
  List<Map<String, dynamic>> _rooms = [];
  bool _isConnected = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _connect();
  }

  void _connect() {
    try {
      // Connecting to the signaling server found earlier (port 8712)
      _socket = io.io('http://localhost:8712', <String, dynamic>{
        'transports': ['websocket'],
        'autoConnect': true,
      });

      _socket.onConnect((_) {
        setState(() {
          _isConnected = true;
          _error = '';
        });
        // Request initial room list
        _socket.emit('get_rooms', {});
      });

      _socket.on('rooms_list', (data) {
        setState(() {
          _rooms = List<Map<String, dynamic>>.from(data);
        });
      });

      _socket.onConnectError((err) => setState(() => _error = 'Connection failed.'));
      _socket.onDisconnect((_) => setState(() => _isConnected = false));
      _socket.on('error', (err) => setState(() => _error = err.toString()));
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _socket.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Arcade Lobby'),
        actions: [
          if (!_isConnected)
            const Icon(Icons.cloud_off, color: Colors.red)
          else
            const Icon(Icons.cloud_done, color: Colors.green),
        ],
      ),
      body: _error.isNotEmpty
          ? Center(child: Text(_error))
          : Column(
              children: [
                if (_rooms.isEmpty)
                  const Expanded(child: Center(child: Text('No active games found.'))),
                Expanded(
                  child: ListView.builder(
                    itemCount: _rooms.length,
                    itemBuilder: (context, index) {
                      final room = _rooms[index];
                      return ListTile(
                        leading: const Icon(Icons.videogame_asset),
                        title: Text(room['name'] ?? 'Unknown Game'),
                        subtitle: Text('Players: \${room['players'] ?? 0} / \${room['max_players'] ?? 4}'),
                        trailing: const Icon(Icons.play_arrow),
                        onTap: () {
                          // Logic to join the room would go here (via socket.emit('join_room', ...))
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Joining \${room['name']}...')),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
