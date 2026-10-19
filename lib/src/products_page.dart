part of '../main.dart';

class ProductsPage extends StatelessWidget {
  const ProductsPage({
    super.key,
    required this.products,
    required this.onChanged,
  });
  final List<Product> products;
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => Column(
    children: [
      const PageHeader('Produits', 'Gérez vos articles et votre stock'),
      Expanded(
        child: _ProductBrowser(
          products: products,
          onOpen: (p) => _addProduct(context, existing: p),
          actions: [
            const SizedBox(width: 10),
            IconButton.filledTonal(
              tooltip: 'Lire le nom avec la caméra',
              onPressed: () async {
                final text = await _scanProductName(context);
                if (text != null && context.mounted) {
                  _addProduct(context, initialName: text);
                }
              },
              icon: const Icon(Icons.document_scanner_outlined),
            ),
            const SizedBox(width: 8),
            IconButton.filledTonal(
              tooltip: 'Scanner un code-barres',
              onPressed: () async {
                final code = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(builder: (_) => const BarcodeScannerPage()),
                );
                if (code != null && context.mounted) {
                  _addProduct(context, barcode: code);
                }
              },
              icon: const Icon(Icons.qr_code_scanner_rounded),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: () => _addProduct(context),
              icon: const Icon(Icons.add),
            ),
            PopupMenuButton<String>(
              tooltip: 'Import, export et inventaire',
              icon: const Icon(Icons.upload_file),
              onSelected: (value) {
                switch (value) {
                  case 'template':
                    _saveImportTemplate(context);
                    break;
                  case 'export':
                    _exportProducts(context);
                    break;
                  case 'inventory':
                    _inventory(context);
                    break;
                  case 'restock':
                    _inventory(context, restock: true);
                    break;
                  case 'value':
                    showDialog<void>(
                      context: context,
                      builder: (dialogContext) => AlertDialog(
                        content: SizedBox(
                          width: 560,
                          child: SingleChildScrollView(
                            child: StockValueCard(
                              value: StockValue(
                                products.map(
                                  (p) => (
                                    stock: p.stock,
                                    price: p.price,
                                    purchasePrice: p.purchasePrice,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(dialogContext),
                            child: const Text('Fermer'),
                          ),
                        ],
                      ),
                    );
                    break;
                  default:
                    _importProducts(context);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'import',
                  child: Text('Importer un fichier Excel'),
                ),
                PopupMenuItem(
                  value: 'template',
                  child: Text('Télécharger le modèle Excel'),
                ),
                PopupMenuItem(
                  value: 'export',
                  child: Text('Exporter les produits Excel'),
                ),
                PopupMenuItem(
                  value: 'inventory',
                  child: Text('Faire un inventaire'),
                ),
                PopupMenuItem(
                  value: 'restock',
                  child: Text('Ajouter du stock aux articles'),
                ),
                PopupMenuItem(
                  value: 'value',
                  child: Text('Voir la valeur de la boutique'),
                ),
              ],
            ),
          ],
        ),
      ),
    ],
  );

  Future<String?> _scanProductName(BuildContext context) async {
    if (Platform.isWindows) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'La lecture automatique de texte est disponible sur mobile. Ajoutez une photo du produit depuis le formulaire Windows.',
          ),
        ),
      );
      return null;
    }
    final image = await ImagePicker().pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (image == null) return null;
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(
        InputImage.fromFilePath(image.path),
      );
      final lines = result.blocks
          .expand((block) => block.lines)
          .map((line) => line.text.trim())
          .where((line) => line.length > 2)
          .toList();
      if (lines.isEmpty && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Aucun nom lisible détecté.')),
        );
      }
      return lines.isEmpty ? null : lines.first;
    } finally {
      await recognizer.close();
    }
  }

  void _addProduct(
    BuildContext context, {
    String barcode = '',
    String initialName = '',
    Product? existing,
  }) {
    final name = TextEditingController(text: existing?.name ?? initialName);
    final price = TextEditingController(text: existing?.price.toString() ?? '');
    final purchasePrice = TextEditingController(
      text: existing?.purchasePrice?.toString() ?? '',
    );
    String? purchasePriceError;
    final stock = TextEditingController(text: existing?.stock.toString() ?? '');
    final barcodeController = TextEditingController(
      text: existing?.barcode ?? barcode,
    );
    var imagePath = existing?.imagePath ?? '';
    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            existing == null ? 'Nouveau produit' : 'Modifier le produit',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(
                    labelText: 'Nom du produit',
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      final path = await selectProductPhoto();
                      if (path != null && dialogContext.mounted)
                        setDialogState(() => imagePath = path);
                    } catch (_) {
                      if (dialogContext.mounted)
                        ScaffoldMessenger.of(dialogContext).showSnackBar(
                          const SnackBar(
                            content: Text(
                              'Photo illisible. Choisissez une image JPG, PNG ou WebP de moins de 10 Mo.',
                            ),
                          ),
                        );
                    }
                  },
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Choisir une photo dans les fichiers'),
                ),
                if (imagePath.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Image.file(
                      File(imagePath),
                      height: 90,
                      width: 140,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) =>
                          const Text('Photo indisponible'),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: () async {
                    if (Platform.isWindows) {
                      final path = await Navigator.push<String>(
                        dialogContext,
                        MaterialPageRoute(
                          builder: (_) => const DesktopCameraCapturePage(),
                        ),
                      );
                      if (path != null && dialogContext.mounted) {
                        setDialogState(() => imagePath = path);
                      }
                      return;
                    }
                    final source = await showModalBottomSheet<ImageSource>(
                      context: dialogContext,
                      builder: (context) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.photo_camera_outlined),
                              title: const Text('Prendre une photo'),
                              onTap: () =>
                                  Navigator.pop(context, ImageSource.camera),
                            ),
                            ListTile(
                              leading: const Icon(Icons.photo_library_outlined),
                              title: const Text('Importer depuis la galerie'),
                              onTap: () =>
                                  Navigator.pop(context, ImageSource.gallery),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (source == null) return;
                    final image = await ImagePicker().pickImage(
                      source: source,
                      imageQuality: 75,
                      maxWidth: 1600,
                    );
                    if (image != null) {
                      setDialogState(() => imagePath = image.path);
                    }
                  },
                  icon: const Icon(Icons.add_a_photo_outlined),
                  label: Text(
                    imagePath.isEmpty
                        ? 'Ajouter une photo'
                        : 'Changer la photo',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Prix de vente'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: purchasePrice,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: 'Prix d’achat (FCFA)',
                    helperText: 'Facultatif • coût unitaire',
                    errorText: purchasePriceError,
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: stock,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Stock initial'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: barcodeController,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: 'Code-barres',
                    hintText: 'Touchez le scanner',
                    prefixIcon: const Icon(Icons.qr_code_rounded),
                    suffixIcon: IconButton(
                      tooltip: 'Scanner le code-barres',
                      onPressed: () async {
                        final code = await Navigator.push<String>(
                          dialogContext,
                          MaterialPageRoute(
                            builder: (_) => const BarcodeScannerPage(),
                          ),
                        );
                        if (code != null && dialogContext.mounted) {
                          barcodeController.text = code;
                          setDialogState(() {});
                        }
                      },
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                final rawPurchasePrice = purchasePrice.text.trim();
                final parsedPurchasePrice = int.tryParse(rawPurchasePrice);
                if (rawPurchasePrice.isNotEmpty &&
                    (parsedPurchasePrice == null || parsedPurchasePrice < 0)) {
                  setDialogState(
                    () => purchasePriceError =
                        'Saisissez un montant entier positif ou nul.',
                  );
                  return;
                }
                if (existing == null) {
                  products.add(
                    Product(
                      name.text.trim(),
                      int.tryParse(price.text) ?? 0,
                      int.tryParse(stock.text) ?? 0,
                      Icons.inventory_2_outlined,
                      barcode: barcodeController.text.trim(),
                      imagePath: imagePath,
                      purchasePrice: parsedPurchasePrice,
                    ),
                  );
                } else {
                  existing.name = name.text.trim();
                  existing.price = int.tryParse(price.text) ?? existing.price;
                  existing.purchasePrice = parsedPurchasePrice;
                  existing.stock = int.tryParse(stock.text) ?? existing.stock;
                  existing.barcode = barcodeController.text.trim();
                  existing.imagePath = imagePath;
                }
                onChanged();
                Navigator.pop(dialogContext);
              },
              child: Text(existing == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveImportTemplate(BuildContext context) async {
    try {
      final bytes = Uint8List.fromList(productImportTemplate());
      final destination = await FilePicker.saveFile(
        dialogTitle: 'Enregistrer le modèle Excel',
        fileName: 'modele-produits-moncommerce.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: bytes,
      );
      if (destination != null && context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Modèle Excel enregistré. Remplissez la feuille Produits.',
            ),
          ),
        );
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Impossible d’enregistrer le modèle Excel.'),
          ),
        );
    }
  }

  Future<void> _exportProducts(BuildContext context) async {
    try {
      final bytes = exportProductWorkbook(
        products.map(
          (p) => ImportedProduct(
            name: p.name,
            price: p.price,
            stock: p.stock,
            purchasePrice: p.purchasePrice,
            barcode: p.barcode,
          ),
        ),
      );
      final path = await FilePicker.saveFile(
        dialogTitle: 'Exporter les produits',
        fileName:
            'produits-${DateTime.now().toIso8601String().substring(0, 10)}.xlsx',
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: Uint8List.fromList(bytes),
      );
      if (path != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Produits exportés en Excel.')),
        );
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossible d’exporter les produits.')),
        );
      }
    }
  }

  Future<void> _inventory(BuildContext context, {bool restock = false}) async {
    if (products.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Ajoutez d’abord des articles avec le bouton + ou l’import Excel.',
          ),
        ),
      );
      return;
    }
    final snapshot = products.toList();
    final stocks = snapshot.map((p) => p.stock).toList();
    final values = await showDialog<List<int?>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => InventoryDialog(
        entries: snapshot
            .map((p) => InventoryEntry(p.name, p.barcode, p.stock))
            .toList(),
        restock: restock,
      ),
    );
    if (values == null || !context.mounted) {
      return;
    }
    for (var i = 0; i < snapshot.length; i++) {
      if (values[i] != null &&
          (!products.contains(snapshot[i]) || snapshot[i].stock != stocks[i])) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Le stock a changé pendant la saisie. Recommencez avec les quantités actualisées.',
            ),
          ),
        );
        return;
      }
    }
    for (var i = 0; i < snapshot.length; i++) {
      if (values[i] != null) {
        snapshot[i].stock = restock ? stocks[i] + values[i]! : values[i]!;
      }
    }
    onChanged();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          restock
              ? 'Réapprovisionnement enregistré.'
              : 'Inventaire enregistré : stocks mis à jour.',
        ),
      ),
    );
  }

  Future<void> _importProducts(BuildContext context) async {
    try {
      final selection = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        withData: true,
      );
      if (selection == null) return;
      final file = selection.files.single;
      if (file.size > 10 * 1024 * 1024)
        throw const FormatException(
          'Choisissez un fichier Excel de moins de 10 Mo.',
        );
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final result = parseProductWorkbook(
        bytes,
        existingNames: products.map((p) => p.name),
        existingBarcodes: products.map((p) => p.barcode),
      );
      if (!context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Vérifier l’importation Excel'),
          content: SizedBox(
            width: 560,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Feuille : ${result.sheetName}\n${result.products.length} produit(s) à ajouter • ${result.issues.length} ligne(s) ignorée(s)',
                ),
                const SizedBox(height: 8),
                const Text('Les produits existants ne seront pas modifiés.'),
                const Divider(),
                Expanded(
                  child: ListView(
                    children: [
                      for (final issue in result.issues)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(
                            issue,
                            style: const TextStyle(color: Color(0xFFB3261E)),
                          ),
                        ),
                      for (final warning in result.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Text(warning),
                        ),
                      for (final row in result.products)
                        ListTile(
                          dense: true,
                          title: Text(row.name),
                          subtitle: Text(
                            '${money(row.price)} FCFA • stock ${row.stock}${row.barcode.isEmpty ? "" : " • ${row.barcode}"}',
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: result.products.isEmpty
                  ? null
                  : () => Navigator.pop(dialogContext, true),
              child: Text('Importer ${result.products.length} produits'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      products.addAll(
        result.products.map(
          (row) => Product(
            row.name,
            row.price,
            row.stock,
            Icons.inventory_2_outlined,
            purchasePrice: row.purchasePrice,
            barcode: row.barcode,
          ),
        ),
      );
      onChanged();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${result.products.length} produit(s) importé(s).'),
        ),
      );
    } on FormatException catch (error) {
      if (context.mounted)
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Fichier illisible. Utilisez un classeur Excel .xlsx non protégé.',
            ),
          ),
        );
    }
  }
}

