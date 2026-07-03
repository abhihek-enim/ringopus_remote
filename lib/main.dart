import 'package:flutter/material.dart';

import 'producer_home_page.dart';
import 'src/rust/frb_generated.dart';
import 'theme.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const RingopusProducerApp());
}

class RingopusProducerApp extends StatelessWidget {
  const RingopusProducerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ringopus Remote Producer',
      theme: buildAppTheme(),
      home: const ProducerHomePage(),
    );
  }
}
