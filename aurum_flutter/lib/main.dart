// Aurum · 液态玻璃音乐播放器（Flutter 移植版）。
// 入口：创建播放引擎与全局状态 → MaterialApp → HomePage。
import 'package:flutter/material.dart';

import 'audio/soloud_engine.dart';
import 'state/app_state.dart';
import 'theme/tokens.dart';
import 'ui/home_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final app = AppState(engine: SoloudEngine());
  runApp(AurumApp(app: app));
}

class AurumApp extends StatelessWidget {
  const AurumApp({super.key, required this.app});

  final AppState app;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Aurum · 液态玻璃音乐播放器',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        fontFamily: kFontFamily,
        scaffoldBackgroundColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
      ),
      home: HomePage(app: app),
    );
  }
}
