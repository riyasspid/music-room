import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
      type: FileType.audio,
      withData: true, // Needed for web support
    );

    if (result != null && result.files.isNotEmpty) {
      final fileData = result.files.first.bytes;
      final fileName = result.files.first.name;
      
      if (fileData == null && result.files.first.path != null) {
        // Fallback for some platforms if withData fails but path is available
        // Note: For full web support, withData usually provides bytes.
      }
      
      setState(() {
        _isUploading = true;
        _uploadStatus = 'Uploading $fileName...';
      });

      try {
        final ext = fileName.split('.').last;
        final storagePath = '${const Uuid().v4()}.$ext';

        // Upload binary to Supabase Storage (works across Web, iOS, Android)
        if (fileData != null) {
          await Supabase.instance.client.storage.from('songs').uploadBinary(
            storagePath,
            fileData,
          );
        } else {
          throw Exception('No file data available. Please try again.');
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
      appBar: AppBar(title: const Text('Upload Song')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            ElevatedButton(
              onPressed: _isUploading ? null : _pickAndUpload,
              child: const Text('Pick Audio File'),
            ),
            const SizedBox(height: 24),
            Text(_uploadStatus, style: const TextStyle(color: Colors.white)),
            if (_isUploading) const Padding(
              padding: EdgeInsets.all(16.0),
              child: CircularProgressIndicator(color: Colors.white),
            )
          ],
        ),
      ),
    );
  }
}
