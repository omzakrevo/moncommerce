part of '../main.dart';

class SalesPage extends StatefulWidget {
  const SalesPage({super.key, required this.sales, required this.onSale});
  final List<SaleRecord> sales;
  final VoidCallback onSale;

  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  final search = TextEditingController();

  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = search.text.trim().toLowerCase();
    final visibleSales = widget.sales.where((sale) {
      return query.isEmpty ||
          sale.number.toLowerCase().contains(query) ||
          sale.product.toLowerCase().contains(query) ||
          sale.client.toLowerCase().contains(query);
    }).toList()..sort((a, b) => b.number.compareTo(a.number));
    return Column(
      children: [
        const PageHeader('Ventes', 'Historique des opérations du jour'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18),
          child: TextField(
            controller: search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Rechercher une vente',
              suffixIcon: IconButton(
                onPressed: () {},
                icon: const Icon(Icons.tune),
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 90),
            itemCount: visibleSales.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final sale = visibleSales[index];
              return Card(
                child: ListTile(
                  onTap: () => _saleActions(context, sale),
                  contentPadding: const EdgeInsets.all(14),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFE4EDFD),
                    child: Icon(Icons.receipt_long_outlined, color: _green),
                  ),
                  title: Text(
                    sale.number.isEmpty ? 'Vente' : sale.number,
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${sale.product}\n${sale.client} • ${sale.payment} • ${sale.date} ${sale.time}',
                  ),
                  isThreeLine: true,
                  trailing: Text(
                    '${money(sale.amount)} F',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _saleActions(BuildContext context, SaleRecord sale) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  sale.product,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text('${money(sale.amount)} FCFA • ${sale.payment}'),
              ),
              ListTile(
                leading: const Icon(Icons.print_outlined, color: _green),
                title: const Text('Imprimer le ticket'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _printInvoice(sale);
                },
              ),
              ListTile(
                leading: const Icon(Icons.chat_outlined, color: _green),
                title: const Text('Envoyer par WhatsApp'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openMessage(context, sale, whatsapp: true);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.sms_outlined,
                  color: Color(0xFF4776B7),
                ),
                title: const Text('Envoyer par SMS'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _openMessage(context, sale, whatsapp: false);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _printInvoice(SaleRecord sale) async {
    final prefs = await SharedPreferences.getInstance();
    await Printing.layoutPdf(
      onLayout: (_) => buildSaleReceipt(sale),
      format: saleReceiptFormat(
        sale,
        footerMessage:
            sale.receiptMessage ??
            prefs.getString(receiptFooterKey) ??
            defaultReceiptFooter,
      ),
      name: '${sale.number.isEmpty ? 'ticket-moncommerce' : sale.number}.pdf',
    );
  }

  Future<void> _openMessage(
    BuildContext context,
    SaleRecord sale, {
    required bool whatsapp,
  }) async {
    final message =
        'MonCommerce - Reçu : ${sale.product}, total ${money(sale.amount)} FCFA, paiement ${sale.payment}.';
    final uri = whatsapp
        ? Uri.parse('https://wa.me/?text=${Uri.encodeComponent(message)}')
        : Uri(scheme: 'sms', queryParameters: {'body': message});
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
        context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Aucune application compatible trouvée.')),
      );
    }
  }
}

class SaleSheet extends StatefulWidget {
  const SaleSheet({
    super.key,
    required this.products,
    required this.onValidated,
  });
  final List<Product> products;
  final FutureOr<void> Function(List<SaleLine>, String, String) onValidated;
  @override
  State<SaleSheet> createState() => _SaleSheetState();
}

class _SaleSheetState extends State<SaleSheet> {
  String payment = 'Espèces';
  final List<SaleLine> cart = [];
  final clientController = TextEditingController();
  final productSearchController = TextEditingController();
  final barcodeController = TextEditingController();
  final barcodeFocus = FocusNode();
  String scanMessage = 'Lecteur USB : scannez un produit pour l’ajouter.';
  bool scanError = false;
  String keyboardBarcode = '';
  DateTime? lastBarcodeKey;
  Timer? barcodeTimer;
  Timer? hardwareBarcodeTimer;
  TextEditingController? scanTextController;
  TextEditingValue? textBeforeScan;
  ReceiptPrintSettings printSettings = const ReceiptPrintSettings();
  bool validating = false;

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
    HardwareKeyboard.instance.addHandler(_captureHardwareBarcode);
  }

  Future<void> _loadPrintSettings() async {
    try {
      final saved = await ReceiptPrintSettings.load();
      if (mounted) setState(() => printSettings = saved);
    } catch (_) {
      // Printing reports configuration failures independently after saving.
    }
  }

  Future<void> _configurePrinting() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Impression du ticket'),
        content: const SizedBox(
          width: 480,
          child: SingleChildScrollView(child: ReceiptPrintSettingsCard()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Terminé'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    await _loadPrintSettings();
    if (mounted) barcodeFocus.requestFocus();
  }

  void _submitBarcode(String value) {
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    keyboardBarcode = '';
    if (validating || !mounted || ModalRoute.of(context)?.isCurrent != true)
      return;
    final code = value.trim();
    if (code.isEmpty) return;
    final matches = widget.products
        .where((p) => p.barcode.trim() == code)
        .toList();
    setState(() {
      scanError = true;
      if (matches.isEmpty) {
        scanMessage = 'Code inconnu : $code';
      } else if (matches.length > 1) {
        scanMessage = 'Code attribué à plusieurs produits : $code';
      } else if (_quantityInCart(matches.single) >= matches.single.stock) {
        scanMessage = 'Stock insuffisant : ${matches.single.name}';
      } else {
        _addProduct(matches.single);
        scanError = false;
        scanMessage =
            '${matches.single.name} ajouté • quantité ${_quantityInCart(matches.single)}';
      }
      barcodeController.clear();
    });
    barcodeFocus.requestFocus();
  }

  void _barcodeChanged(String value) {
    barcodeTimer?.cancel();
    final code = value.trim();
    if (code.isEmpty) return;
    // USB readers without a suffix finish by pausing. Match the whole code,
    // preserving leading zeroes and keeping incomplete manual input editable.
    barcodeTimer = Timer(const Duration(milliseconds: 200), () {
      if (!mounted || validating || ModalRoute.of(context)?.isCurrent != true)
        return;
      if (widget.products.any((p) => p.barcode.trim() == code)) {
        _submitBarcode(code);
      } else {
        setState(() {
          scanError = true;
          scanMessage = 'Code non reconnu : $code';
        });
      }
    });
  }

  bool _captureHardwareBarcode(KeyEvent event) {
    if (event is! KeyDownEvent ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true)
      return false;
    if (validating) return true;
    if (barcodeFocus.hasFocus)
      return false; // The scanner field also handles pasted input.
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed)
      return false;
    final now = DateTime.now();
    if (lastBarcodeKey == null ||
        now.difference(lastBarcodeKey!) > const Duration(milliseconds: 100)) {
      keyboardBarcode = '';
      final focusContext = FocusManager.instance.primaryFocus?.context;
      final editable = focusContext
          ?.findAncestorWidgetOfExactType<EditableText>();
      final controller = editable?.controller;
      scanTextController =
          [clientController, productSearchController].contains(controller)
          ? controller
          : null;
      textBeforeScan = scanTextController?.value;
    }
    lastBarcodeKey = now;
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter ||
        event.logicalKey == LogicalKeyboardKey.tab) {
      return _finishHardwareBarcode();
    }
    if (event.character != null &&
        event.character!.codeUnits.every((c) => c >= 32) &&
        keyboardBarcode.length < 128) {
      keyboardBarcode += event.character!;
      hardwareBarcodeTimer?.cancel();
      hardwareBarcodeTimer = Timer(const Duration(milliseconds: 200), () {
        _finishHardwareBarcode();
        keyboardBarcode = '';
        lastBarcodeKey = null;
      });
    }
    return false;
  }

  bool _finishHardwareBarcode() {
    if (!mounted ||
        validating ||
        ModalRoute.of(context)?.isCurrent != true ||
        keyboardBarcode.length < 3)
      return false;
    final code = keyboardBarcode;
    final known = widget.products.any((p) => p.barcode.trim() == code);
    // Do not interpret ordinary names typed in customer/search fields as scans.
    if (!known &&
        scanTextController != null &&
        !RegExp(r'^\d{6,}$').hasMatch(code))
      return false;
    if (scanTextController != null && textBeforeScan != null)
      scanTextController!.value = textBeforeScan!;
    scanTextController = null;
    textBeforeScan = null;
    _submitBarcode(code);
    return true;
  }

  @override
  void dispose() {
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_captureHardwareBarcode);
    clientController.dispose();
    productSearchController.dispose();
    barcodeController.dispose();
    barcodeFocus.dispose();
    super.dispose();
  }

