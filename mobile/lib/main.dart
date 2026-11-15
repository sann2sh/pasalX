import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(
    const ProviderScope(
      child: PasalXApp(),
    ),
  );
}

class PasalXApp extends StatelessWidget {
  const PasalXApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PasalX',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF215542)),
      ),
      home: const Scaffold(
        body: Center(
          child: Text('PasalX Mobile POS & Inventory'),
        ),
      ),
    );
  }
}
