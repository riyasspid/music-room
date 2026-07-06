import 'dart:ui';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final AudioPlayer _player = AudioPlayer();
  final _supabase = Supabase.instance.client;
  
  List<dynamic> _songs = [];
  bool _isLoadingSongs = true;
  String _searchQuery = '';
  
  String? _currentSongId;
  bool _isPlaying = false;

  final List<Map<String, dynamic>> _queue = [];
  ConcatenatingAudioSource? _playlist;
  
  @override
  void initState() {
    super.initState();
    _fetchSongs();
    _setupAudioListeners();
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _fetchSongs() async {
    try {
      final data = await _supabase.from('songs').select().order('created_at');
      if (mounted) {
        setState(() {
          _songs = data;
          _isLoadingSongs = false;
        });
      }
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
    });

    _player.currentIndexStream.listen((index) async {
      if (index != null && index > 0 && _playlist != null) {
        if (index < _playlist!.children.length) {
          final currentSource = _playlist!.children[index] as UriAudioSource;
          final nextMediaItem = currentSource.tag as MediaItem;
          final newSongId = nextMediaItem.id;
          
          if (mounted) {
            setState(() {
              _currentSongId = newSongId;
              if (_queue.isNotEmpty && _queue[0]['id'] == newSongId) {
                _queue.removeAt(0);
              }
            });
          }
        }
      }
    });
  }

  AudioSource _createAudioSource(Map<String, dynamic> song) {
    final uri = Uri.parse(song['url']);
    final tag = MediaItem(id: song['id'], album: 'Library', title: song['title'], artist: song['artist'] ?? 'Unknown');
    if (kIsWeb) {
      return AudioSource.uri(uri, tag: tag);
    } else {
      return LockCachingAudioSource(uri, tag: tag);
    }
  }

  Future<void> _playSong(Map<String, dynamic> song) async {
    setState(() {
      _currentSongId = song['id'];
      _isPlaying = true;
    });
    
    try {
      final sources = <AudioSource>[];
      
      // 1. Add current song
      sources.add(_createAudioSource(song));
      
      // 2. Add existing queue
      for (var qSong in _queue) {
        sources.add(_createAudioSource(qSong));
      }
      
      // 3. Add remaining library songs for continuous playback
      if (_songs.isNotEmpty) {
        final cIdx = _songs.indexWhere((s) => s['id'] == song['id']);
        if (cIdx != -1) {
          for (int i = cIdx + 1; i < _songs.length; i++) {
            sources.add(_createAudioSource(_songs[i]));
          }
        }
      }
      
      _playlist = ConcatenatingAudioSource(children: sources);
      await _player.setAudioSource(_playlist!);
      
      _player.play().catchError((e) {
        debugPrint('Autoplay blocked during song switch: $e');
      });
    } catch (e) {
      debugPrint('Error loading audio source: $e');
    }
  }

  void _addToQueue(Map<String, dynamic> song) {
    setState(() {
      _queue.add(song);
    });
    
    // If a playlist is active, insert the song dynamically
    if (_playlist != null && _player.currentIndex != null) {
      // Insert after current song + existing queue items
      final insertIndex = _player.currentIndex! + _queue.length;
      if (insertIndex <= _playlist!.children.length) {
        _playlist!.insert(insertIndex, _createAudioSource(song));
      }
    }
    
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
      // 1. Clear foreign key references in rooms table just in case
      await _supabase.from('rooms').update({'current_song_id': null}).eq('current_song_id', song['id']);
      
      // 2. Delete from database
      await _supabase.from('songs').delete().eq('id', song['id']);
      
      // 3. Delete from storage
      final path = Uri.parse(song['url']).pathSegments.last;
      await _supabase.storage.from('songs').remove([path]);
      
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
    final filteredSongs = _searchQuery.isEmpty 
        ? _songs 
        : _songs.where((s) => s['title'].toString().toLowerCase().contains(_searchQuery)).toList();

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
              title: const Text('LIBRARY', style: TextStyle(letterSpacing: 1.5, fontWeight: FontWeight.bold, fontSize: 16)),
              centerTitle: true,
            ),
          ),
        ),
      ),
      body: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF171717),
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
                  : filteredSongs.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.library_music_rounded, size: 64, color: Colors.white.withOpacity(0.2)),
                              const SizedBox(height: 16),
                              Text('No songs found.', style: TextStyle(color: Colors.white.withOpacity(0.5))),
                            ],
                          ),
                        )
                      : ListView.builder(
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
                                child: Material(
                                  color: Colors.transparent,
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
                                        if (_isPlaying) {
                                          _player.pause();
                                        } else {
                                          _player.play();
                                        }
                                      } else {
                                        _playSong(song as Map<String, dynamic>);
                                      }
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
              ),
              
              // Bottom playback panel
              if (_currentSongId != null)
                Builder(
                  builder: (context) {
                    final currentSong = _songs.firstWhere(
                      (s) => s['id'] == _currentSongId, 
                      orElse: () => <String, dynamic>{},
                    );
                    
                    return Container(
                      padding: const EdgeInsets.fromLTRB(16.0, 12.0, 16.0, 24.0),
                      decoration: const BoxDecoration(
                        color: Color(0xFF010002), // Spotify accent/overlay
                        border: Border(top: BorderSide(color: Color(0xFF282828))),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (currentSong.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8.0),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          currentSong['title'] ?? 'Unknown',
                                          style: const TextStyle(
                                            color: Color(0xFFFEFEFE),
                                            fontSize: 15,
                                            fontWeight: FontWeight.w500,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (currentSong['artist'] != null)
                                          Text(
                                            currentSong['artist'],
                                            style: const TextStyle(
                                              color: Color(0xFFA6A6A6),
                                              fontSize: 13,
                                            ),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
                                  Text(format(position), style: const TextStyle(color: Color(0xFFA6A6A6), fontSize: 12, fontWeight: FontWeight.w500)),
                                  Expanded(
                                    child: SliderTheme(
                                      data: SliderTheme.of(context).copyWith(
                                        trackHeight: 4,
                                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                                        overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                                        activeTrackColor: const Color(0xFF1DB954),
                                        inactiveTrackColor: const Color(0xFF282828),
                                        thumbColor: const Color(0xFF1DB954),
                                      ),
                                      child: Slider(
                                        value: currentVal,
                                        max: maxVal,
                                        onChanged: (val) {
                                          final newPos = Duration(seconds: val.toInt());
                                          _player.seek(newPos);
                                        },
                                      ),
                                    ),
                                  ),
                                  Text(format(duration), style: const TextStyle(color: Color(0xFFA6A6A6), fontSize: 12, fontWeight: FontWeight.w500)),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 8),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const SizedBox(width: 48), // Spacer
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 36),
                                    onPressed: () {
                                      _player.seekToPrevious();
                                    },
                                  ),
                                  const SizedBox(width: 16),
                                  Container(
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: Color(0xFF1DB954),
                                    ),
                                    child: IconButton(
                                      iconSize: 40,
                                      padding: const EdgeInsets.all(12),
                                      icon: Icon(
                                        _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, 
                                        color: const Color(0xFF171717),
                                      ),
                                      onPressed: () {
                                        if (_isPlaying) {
                                          _player.pause();
                                        } else {
                                          _player.play();
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 16),
                                  IconButton(
                                    icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 36),
                                    onPressed: () {
                                      _player.seekToNext();
                                    },
                                  ),
                                ],
                              ),
                              IconButton(
                                icon: const Icon(Icons.queue_music_rounded, color: Color(0xFFA6A6A6)),
                                tooltip: 'Queue',
                                onPressed: _showQueueBottomSheet,
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                )
            ],
          ),
        ),
      ),
    );
  }
}
