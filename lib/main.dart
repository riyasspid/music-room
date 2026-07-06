import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:google_fonts/google_fonts.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize background audio playback ONLY on native platforms
  if (!kIsWeb) {
    await JustAudioBackground.init(
      androidNotificationChannelId: 'com.ryanheise.bg_demo.channel.audio',
      androidNotificationChannelName: 'Audio playback',
      androidNotificationOngoing: true,
    );
  }

  // TODO: Replace these with your actual Supabase project URL and anon key
  const supabaseUrl = 'https://hvivokcplgcthaubldes.supabase.co';
  const supabaseAnonKey = 'sb_publishable_huVf1RyPeyH885OeTXWttg_iabhzheT';


  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
  );

  runApp(const MusicRoomApp());
}

class MusicRoomApp extends StatelessWidget {
  const MusicRoomApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Music Room',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF171717),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent,
          foregroundColor: Colors.white,
          elevation: 0,
          centerTitle: true,
        ),
        textTheme: GoogleFonts.interTextTheme(Theme.of(context).textTheme).apply(
          bodyColor: const Color(0xFFDBDBDB),
          displayColor: const Color(0xFFDBDBDB),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFFFEFEFE),
            foregroundColor: const Color(0xFF171717),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(24), // Spotify style pill buttons
            ),
            elevation: 0,
          ),
        ),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFEFEFE),
          secondary: Color(0xFFDBDBDB),
          background: Color(0xFF171717),
          surface: Color(0xFF282828),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