Future<String?> selectProductPhoto() async {
  final selected = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
  );
  if (selected == null) return null;
  final file = selected.files.single;
  if (file.path == null || file.size > 10 * 1024 * 1024)
    throw const FormatException('Image invalide');
  final bytes = await File(file.path!).readAsBytes();
  final codec = await ui.instantiateImageCodec(bytes, targetWidth: 1600);
  final frame = await codec.getNextFrame();
  final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
  frame.image.dispose();
  codec.dispose();
  if (png == null) throw const FormatException('Image illisible');
  final support = await getApplicationSupportDirectory();
  final directory = await Directory(
    '${support.path}${Platform.pathSeparator}product_images',
  ).create(recursive: true);
  final destination = File(
    '${directory.path}${Platform.pathSeparator}${DateTime.now().microsecondsSinceEpoch}.png',
  );
  await destination.writeAsBytes(png.buffer.asUint8List(), flush: true);
  return destination.path;
}

class _ProductBrowser extends StatefulWidget {
  const _ProductBrowser({
    required this.products,
    required this.actions,
    required this.onOpen,
  });
  final List<Product> products;
  final List<Widget> actions;
  final ValueChanged<Product> onOpen;

  @override
  State<_ProductBrowser> createState() => _ProductBrowserState();
}

class _ProductBrowserState extends State<_ProductBrowser> {
  final search = TextEditingController();
  String filter = 'Tous';

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  List<Product> get _visible {
    final query = search.text.trim().toLowerCase();
    return widget.products.where((p) {
      if (filter == 'Stock faible' && !(p.stock > 0 && p.stock <= 6)) {
        return false;
      }
      if (filter == 'Épuisés' && p.stock > 0) return false;
      return query.isEmpty ||
          p.name.toLowerCase().contains(query) ||
          p.barcode.toLowerCase().contains(query);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final side = width > 1120 ? (width - 1120) / 2 + 18 : 18.0;
    final visible = _visible;
    return Column(
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: search,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: 'Rechercher un produit',
                    suffixIcon: search.text.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Effacer',
                            onPressed: () {
                              search.clear();
                              setState(() {});
                            },
                            icon: const Icon(Icons.close),
                          ),
                  ),
                ),
              ),
              ...widget.actions,
            ],
          ),
        ),
        const SizedBox(height: 12),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: side),
          child: Row(
            children: [
              for (final label in const ['Tous', 'Stock faible', 'Épuisés'])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() => filter = label),
                    child: Container(
                      height: 40,
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: filter == label ? _green : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        boxShadow: const [
                          BoxShadow(color: Color(0x140F1F46), blurRadius: 6),
                        ],
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: filter == label ? Colors.white : _dark,
                        ),
                      ),
                    ),
                  ),
                ),
              const Spacer(),
              Text(
                '${visible.length} produit${visible.length > 1 ? 's' : ''}',
                style: const TextStyle(
                  color: Color(0xFF6B7280),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: visible.isEmpty
              ? const Center(child: Text('Aucun produit'))
              : GridView.builder(
                  padding: EdgeInsets.fromLTRB(side, 0, side, 20),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 420,
                    mainAxisExtent: 112,
                    crossAxisSpacing: 14,
                    mainAxisSpacing: 14,
                  ),
                  itemCount: visible.length,
                  itemBuilder: (_, index) => _card(visible[index]),
                ),
        ),
      ],
    );
  }

  Widget _image(Product p) {
    if (p.imagePath.isNotEmpty && File(p.imagePath).existsSync()) {
      return Image.file(File(p.imagePath), fit: BoxFit.cover);
    }
    if (p.imageUrl.isNotEmpty) {
      return Image.network(
        p.imageUrl,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(p),
      );
    }
    return _placeholder(p);
  }

  Widget _placeholder(Product p) => ColoredBox(
    color: _green.withValues(alpha: .08),
    child: Icon(p.icon, color: _green, size: 32),
  );

  Widget _card(Product p) {
    final out = p.stock <= 0;
    final low = !out && p.stock <= 6;
    final badgeColor = out
        ? const Color(0xFFB3261E)
        : low
        ? const Color(0xFFD56A4D)
        : _green;
    return Material(
      color: Colors.white,
      elevation: 1.5,
      shadowColor: const Color(0x1A0F1F46),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => widget.onOpen(p),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: _image(p),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      p.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: _dark,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${money(p.price)} FCFA',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        color: _dark,
                      ),
                    ),
                    if (p.barcode.isNotEmpty)
                      Text(
                        p.barcode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9CA3AF),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: .12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  out ? 'Épuisé' : '${p.stock} en stock',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class UpdateDownloadButton extends StatefulWidget {
  const UpdateDownloadButton({
    super.key,
    required this.downloadUrl,
    required this.version,
  });

  final String downloadUrl;
  final String version;

  @override
  State<UpdateDownloadButton> createState() => _UpdateDownloadButtonState();
}

class _UpdateDownloadButtonState extends State<UpdateDownloadButton> {
  bool _downloading = false;
  double _progress = 0;

  Future<void> _downloadAndInstall() async {
    if (_downloading) return;
    if (!Platform.isAndroid) {
      await launchUrl(
        Uri.parse(widget.downloadUrl),
        mode: LaunchMode.externalApplication,
      );
      return;
    }
    setState(() {
      _downloading = true;
      _progress = 0;
    });
    try {
      final path = await _downloadUpdateApk(
        widget.downloadUrl,
        widget.version,
        (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _downloading = false);
      await _installUpdateApk(path);
    } catch (_) {
      if (!mounted) return;
      setState(() => _downloading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Téléchargement impossible. Vérifiez votre connexion et réessayez.',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => FilledButton.icon(
    onPressed: _downloading ? null : _downloadAndInstall,
    icon: _downloading
        ? const SizedBox.square(
            dimension: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : const Icon(Icons.download),
    label: Text(
      _downloading
          ? 'Téléchargement ${(_progress * 100).round()} %'
          : 'Télécharger et installer',
    ),
  );
}
