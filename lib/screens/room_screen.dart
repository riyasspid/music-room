import 'dart:async';
import 'dart:ui';
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
  
  // Queue & Autoplay
  bool _isAutoPlay = true;
  final List<Map<String, dynamic>> _queue = [];
  bool _handlingCompletion = false;

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
        _handleSongCompletion();
      }
    });

    _player.positionStream.listen((pos) {
      // We don't broadcast position on every tick to avoid spamming the DB,
      // but we could sync occasionally or when scrubbing.
      _position = pos;
    });
  }

  Future<void> _handleSongCompletion() async {
    if (_handlingCompletion) return;
    _handlingCompletion = true;
    
    try {
      if (_queue.isNotEmpty) {
        final nextSong = _queue.removeAt(0);
        await _playSong(nextSong);
        if (mounted) setState(() {});
      } else if (_isAutoPlay && _songs.isNotEmpty && _currentSongId != null) {
        final currentIndex = _songs.indexWhere((s) => s['id'] == _currentSongId);
        if (currentIndex != -1 && currentIndex + 1 < _songs.length) {
          final nextSong = _songs[currentIndex + 1];
          await _playSong(nextSong);
        } else {
          await _updateRoomState(isPlaying: false, position: Duration.zero);
        }
      } else {
        await _updateRoomState(isPlaying: false, position: Duration.zero);
      }
    } finally {
      // Debounce completion logic
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) {
          _handlingCompletion = false;
        }
      });
    }
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

  void _addToQueue(Map<String, dynamic> song) {
    setState(() {
      _queue.add(song);
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${song['title']} added to queue')),
    );
  }

  void _showQueueBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(32)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
            child: Container(
              color: const Color(0xFF14142B).withOpacity(0.7),
              child: StatefulBuilder(
                builder: (context, setModalState) {
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12.0),
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white24,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Up Next',
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white, letterSpacing: 1),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.primary.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '${_queue.length} songs',
                                style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(color: Colors.white10, height: 1),
                      Expanded(
                        child: _queue.isEmpty
                            ? const Center(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.queue_music, size: 48, color: Colors.white24),
                                    SizedBox(height: 16),
                                    Text(
                                      'Queue is empty',
                                      style: TextStyle(color: Colors.white54, fontSize: 16),
                                    ),
                                  ],
                                ),
                              )
                            : ReorderableListView.builder(
                                padding: const EdgeInsets.all(8),
                                itemCount: _queue.length,
                                onReorder: (oldIndex, newIndex) {
                                  setModalState(() {
                                    setState(() {
                                      if (oldIndex < newIndex) {
                                        newIndex -= 1;
                                      }
                                      final item = _queue.removeAt(oldIndex);
                                      _queue.insert(newIndex, item);
                                    });
                                  });
                                },
                                itemBuilder: (context, index) {
                                  final song = _queue[index];
                                  return Card(
                                    key: ValueKey('${song['id']}_$index'),
                                    color: Colors.white.withOpacity(0.05),
                                    elevation: 0,
                                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    child: ListTile(
                                      leading: const Icon(Icons.drag_handle, color: Colors.white38),
                                      title: Text(
                                        song['title'],
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w500),
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.close, color: Colors.white38),
                                        onPressed: () {
                                          setModalState(() {
                                            setState(() {
                                              _queue.removeAt(index);
                                            });
                                          });
                                        },
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                }
              ),
            ),
          ),
        );
      },
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
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: ClipRRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
            child: AppBar(
              backgroundColor: const Color(0xFF09090E).withOpacity(0.5),
              elevation: 0,
              title: Text('ROOM: ${widget.roomId}', style: const TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.bold, fontSize: 16)),
              centerTitle: true,
              actions: [
                Row(
                  children: [
                    const Text('AUTO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white54)),
                    Switch(
                      value: _isAutoPlay,
                      onChanged: (val) {
                        setState(() => _isAutoPlay = val);
                      },
                      activeColor: Theme.of(context).colorScheme.primary,
                      inactiveTrackColor: Colors.white10,
                    ),
                  ],
                ),
                IconButton(
                  icon: const Icon(Icons.copy_rounded, size: 20),
                  tooltip: 'Copy Room ID',
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: widget.roomId));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Room ID copied')));
                  },
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF14142B), Color(0xFF09090E)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.05),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: TextField(
                    decoration: InputDecoration(
                      hintText: 'Search for a song...',
                      hintStyle: TextStyle(color: Colors.white.withOpacity(0.4)),
                      prefixIcon: Icon(Icons.search_rounded, color: Colors.white.withOpacity(0.4)),
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value.toLowerCase();
                      });
                    },
                  ),
                ),
              ),
              Expanded(
                child: _isLoadingSongs
                  ? const Center(child: CircularProgressIndicator())
                  : _songs.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.music_note_rounded, size: 64, color: Colors.white.withOpacity(0.2)),
                              const SizedBox(height: 16),
                              Text('No songs in the room yet.', style: TextStyle(color: Colors.white.withOpacity(0.5))),
                            ],
                          ),
                        )
                      : Builder(
                          builder: (context) {
                            final filteredSongs = _searchQuery.isEmpty 
                                ? _songs 
                                : _songs.where((s) => s['title'].toString().toLowerCase().contains(_searchQuery)).toList();
                            
                            if (filteredSongs.isEmpty) {
                              return const Center(child: Text('No songs match your search.', style: TextStyle(color: Colors.white54)));
                            }
                            
                            return ListView.builder(
                              padding: const EdgeInsets.only(bottom: 24, top: 8),
                              itemCount: filteredSongs.length,
                              itemBuilder: (context, index) {
                                final song = filteredSongs[index];
                                final isCurrent = song['id'] == _currentSongId;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                                  child: AnimatedContainer(
                                    duration: const Duration(milliseconds: 300),
                                    decoration: BoxDecoration(
                                      color: isCurrent ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : Colors.white.withOpacity(0.03),
                                      borderRadius: BorderRadius.circular(16),
                                      border: Border.all(
                                        color: isCurrent ? Theme.of(context).colorScheme.primary.withOpacity(0.3) : Colors.transparent,
                                      ),
                                    ),
                                    child: ListTile(
                                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                                      leading: CircleAvatar(
                                        backgroundColor: isCurrent ? Theme.of(context).colorScheme.primary : Colors.white10,
                                        child: Icon(
                                          isCurrent ? Icons.graphic_eq_rounded : Icons.music_note_rounded,
                                          color: isCurrent ? Colors.black : Colors.white54,
                                        ),
                                      ),
                                      title: Text(
                                        song['title'], 
                                        maxLines: 1, 
                                        overflow: TextOverflow.ellipsis, 
                                        style: TextStyle(
                                          color: isCurrent ? Colors.white : Colors.white70,
                                          fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                        )
                                      ),
                                      trailing: PopupMenuButton<String>(
                                        icon: const Icon(Icons.more_vert_rounded, color: Colors.white54),
                                        color: const Color(0xFF14142B),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                        onSelected: (value) {
                                          if (value == 'delete') {
                                            _deleteSong(song);
                                          } else if (value == 'queue') {
                                            _addToQueue(song);
                                          }
                                        },
                                        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                                          const PopupMenuItem<String>(
                                            value: 'queue',
                                            child: Row(
                                              children: [
                                                Icon(Icons.queue_music_rounded, color: Colors.white70, size: 20),
                                                SizedBox(width: 12),
                                                Text('Add to Queue'),
                                              ],
                                            ),
                                          ),
                                          const PopupMenuItem<String>(
                                            value: 'delete',
                                            child: Row(
                                              children: [
                                                Icon(Icons.delete_rounded, color: Colors.redAccent, size: 20),
                                                SizedBox(width: 12),
                                                Text('Delete', style: TextStyle(color: Colors.redAccent)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      onTap: () {
                                        if (isCurrent) {
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
                                    ),
                                  ),
                                );
                              },
                            );
                          }
                        ),
              ),
              
              // Glassmorphism Playback controls
              if (_currentSongId != null)
                ClipRRect(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 24.0),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.5),
                        border: Border(top: BorderSide(color: Colors.white.withOpacity(0.1))),
                      ),
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
                              
                              double maxVal = math.max(duration.inSeconds.toDouble(), position.inSeconds.toDouble());
                              if (maxVal <= 0.0) maxVal = 1.0;
                              double currentVal = position.inSeconds.toDouble().clamp(0.0, maxVal);
        
                              return Row(
                                children: [
                                  Text(format(position), style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500)),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 4,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                        activeTrackColor: Theme.of(context).colorScheme.primary,
                                        inactiveTrackColor: Colors.white10,
                                        thumbColor: Colors.white,
                                      ),
                                      child: Slider(
                                        value: currentVal,
                                        max: maxVal,
                                        onChanged: (val) {
                                          final newPos = Duration(seconds: val.toInt());
                                          _player.seek(newPos);
                                          _updateRoomState(isPlaying: _isPlaying, position: newPos);
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(format(duration), style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.w500)),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const SizedBox(width: 48), // Spacer
                              Container(
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: Colors.white,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.white.withOpacity(0.2),
                                      blurRadius: 20,
                                      spreadRadius: 2,
                                    )
                                  ]
                                ),
                                child: IconButton(
                                  iconSize: 40,
                                  padding: const EdgeInsets.all(12),
                                  icon: Icon(
                                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, 
                                    color: Colors.black,
                                  ),
                                  onPressed: () {
                                    final newIsPlaying = !_isPlaying;
                                    setState(() => _isPlaying = newIsPlaying);
                                    
                                    if (newIsPlaying) {
                                      _player.play();
                                    } else {
                                      _player.pause();
                                    }
                                    
                                    _updateRoomState(
                                      isPlaying: newIsPlaying,
                                      position: _player.position,
                                    );
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.queue_music_rounded, color: Colors.white70),
                                tooltip: 'Queue',
                                onPressed: _showQueueBottomSheet,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
            ],
          ),
        ),
      ),
    );
  }
}
