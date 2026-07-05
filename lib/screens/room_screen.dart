import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'upload_screen.dart';

class RoomScreen extends StatefulWidget {
  final String roomId;
  const RoomScreen({super.key, required this.roomId});

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  final AudioPlayer _player = AudioPlayer();
  final _supabase = Supabase.instance.client;
  
  List<dynamic> _songs = [];
  bool _isLoadingSongs = true;
  
  // Realtime subscription
  RealtimeChannel? _roomSubscription;
  
  // Local state
  String? _currentSongId;
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  String _searchQuery = '';

  // Prevent recursive syncing
  bool _isSyncingFromRemote = false;

  @override
  void initState() {
    super.initState();
    _fetchSongs();
    _setupAudioListeners();
    _subscribeToRoom();
  }

  @override
  void dispose() {
    _roomSubscription?.unsubscribe();
    _player.dispose();
    super.dispose();
  }

  Future<void> _fetchSongs() async {
    try {
      final data = await _supabase.from('songs').select().order('created_at');
      setState(() {
        _songs = data;
        _isLoadingSongs = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error loading songs: $e')));
      }
    }
  }

  void _setupAudioListeners() {
    _player.playerStateStream.listen((state) {
      if (mounted) {
        setState(() => _isPlaying = state.playing);
      }
      
      if (state.processingState == ProcessingState.completed) {
        _updateRoomState(isPlaying: false, position: Duration.zero);
      }
    });

    _player.positionStream.listen((pos) {
      // We don't broadcast position on every tick to avoid spamming the DB,
      // but we could sync occasionally or when scrubbing.
      _position = pos;
    });
  }

  Future<void> _subscribeToRoom() async {
    _roomSubscription = _supabase.channel('public:rooms:id=eq.${widget.roomId}')
      .onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'rooms',
        filter: PostgresChangeFilter(type: PostgresChangeFilterType.eq, column: 'id', value: widget.roomId),
        callback: (payload) {
          _handleRemoteUpdate(payload.newRecord);
        }
      )
      .subscribe();
      
    // Initial fetch
    final data = await _supabase.from('rooms').select().eq('id', widget.roomId).single();
    _handleRemoteUpdate(data);
  }

