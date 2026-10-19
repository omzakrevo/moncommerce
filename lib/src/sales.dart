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
  String filter = 'Tous';

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
      if (filter == 'Dans le panier' && _quantityInCart(item) == 0) {
        return false;
      }
      if (filter == 'Stock faible' && item.stock > 5) return false;
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
        _filterChips(),
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
                            Expanded(flex: 7, child: catalog),
                            const SizedBox(height: 12),
                            Expanded(flex: 4, child: _cartPanel()),
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

  Widget _filterChips() {
    const filters = ['Tous', 'Dans le panier', 'Stock faible'];
    return SizedBox(
      height: 42,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final label = filters[index];
          final selected = filter == label;
          return InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => filter = label),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? _green : Colors.white,
                borderRadius: BorderRadius.circular(12),
                boxShadow: const [
                  BoxShadow(color: Color(0x140F1F46), blurRadius: 6),
                ],
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: selected ? Colors.white : _dark,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _productGrid() {
    final products = _visibleProducts;
    if (products.isEmpty) {
      return const Center(child: Text('Aucun produit disponible'));
    }
    return GridView.builder(
      padding: const EdgeInsets.only(bottom: 12),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 360,
        mainAxisExtent: 176,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: products.length,
      itemBuilder: (_, index) => _productCard(products[index]),
    );
  }

  Widget _stepper(Product item, {double size = 34}) {
    final inCart = _quantityInCart(item);
    final remaining = item.stock - inCart;
    Widget button({
      required IconData icon,
      required String tooltip,
      required VoidCallback? onPressed,
      required bool primary,
    }) => SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: primary && onPressed != null
              ? _green
              : const Color(0xFFF1F4F9),
          foregroundColor: primary ? Colors.white : _dark,
          disabledBackgroundColor: const Color(0xFFF1F4F9),
        ),
        icon: Icon(icon, size: size * .55),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        button(
          icon: Icons.remove,
          tooltip: 'Retirer du panier',
          onPressed: inCart > 0 ? () => _removeOne(item) : null,
          primary: false,
        ),
        SizedBox(
          width: size,
          child: Text(
            '$inCart',
            textAlign: TextAlign.center,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        ),
        button(
          icon: Icons.add,
          tooltip: 'Ajouter au panier',
          onPressed: remaining > 0 ? () => _addProduct(item) : null,
          primary: true,
        ),
      ],
    );
  }

  void _removeOne(Product item) {
    final index = cart.indexWhere((line) => identical(line.product, item));
    if (index < 0) return;
    setState(() {
      if (cart[index].quantity > 1) {
        cart[index].quantity--;
      } else {
        cart.removeAt(index);
      }
    });
    barcodeFocus.requestFocus();
  }

  Widget _productCard(Product item) {
    final remaining = item.stock - _quantityInCart(item);
    final selected = _quantityInCart(item) > 0;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected ? _green : Colors.transparent,
          width: 1.5,
        ),
        boxShadow: const [BoxShadow(color: Color(0x140F1F46), blurRadius: 8)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 70,
                  height: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: _productImage(item),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          color: _dark,
                          fontWeight: FontWeight.w800,
                          height: 1.2,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$remaining disponible${remaining > 1 ? 's' : ''}',
                        style: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF6B7280),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Row(
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    money(item.price),
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                      color: _dark,
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(right: 8, left: 2),
                child: Text(
                  'F',
                  style: TextStyle(
                    color: Color(0xFF9CA3AF),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              _stepper(item),
            ],
          ),
        ],
      ),
    );
  }

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

  Widget _cartPanel() => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [BoxShadow(color: Color(0x140F1F46), blurRadius: 10)],
    ),
    child: LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: SizedBox(
          height: constraints.maxHeight.clamp(
            600 * MediaQuery.textScalerOf(context).scale(1),
            double.infinity,
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Panier (${cart.length})',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _dark,
                  ),
                ),
                const SizedBox(height: 10),
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
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 12),
                          itemBuilder: (_, index) => _cartLine(cart[index]),
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
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF4F6F9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Résumé du paiement',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: _dark,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Text(
                            'Articles',
                            style: TextStyle(color: Color(0xFF6B7280)),
                          ),
                          const Spacer(),
                          Text(
                            '${cart.fold<int>(0, (s, l) => s + l.quantity)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                      const Divider(height: 22),
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
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              color: _green,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children:
                            ['Espèces', 'Orange Money', 'Moov Money', 'Crédit']
                                .map(
                                  (item) => ChoiceChip(
                                    label: Text(item),
                                    selected: payment == item,
                                    showCheckmark: false,
                                    selectedColor: Colors.white,
                                    onSelected: (_) =>
                                        setState(() => payment = item),
                                  ),
                                )
                                .toList(),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
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
                  height: 52,
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

  Widget _cartLine(SaleLine line) => Row(
    children: [
      SizedBox(
        width: 52,
        height: 52,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: _productImage(line.product),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              line.product.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w800,
                color: _dark,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '${line.quantity} × ${money(line.product.price)} F',
              style: const TextStyle(fontSize: 12, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
      const SizedBox(width: 8),
      Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            '${money(line.total)} F',
            style: const TextStyle(fontWeight: FontWeight.w900, color: _dark),
          ),
          const SizedBox(height: 4),
          _stepper(line.product, size: 28),
        ],
      ),
    ],
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
