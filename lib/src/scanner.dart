part of '../main.dart';

class BarcodeScannerPage extends StatefulWidget {
  const BarcodeScannerPage({super.key});
  @override
  State<BarcodeScannerPage> createState() => _BarcodeScannerPageState();
}

class _BarcodeScannerPageState extends State<BarcodeScannerPage> {
  bool _returned = false;
  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const WindowsBarcodeEntryPage();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Scanner le produit'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              if (_returned || capture.barcodes.isEmpty) return;
              final value = capture.barcodes.first.rawValue;
              if (value == null || value.isEmpty) return;
              _returned = true;
              Navigator.pop(context, value);
            },
          ),
          Center(
            child: Container(
              width: 260,
              height: 150,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          const Positioned(
            left: 30,
            right: 30,
            bottom: 45,
            child: Text(
              'Placez le code-barres dans le cadre',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ContinuousBarcodeScannerPage extends StatefulWidget {
  const ContinuousBarcodeScannerPage({super.key});

  @override
  State<ContinuousBarcodeScannerPage> createState() =>
      _ContinuousBarcodeScannerPageState();
}

class _ContinuousBarcodeScannerPageState
    extends State<ContinuousBarcodeScannerPage> {
  final scannedCodes = <String>[];
  final lastDetection = <String, DateTime>{};

  void _detect(BarcodeCapture capture) {
    final now = DateTime.now();
    var changed = false;
    for (final barcode in capture.barcodes) {
      final code = barcode.rawValue;
      if (code == null || code.isEmpty) continue;
      final previous = lastDetection[code];
      if (previous != null && now.difference(previous).inMilliseconds < 1200) {
        continue;
      }
      lastDetection[code] = now;
      scannedCodes.add(code);
      changed = true;
    }
    if (changed && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) return const WindowsContinuousBarcodeEntryPage();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Vente rapide - scan continu'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          TextButton.icon(
            onPressed: scannedCodes.isEmpty
                ? null
                : () => Navigator.pop(context, scannedCodes),
            icon: const Icon(Icons.check, color: Colors.white),
            label: const Text(
              'Terminer',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(onDetect: _detect),
          Center(
            child: Container(
              width: 275,
              height: 165,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(18),
              ),
            ),
          ),
          Positioned(
            left: 20,
            right: 20,
            bottom: 35,
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black87,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                children: [
                  Text(
                    '${scannedCodes.length} produit(s) scanné(s)',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Scannez les produits à la suite, puis touchez Terminer.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class WindowsCameraPreview extends StatefulWidget {
  const WindowsCameraPreview({super.key});

  @override
  State<WindowsCameraPreview> createState() => _WindowsCameraPreviewState();
}

class _WindowsCameraPreviewState extends State<WindowsCameraPreview> {
  CameraController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Aucune webcam détectée.');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller != null && controller.value.isInitialized) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: AspectRatio(
          aspectRatio: controller.value.aspectRatio,
          child: CameraPreview(controller),
        ),
      );
    }
    return Container(
      height: 230,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFF17231D),
        borderRadius: BorderRadius.circular(18),
      ),
      child: _error == null
          ? const CircularProgressIndicator(color: Colors.white)
          : Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Webcam indisponible. Vérifiez les autorisations de caméra dans les Paramètres Windows.\n\n$_error',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white),
              ),
            ),
    );
  }
}

class WindowsBarcodeEntryPage extends StatefulWidget {
  const WindowsBarcodeEntryPage({super.key});

  @override
  State<WindowsBarcodeEntryPage> createState() =>
      _WindowsBarcodeEntryPageState();
}

class _WindowsBarcodeEntryPageState extends State<WindowsBarcodeEntryPage> {
  final _code = TextEditingController();

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _confirm() {
    final value = _code.text.trim();
    if (value.isNotEmpty) Navigator.pop(context, value);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scanner le produit')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const WindowsCameraPreview(),
            const SizedBox(height: 20),
            const Text(
              'Webcam activée',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'La lecture automatique des codes-barres n’est pas prise en charge par Windows. Saisissez le code ou utilisez un lecteur USB : il remplit ce champ automatiquement.',
            ),
            const SizedBox(height: 18),
            TextField(
              controller: _code,
              autofocus: true,
              onSubmitted: (_) => _confirm(),
              decoration: const InputDecoration(
                labelText: 'Code-barres',
                prefixIcon: Icon(Icons.qr_code_rounded),
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: _confirm,
              icon: const Icon(Icons.check),
              label: const Text('Utiliser ce code'),
            ),
          ],
        ),
      ),
    ),
  );
}

class WindowsContinuousBarcodeEntryPage extends StatefulWidget {
  const WindowsContinuousBarcodeEntryPage({super.key});

  @override
  State<WindowsContinuousBarcodeEntryPage> createState() =>
      _WindowsContinuousBarcodeEntryPageState();
}

class _WindowsContinuousBarcodeEntryPageState
    extends State<WindowsContinuousBarcodeEntryPage> {
  final _code = TextEditingController();
  final _codes = <String>[];

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  void _add() {
    final value = _code.text.trim();
    if (value.isEmpty) return;
    setState(() {
      _codes.add(value);
      _code.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Vente rapide - saisie des codes'),
      actions: [
        TextButton.icon(
          onPressed: _codes.isEmpty
              ? null
              : () => Navigator.pop(context, _codes),
          icon: const Icon(Icons.check),
          label: const Text('Terminer'),
        ),
      ],
    ),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const WindowsCameraPreview(),
            const SizedBox(height: 16),
            Text(
              '${_codes.length} produit(s) ajouté(s)',
              style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            const Text(
              'Utilisez la webcam pour vous guider, puis saisissez le code ou utilisez votre lecteur de code-barres USB.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              autofocus: true,
              onSubmitted: (_) => _add(),
              decoration: InputDecoration(
                labelText: 'Code-barres',
                prefixIcon: const Icon(Icons.qr_code_rounded),
                suffixIcon: IconButton(
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                ),
              ),
            ),
            if (_codes.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _codes
                    .map((code) => Chip(label: Text(code)))
                    .toList(),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class DesktopCameraCapturePage extends StatefulWidget {
  const DesktopCameraCapturePage({super.key});

  @override
  State<DesktopCameraCapturePage> createState() =>
      _DesktopCameraCapturePageState();
}

class _DesktopCameraCapturePageState extends State<DesktopCameraCapturePage> {
  CameraController? _controller;
  String? _error;
  bool _takingPhoto = false;

  @override
  void initState() {
    super.initState();
    _startCamera();
  }

  Future<void> _startCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw StateError('Aucune webcam détectée.');
      final controller = CameraController(
        cameras.first,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _takePhoto() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _takingPhoto)
      return;
    setState(() => _takingPhoto = true);
    try {
      final photo = await controller.takePicture();
      if (mounted) Navigator.pop(context, photo.path);
    } catch (error) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossible de prendre la photo : $error')),
        );
    } finally {
      if (mounted) setState(() => _takingPhoto = false);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Prendre une photo')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: controller != null && controller.value.isInitialized
              ? AspectRatio(
                  aspectRatio: controller.value.aspectRatio,
                  child: CameraPreview(controller),
                )
              : Text(
                  _error == null
                      ? 'Activation de la webcam…'
                      : 'Webcam indisponible.\n\n$_error',
                  textAlign: TextAlign.center,
                ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _takingPhoto ? null : _takePhoto,
        icon: const Icon(Icons.camera_alt_outlined),
        label: Text(_takingPhoto ? 'Capture…' : 'Prendre la photo'),
      ),
    );
  }
}