  List<Product> get _visibleProducts {
    final query = productSearchController.text.trim().toLowerCase();
    return widget.products.where((item) {
      if (item.stock <= 0) return false;
      return query.isEmpty ||
          item.name.toLowerCase().contains(query) ||
          item.barcode.toLowerCase().contains(query);
    }).toList();
  }

  int get cartTotal => cart.fold(0, (sum, line) => sum + line.total);

  int _quantityInCart(Product item) => cart
      .where((line) => identical(line.product, item))
      .fold(0, (sum, line) => sum + line.quantity);

  void _addProduct(Product product) {
    if (product.stock - _quantityInCart(product) <= 0) return;
    setState(() {
      final index = cart.indexWhere((line) => identical(line.product, product));
      if (index >= 0) {
        cart[index].quantity++;
      } else {
        cart.add(SaleLine(product, 1));
      }
    });
    barcodeFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final windowWidth = MediaQuery.sizeOf(context).width;
    final desktop = windowWidth >= 1250;
    final catalog = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: barcodeController,
          focusNode: barcodeFocus,
          autofocus: true,
          onChanged: _barcodeChanged,
          onSubmitted: _submitBarcode,
          decoration: const InputDecoration(
            labelText: 'Lecteur de code-barres USB',
            hintText: 'Scannez : le produit s’ajoute automatiquement',
            prefixIcon: Icon(Icons.qr_code_scanner),
          ),
        ),
        const SizedBox(height: 6),
        Semantics(
          liveRegion: true,
          child: Text(
            scanMessage,
            style: TextStyle(
              color: scanError ? const Color(0xFFB3261E) : _green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: productSearchController,
          onChanged: (_) => setState(() {}),
          onSubmitted: (value) {
            if (value.trim().isNotEmpty) {
              _submitBarcode(value);
              productSearchController.clear();
              setState(() {});
            }
          },
          decoration: InputDecoration(
            labelText: 'Rechercher un produit',
            hintText: 'Nom ou code-barres',
            prefixIcon: const Icon(Icons.search),
            suffixIcon: productSearchController.text.isEmpty
                ? null
                : IconButton(
                    onPressed: () {
                      productSearchController.clear();
                      setState(() {});
                    },
                    icon: const Icon(Icons.close),
                  ),
          ),
        ),
        const SizedBox(height: 14),
        Expanded(child: _productGrid()),
      ],
    );
    return PopScope(
      canPop: !validating,
      child: AbsorbPointer(
        absorbing: validating,
        child: Focus(
          child: Container(
            height: double.infinity,
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 18),
            decoration: const BoxDecoration(color: _cream),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Fermer la vente',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Nouvelle vente',
                        style: TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                          color: _dark,
                        ),
                      ),
                    ),
                    Badge(
                      label: Text('${cart.length}'),
                      child: const Icon(
                        Icons.shopping_cart_outlined,
                        color: _green,
                      ),
                    ),
                    const SizedBox(width: 10),
                    IconButton.filledTonal(
                      tooltip: 'Scanner pour ajouter',
                      onPressed: _scanIntoCart,
                      icon: const Icon(Icons.qr_code_scanner_rounded),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filledTonal(
                      tooltip: 'Configurer l’impression du ticket',
                      onPressed: _configurePrinting,
                      icon: Icon(
                        printSettings.enabled
                            ? Icons.print
                            : Icons.print_disabled_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Expanded(
                  child: desktop
                      ? Row(
                          children: [
                            Expanded(flex: 7, child: catalog),
                            const SizedBox(width: 18),
                            SizedBox(width: 410, child: _cartPanel()),
                          ],
                        )
                      : Column(
                          children: [
                            Expanded(flex: 6, child: catalog),
                            const SizedBox(height: 12),
                            Expanded(flex: 5, child: _cartPanel()),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _productGrid() {
    final products = _visibleProducts;
    if (products.isEmpty)
      return const Center(child: Text('Aucun produit disponible'));
    return ListView.separated(
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemCount: products.length,
      itemBuilder: (_, index) {
        final item = products[index];
        final remaining = item.stock - _quantityInCart(item);
        return Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: remaining > 0 ? () => _addProduct(item) : null,
            child: Ink(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _green.withValues(alpha: .14)),
              ),
              child: LayoutBuilder(
                builder: (context, constraints) => constraints.maxWidth >= 480
                    ? Row(
                        children: [
                          SizedBox(
                            width: 140,
                            height: 150,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.horizontal(
                                left: Radius.circular(15),
                              ),
                              child: _productImage(item),
                            ),
                          ),
                          Expanded(
                            child: _productDetails(
                              item,
                              remaining,
                              large: true,
                            ),
                          ),
                        ],
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: 105,
                            child: ClipRRect(
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(15),
                              ),
                              child: _productImage(item),
                            ),
                          ),
                          _productDetails(item, remaining),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _productDetails(Product item, int remaining, {bool large = false}) =>
      Padding(
        padding: EdgeInsets.all(large ? 18 : 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              item.name,
              style: TextStyle(
                fontSize: large ? 21 : 17,
                color: _dark,
                fontWeight: FontWeight.w900,
                height: 1.15,
              ),
            ),
            SizedBox(height: large ? 8 : 6),
            Text(
              '${money(item.price)} FCFA',
              style: TextStyle(
                fontSize: large ? 19 : 16,
                fontWeight: FontWeight.w900,
                color: _green,
              ),
            ),
            SizedBox(height: large ? 5 : 4),
            Text(
              '$remaining disponible${remaining > 1 ? 's' : ''}',
              style: TextStyle(
                fontSize: large ? 13 : 12,
                color: const Color(0xFF4B5563),
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: large ? 8 : 7),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: remaining > 0 ? () => _addProduct(item) : null,
                icon: Icon(Icons.add, size: large ? 20 : 18),
                label: Text(
                  'Ajouter au panier',
                  style: TextStyle(
                    fontSize: large ? 14 : 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: Size(0, large ? 42 : 38),
                ),
              ),
            ),
          ],
        ),
      );

  Widget _productImage(Product item) {
    if (item.imagePath.isNotEmpty && File(item.imagePath).existsSync())
      return ColoredBox(
        color: const Color(0xFFF4F6F9),
        child: Image.file(File(item.imagePath), fit: BoxFit.contain),
      );
    if (item.imageUrl.isNotEmpty)
      return Image.network(
        item.imageUrl,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _fallbackProductImage(item),
      );
    return _fallbackProductImage(item);
  }

  Widget _fallbackProductImage(Product item) => ColoredBox(
    color: _green.withValues(alpha: .08),
    child: Icon(item.icon, size: 54, color: _green),
  );

  Widget _cartPanel() => Card(
    margin: EdgeInsets.zero,
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: constraints.maxHeight.clamp(
            480 * MediaQuery.textScalerOf(context).scale(1),
            double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Panier (${cart.length})',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: cart.isEmpty
                      ? const Center(
                          child: Text(
                            'Sélectionnez des produits',
                            style: TextStyle(color: Colors.black45),
                          ),
                        )
                      : ListView.separated(
                          itemCount: cart.length,
                          separatorBuilder: (_, _) => const Divider(),
                          itemBuilder: (_, index) {
                            final line = cart[index];
                            return Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        line.product.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                      Text(
                                        '${money(line.product.price)} F × ${line.quantity}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: line.quantity > 1
                                      ? () => setState(() => line.quantity--)
                                      : null,
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                                Text(
                                  '${line.quantity}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                IconButton(
                                  onPressed: line.quantity < line.product.stock
                                      ? () => setState(() => line.quantity++)
                                      : null,
                                  icon: const Icon(
                                    Icons.add_circle_outline,
                                    color: _green,
                                  ),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      setState(() => cart.removeAt(index)),
                                  icon: const Icon(
                                    Icons.close,
                                    color: Color(0xFFD56A4D),
                                  ),
                                ),
                              ],
                            );
                          },
                        ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: clientController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Client (facultatif)',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: ['Espèces', 'Orange Money', 'Moov Money', 'Crédit']
                      .map(
                        (item) => ChoiceChip(
                          label: Text(item),
                          selected: payment == item,
                          onSelected: (_) => setState(() => payment = item),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${money(cartTotal)} FCFA',
                      style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.w900,
                        color: _green,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _configurePrinting,
                  icon: Icon(
                    printSettings.enabled
                        ? Icons.print
                        : Icons.print_disabled_outlined,
                  ),
                  label: Text(
                    printSettings.enabled
                        ? 'Ticket automatique : ${printSettings.printer?.name ?? "imprimante à choisir"}'
                        : 'Activer l’impression du ticket',
                  ),
                ),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton.icon(
                    onPressed: cart.isEmpty || validating
                        ? null
                        : _validateSale,
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(
                      validating
                          ? 'Validation en cours…'
                          : printSettings.enabled
                          ? 'Valider et imprimer'
                          : 'Valider la vente',
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

  Future<void> _validateSale() async {
    if (validating || cart.isEmpty) return;
    barcodeTimer?.cancel();
    hardwareBarcodeTimer?.cancel();
    setState(() => validating = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      await widget.onValidated(
        cart.map((line) => SaleLine(line.product, line.quantity)).toList(),
        payment,
        clientController.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        cart.clear();
        payment = 'Espèces';
        clientController.clear();
        productSearchController.clear();
        barcodeController.clear();
        keyboardBarcode = '';
        lastBarcodeKey = null;
        scanError = false;
        scanMessage =
            'Nouvelle vente prête. Scannez ou sélectionnez un produit.';
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vente non enregistrée. Le panier est conservé ; réessayez.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => validating = false);
        barcodeFocus.requestFocus();
      }
    }
  }

  Future<void> _scanIntoCart() async {
    final codes = await Navigator.push<List<String>>(
      context,
      MaterialPageRoute(builder: (_) => const ContinuousBarcodeScannerPage()),
    );
    if (codes == null || codes.isEmpty || !mounted) return;
    var added = 0;
    var unknown = 0;
    setState(() {
      for (final code in codes) {
        Product? found;
        for (final item in widget.products) {
          if (item.barcode == code) {
            found = item;
            break;
          }
        }
        if (found == null) {
          unknown++;
          continue;
        }
        final existing = cart.indexWhere(
          (line) => identical(line.product, found),
        );
        final already = existing >= 0 ? cart[existing].quantity : 0;
        if (already >= found.stock) continue;
        if (existing >= 0) {
          cart[existing].quantity++;
        } else {
          cart.add(SaleLine(found, 1));
        }
        added++;
      }
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$added produit(s) ajouté(s)${unknown > 0 ? ' • $unknown code(s) inconnu(s)' : ''}',
        ),
      ),
    );
  }
}

String money(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(' ');
    out.write(digits[i]);
  }
  return out.toString();
}
