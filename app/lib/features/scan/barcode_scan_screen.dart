import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../core/router.dart';
import '../../data/repositories/food_repository.dart';

class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  final _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.upcA,
      BarcodeFormat.upcE,
      BarcodeFormat.code128,
    ],
  );
  bool _handling = false;
  String _lastMiss = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final code = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((v) => v != null && v.isNotEmpty, orElse: () => null);
    if (code == null) return;
    _handling = true;
    final repo = context.read<FoodRepository>();
    final food = await repo.byBarcode(code);
    if (!mounted) return;
    if (food != null) {
      await _controller.stop();
      if (!mounted) return;
      context.pushReplacement(Routes.foodPath(food.id));
      return;
    }
    setState(() => _lastMiss = code);
    // Let the user try again rather than locking the scanner on one miss.
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _handling = false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan barcode'),
        actions: [
          IconButton(
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
          IconButton(
            icon: const Icon(Icons.cameraswitch_outlined),
            onPressed: () => _controller.switchCamera(),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 260,
              height: 160,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          Positioned(
            left: 16,
            right: 16,
            bottom: 24,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _lastMiss.isEmpty
                          ? 'Point the camera at a packaged food barcode.'
                          : 'No match for $_lastMiss in the offline database.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    if (_lastMiss.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Text(
                        'Packaged products come from Open Food Facts and are '
                        'refreshed with the weekly database update.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.labelSmall,
                      ),
                      const SizedBox(height: 10),
                      OutlinedButton(
                        onPressed: () => context
                            .pushReplacement('${Routes.search}?q=$_lastMiss'),
                        child: const Text('Search by name instead'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