  Future<void> _handleRemoteUpdate(Map<String, dynamic> data) async {
    _isSyncingFromRemote = true;
    
    final remoteSongId = data['current_song_id'] as String?;
    final remoteIsPlaying = data['is_playing'] as bool? ?? false;
    final remotePosition = Duration(milliseconds: data['position_ms'] as int? ?? 0);
    
    if (remoteSongId != null && remoteSongId != _currentSongId) {
      // Song changed
      setState(() {
        _currentSongId = remoteSongId;
        _isPlaying = remoteIsPlaying;
      });
      
      final song = _songs.firstWhere((s) => s['id'] == remoteSongId, orElse: () => null);
      if (song != null) {
        try {
          // Do not await to allow immediate command queuing
          _player.stop().catchError((_) {});
          _player.setAudioSource(AudioSource.uri(
            Uri.parse(song['url']),
            tag: MediaItem(
              id: song['id'],
              album: 'Music Room',
              title: song['title'],
            ),
          )).catchError((e) {
            debugPrint('Error setting remote source: $e');
          });
          
          _player.seek(remotePosition);
          
          if (remoteIsPlaying) {
            _player.play().catchError((e) {
              debugPrint('Autoplay blocked: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Tap Play to sync audio (browser blocked autoplay)')),
                );
              }
            });
          }
        } catch (e) {
          debugPrint('Error switching remote song: $e');
        }
      }
    } else if (remoteSongId != null) {
      // Same song, just sync state
      final drift = (remotePosition - _player.position).inMilliseconds.abs();
      if (drift > 2000) {
        _player.seek(remotePosition);
      }
      
      setState(() => _isPlaying = remoteIsPlaying);
      if (remoteIsPlaying) {
        if (!_player.playing) _player.play().catchError((_) {});
      } else {
        if (_player.playing) _player.pause();
      }
    }

    _isSyncingFromRemote = false;
  }

  Future<void> _updateRoomState({String? songId, required bool isPlaying, required Duration position}) async {
    try {
      await _supabase.from('rooms').update({
        if (songId != null) 'current_song_id': songId,
        'is_playing': isPlaying,
        'position_ms': position.inMilliseconds,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('id', widget.roomId);
    } catch (e) {
      debugPrint('Error updating room state: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sync Error: $e')));
      }
    }
  }
  
  Future<void> _playSong(Map<String, dynamic> song) async {
    // Play locally immediately to satisfy browser interaction policies
    setState(() {
      _currentSongId = song['id'];
      _isPlaying = true;
    });
    
    try {
      // Do not await these commands. just_audio will queue them.
      // This ensures play() is called in the same synchronous execution block as the click.
      _player.stop().catchError((_) {});
      
      _player.setAudioSource(AudioSource.uri(
        Uri.parse(song['url']),
        tag: MediaItem(
          id: song['id'],
          album: 'Music Room',
          title: song['title'],
        ),
      )).catchError((e) {
        debugPrint('Error setting audio source: $e');
      });
      
      _player.play().catchError((e) {
        debugPrint('Autoplay blocked during song switch: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Tap Play to start audio (browser blocked autoplay)')),
          );
        }
      });
    } catch (e) {
      debugPrint('Caught synchronous error in just_audio: $e');
    }

    // Broadcast to room
    await _updateRoomState(
      songId: song['id'], 
      isPlaying: true, 
      position: Duration.zero
    );
  }

  Future<void> _deleteSong(Map<String, dynamic> song) async {
    try {
      // 1. Clear foreign key references in rooms table to prevent PostgreSQL errors
      await _supabase.from('rooms').update({'current_song_id': null}).eq('current_song_id', song['id']);
      
      // 2. Delete from database
      await _supabase.from('songs').delete().eq('id', song['id']);
      
      // 3. Delete from storage
      final path = Uri.parse(song['url']).pathSegments.last;
      await _supabase.storage.from('songs').remove([path]);
      
      // If it's the current song being played, stop it
      if (_currentSongId == song['id']) {
        await _player.stop();
        _currentSongId = null;
        setState(() => _isPlaying = false);
        _updateRoomState(isPlaying: false, position: Duration.zero);
      }
      
      // Refresh list
      _fetchSongs();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Song deleted')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error deleting song: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Room: ${widget.roomId}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: 'Copy Room ID',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: widget.roomId));
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Room ID copied')));
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search songs...',
                hintStyle: const TextStyle(color: Colors.grey),
                prefixIcon: const Icon(Icons.search, color: Colors.grey),
                filled: true,
                fillColor: Colors.grey.shade900,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8.0),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
              ),
              onChanged: (value) {
                setState(() {
                  _searchQuery = value.toLowerCase();
                });
              },
            ),
          ),
          Expanded(
            child: _isLoadingSongs
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : _songs.isEmpty
                  ? const Center(child: Text('No songs uploaded yet.'))
                  : Builder(
                      builder: (context) {
                        final filteredSongs = _searchQuery.isEmpty 
                            ? _songs 
                            : _songs.where((s) => s['title'].toString().toLowerCase().contains(_searchQuery)).toList();
                        
                        if (filteredSongs.isEmpty) {
                          return const Center(child: Text('No songs match your search.'));
                        }
                        
                        return ListView.builder(
                          itemCount: filteredSongs.length,
                          itemBuilder: (context, index) {
                            final song = filteredSongs[index];
                            final isCurrent = song['id'] == _currentSongId;
                            return ListTile(
                              title: Text(
                                song['title'], 
                                maxLines: 1, 
                                overflow: TextOverflow.ellipsis, 
                                style: TextStyle(color: isCurrent ? Colors.grey : Colors.white)
                              ),
                              trailing: PopupMenuButton<String>(
                                icon: const Icon(Icons.more_vert, color: Colors.grey),
                                onSelected: (value) {
                                  if (value == 'delete') {
                                    _deleteSong(song);
                                  }
                                },
                                itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                                  const PopupMenuItem<String>(
                                    value: 'delete',
                                    child: Row(
                                      children: [
                                        Icon(Icons.delete, color: Colors.red, size: 20),
                                        SizedBox(width: 8),
                                        Text('Delete', style: TextStyle(color: Colors.red)),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                              onTap: () {
                                if (isCurrent) {
                                  // Toggle play/pause
                                  final newIsPlaying = !_isPlaying;
                                  if (newIsPlaying) {
                                    _player.play();
                                  } else {
                                    _player.pause();
                                  }
                                  setState(() => _isPlaying = newIsPlaying);
                                  _updateRoomState(
                                    isPlaying: newIsPlaying,
                                    position: _player.position,
                                  );
                                } else {
                                  _playSong(song);
                                }
                              },
                            );
                          },
                        );
                      }
                    ),
          ),
          
          // Playback controls
          if (_currentSongId != null)
            Container(
              padding: const EdgeInsets.fromLTRB(16.0, 8.0, 16.0, 16.0),
              color: Colors.grey.shade900,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  StreamBuilder<Duration>(
                    stream: _player.positionStream,
                    builder: (context, snapshot) {
                      final position = snapshot.data ?? Duration.zero;
                      final duration = _player.duration ?? Duration.zero;
                      
                      String format(Duration d) {
                        final min = d.inMinutes;
                        final sec = (d.inSeconds % 60).toString().padLeft(2, '0');
                        return '$min:$sec';
                      }
                      
                      // Fix: If duration hasn't loaded yet, maxVal should at least match the current position to prevent overflow
                      double maxVal = math.max(duration.inSeconds.toDouble(), position.inSeconds.toDouble());
                      if (maxVal <= 0.0) maxVal = 1.0;
                      double currentVal = position.inSeconds.toDouble().clamp(0.0, maxVal);

                      return Row(
                        children: [
                          Text(format(position), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                          Expanded(
                            child: Slider(
                              activeColor: Colors.white,
                              inactiveColor: Colors.white24,
                              value: currentVal,
                              max: maxVal,
                              onChanged: (val) {
                                final newPos = Duration(seconds: val.toInt());
                                _player.seek(newPos);
                                _updateRoomState(isPlaying: _isPlaying, position: newPos);
                              },
                            ),
                          ),
                          Text(format(duration), style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      );
                    },
                  ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          iconSize: 48,
                          icon: Icon(_isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white),
                          onPressed: () {
                            // Play/Pause locally immediately (optimistic UI update)
                            final newIsPlaying = !_isPlaying;
                            setState(() => _isPlaying = newIsPlaying);
                            
                            if (newIsPlaying) {
                              _player.play();
                            } else {
                              _player.pause();
                            }
                            
                            // Broadcast state
                            _updateRoomState(
                              isPlaying: newIsPlaying,
                              position: _player.position,
                            );
                          },
                        ),
                      ],
                    ),
                ],
              ),
            )
        ],
      ),
    );
  }
}
