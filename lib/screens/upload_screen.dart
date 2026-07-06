import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'dart:io';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  bool _isUploading = false;
  String _uploadStatus = '';

  Future<void> _pickAndUpload() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg', 'wma'],
      withData: kIsWeb, // Needed for web support, but avoid on mobile to prevent OOM
    );

    if (result != null && result.files.isNotEmpty) {
      final file = result.files.first;
      final fileName = file.name;
      
      setState(() {
        _isUploading = true;
        _uploadStatus = 'Uploading $fileName...';
      });

      try {
        final ext = fileName.split('.').last;
        final storagePath = '${const Uuid().v4()}.$ext';

        // Upload to Supabase Storage
        if (kIsWeb) {
          final fileData = file.bytes;
          if (fileData == null) {
            throw Exception('No file data available. Please try again.');
          }
          await Supabase.instance.client.storage.from('songs').uploadBinary(
            storagePath,
            fileData,
          );
        } else {
          final filePath = file.path;
          if (filePath == null) {
            throw Exception('File path not found. Please try again.');
          }
          await Supabase.instance.client.storage.from('songs').upload(
            storagePath,
            File(filePath),
          );
        }

        // Get public URL
        final publicUrl = Supabase.instance.client.storage.from('songs').getPublicUrl(storagePath);

        // Insert into songs table
        await Supabase.instance.client.from('songs').insert({
          'title': fileName,
          'url': publicUrl,
        });

        setState(() {
          _uploadStatus = 'Upload successful!';
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Song uploaded successfully.')));
          Navigator.pop(context);
        }
      } catch (e) {
        setState(() {
          _uploadStatus = 'Error: $e';
        });
      } finally {
        setState(() {
          _isUploading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('UPLOAD SONG', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 2)),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF09090E),
              Color(0xFF14142B),
              Color(0xFF09090E),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  GestureDetector(
                    onTap: _isUploading ? null : _pickAndUpload,
                    child: Container(
                      width: double.infinity,
                      height: 250,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.05),
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary.withOpacity(_isUploading ? 0.2 : 0.5),
                          width: 2,
                        ),
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_isUploading)
                            const CircularProgressIndicator()
                          else
                            Icon(
                              Icons.cloud_upload_rounded,
                              size: 80,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          const SizedBox(height: 24),
                          Text(
                            _isUploading ? 'Uploading...' : 'Tap to Browse Audio Files',
                            style: TextStyle(
                              color: _isUploading ? Colors.white54 : Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (!_isUploading)
                            Padding(
                              padding: const EdgeInsets.only(top: 8.0),
                              child: Text(
                                'MP3, WAV, M4A, OGG supported',
                                style: TextStyle(color: Colors.white.withOpacity(0.4), fontSize: 12),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (_uploadStatus.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      decoration: BoxDecoration(
                        color: _uploadStatus.contains('Error') 
                            ? Colors.redAccent.withOpacity(0.1) 
                            : Theme.of(context).colorScheme.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _uploadStatus,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: _uploadStatus.contains('Error') 
                              ? Colors.redAccent 
                              : Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
