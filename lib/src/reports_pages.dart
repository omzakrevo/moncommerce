part of '../main.dart';

class ReportsPage extends StatefulWidget {
  const ReportsPage({
    super.key,
    required this.revenue,
    required this.expenses,
    required this.salesCount,
    required this.creditTotal,
    required this.sales,
    required this.products,
    required this.expenseRecords,
  });
  final int revenue, expenses, salesCount, creditTotal;
  final List<SaleRecord> sales;
  final List<Product> products;
  final List<ExpenseRecord> expenseRecords;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  String period = 'all';

  DateTime? _saleDate(SaleRecord sale) {
    final parts = sale.date.split('/');
    if (parts.length != 3) return null;
    return DateTime.tryParse('${parts[2]}-${parts[1]}-${parts[0]}');
  }

  DateTime get _periodStart {
    final now = DateTime.now();
    return switch (period) {
      'today' => DateTime(now.year, now.month, now.day),
      'week' => DateTime(
        now.year,
        now.month,
        now.day,
      ).subtract(Duration(days: now.weekday - 1)),
      'month' => DateTime(now.year, now.month),
      _ => DateTime(2000),
    };
  }

  List<SaleRecord> get _filteredSales => widget.sales.where((sale) {
    final date = _saleDate(sale);
    return period == 'all' || (date != null && !date.isBefore(_periodStart));
  }).toList();

  List<ExpenseRecord> get _filteredExpenses => widget.expenseRecords.where((
    item,
  ) {
    final date = DateTime.tryParse(item.createdAt)?.toLocal();
    return period == 'all' || (date != null && !date.isBefore(_periodStart));
  }).toList();

  @override
  Widget build(BuildContext context) {
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    final salesCount = _filteredSales.length;
    final profit = revenue - expenses;
    final average = salesCount == 0 ? 0 : revenue ~/ salesCount;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rapports et statistiques'),
        actions: [
          PopupMenuButton<String>(
            tooltip: 'Exporter',
            icon: const Icon(Icons.ios_share_outlined),
            onSelected: (value) =>
                value == 'pdf' ? _exportPdf() : _exportExcel(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'pdf', child: Text('Exporter en PDF')),
              PopupMenuItem(value: 'excel', child: Text('Exporter en Excel')),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'today', label: Text('Jour')),
              ButtonSegment(value: 'week', label: Text('Semaine')),
              ButtonSegment(value: 'month', label: Text('Mois')),
              ButtonSegment(value: 'all', label: Text('Tout')),
            ],
            selected: {period},
            onSelectionChanged: (value) => setState(() => period = value.first),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(22),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [_dark, _green]),
              borderRadius: BorderRadius.circular(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'BÉNÉFICE ESTIMÉ',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 8),
                Text(
                  '${money(profit)} FCFA',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 1.35,
            children: [
              MetricCard(
                label: 'Chiffre d’affaires',
                value: '${money(revenue)} F',
                icon: Icons.trending_up,
                color: _green,
              ),
              MetricCard(
                label: 'Dépenses',
                value: '${money(expenses)} F',
                icon: Icons.trending_down,
                color: const Color(0xFFD56A4D),
              ),
              MetricCard(
                label: 'Panier moyen',
                value: '${money(average)} F',
                icon: Icons.shopping_basket_outlined,
                color: const Color(0xFF4776B7),
              ),
              MetricCard(
                label: 'Crédits ouverts',
                value: '${money(widget.creditTotal)} F',
                icon: Icons.schedule,
                color: _orange,
              ),
            ],
          ),
          const SizedBox(height: 22),
          SectionTitle('Performance - $_periodLabel'),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  _reportLine('Nombre de ventes', '$salesCount'),
                  const Divider(),
                  _reportLine(
                    'Marge estimée',
                    revenue == 0
                        ? '0 %'
                        : '${((profit / revenue) * 100).toStringAsFixed(1)} %',
                  ),
                  const Divider(),
                  _reportLine('Montant encaissé', '${money(revenue)} FCFA'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const SectionTitle('Exports détaillés'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf_outlined),
                  label: const Text('Rapport PDF'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _exportExcel,
                  icon: const Icon(Icons.table_view_outlined),
                  label: const Text('Rapport Excel'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _reportLine(String label, String value) => Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: Colors.black54)),
      ),
      Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
    ],
  );

  String get _periodLabel => switch (period) {
    'today' => 'Aujourd’hui',
    'week' => 'Cette semaine',
    'month' => 'Ce mois',
    _ => 'Toutes les périodes',
  };

  Future<void> _exportPdf() async {
    final shop =
        (await SharedPreferences.getInstance()).getString('shop_name') ??
        'MonCommerce';
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (_) => [
          pw.Text(
            shop.toUpperCase(),
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
          pw.Text('RAPPORT D’ACTIVITÉ - $_periodLabel'),
          pw.SizedBox(height: 14),
          pw.Row(
            children: [
              pw.Expanded(child: pw.Text('Ventes : ${_filteredSales.length}')),
              pw.Expanded(
                child: pw.Text('Chiffre d’affaires : ${money(revenue)} FCFA'),
              ),
              pw.Expanded(
                child: pw.Text(
                  'Bénéfice estimé : ${money(revenue - expenses)} FCFA',
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'VENTES',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: const [
              'N° vente',
              'Date',
              'Client',
              'Produits',
              'Paiement',
              'Montant',
            ],
            data: _filteredSales
                .map(
                  (s) => [
                    s.number,
                    '${s.date} ${s.time}',
                    s.client,
                    s.product,
                    s.payment,
                    '${money(s.amount)} F',
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.green800),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'LISTE DES PRODUITS',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.TableHelper.fromTextArray(
            headers: const ['Produit', 'Code-barres', 'Prix', 'Quantité'],
            data: widget.products
                .map(
                  (p) => [
                    p.name,
                    p.barcode,
                    '${money(p.price)} F',
                    '${p.stock}',
                  ],
                )
                .toList(),
            headerDecoration: const pw.BoxDecoration(color: PdfColors.blue700),
            headerStyle: pw.TextStyle(
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ),
    );
    await Printing.sharePdf(
      bytes: await pdf.save(),
      filename: 'rapport-moncommerce.pdf',
    );
  }

  Future<void> _exportExcel() async {
    final book = xlsx.Excel.createExcel();
    final summary = book['Résumé'];
    summary.appendRow([
      xlsx.TextCellValue('Rapport MonCommerce'),
      xlsx.TextCellValue(_periodLabel),
    ]);
    final revenue = _filteredSales.fold(0, (sum, sale) => sum + sale.amount);
    final expenses = _filteredExpenses.fold(
      0,
      (sum, item) => sum + item.amount,
    );
    summary.appendRow([
      xlsx.TextCellValue('Nombre de ventes'),
      xlsx.IntCellValue(_filteredSales.length),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Chiffre d’affaires'),
      xlsx.IntCellValue(revenue),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Dépenses'),
      xlsx.IntCellValue(expenses),
    ]);
    summary.appendRow([
      xlsx.TextCellValue('Bénéfice estimé'),
      xlsx.IntCellValue(revenue - expenses),
    ]);

    final salesSheet = book['Ventes'];
    salesSheet.appendRow(
      [
        'N° vente',
        'Date',
        'Client',
        'Produits',
        'Paiement',
        'Montant FCFA',
      ].map(xlsx.TextCellValue.new).toList(),
    );
    for (final sale in _filteredSales) {
      salesSheet.appendRow([
        xlsx.TextCellValue(sale.number),
        xlsx.TextCellValue('${sale.date} ${sale.time}'),
        xlsx.TextCellValue(sale.client),
        xlsx.TextCellValue(sale.product),
        xlsx.TextCellValue(sale.payment),
        xlsx.IntCellValue(sale.amount),
      ]);
    }
    final productsSheet = book['Produits'];
    productsSheet.appendRow(
      [
        'Produit',
        'Code-barres',
        'Prix FCFA',
        'Quantité',
      ].map(xlsx.TextCellValue.new).toList(),
    );
    for (final product in widget.products) {
      productsSheet.appendRow([
        xlsx.TextCellValue(product.name),
        xlsx.TextCellValue(product.barcode),
        xlsx.IntCellValue(product.price),
        xlsx.IntCellValue(product.stock),
      ]);
    }
    if (book.tables.containsKey('Sheet1')) book.delete('Sheet1');
    final bytes = book.encode();
    if (bytes == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            Uint8List.fromList(bytes),
            mimeType:
                'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
            name: 'rapport-moncommerce.xlsx',
          ),
        ],
        subject: 'Rapport MonCommerce - $_periodLabel',
      ),
    );
  }
}

class CreditsPage extends StatefulWidget {
  const CreditsPage({
    super.key,
    required this.credits,
    required this.onChanged,
  });
  final List<Credit> credits;
  final Future<void> Function() onChanged;
  @override
  State<CreditsPage> createState() => _CreditsPageState();
}

class _CreditsPageState extends State<CreditsPage> {
  Future<void> _markPaid(int index) async {
    final credit = widget.credits[index];
    final controller = TextEditingController(text: credit.remaining.toString());
    final paidAmount = await showDialog<int>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paiement du crédit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Reste à payer : ${money(credit.remaining)} FCFA'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant payé'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text) ?? 0;
              if (value > 0 && value <= credit.remaining) {
                Navigator.pop(c, value);
              }
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
    if (paidAmount != null) {
      setState(() => credit.paid += paidAmount);
      await widget.onChanged();
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Crédits clients')),
    body: widget.credits.isEmpty
        ? const Center(child: Text('Aucun crédit en attente'))
        : ListView.separated(
            padding: const EdgeInsets.all(18),
            itemCount: widget.credits.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final credit = widget.credits[index];
              return Card(
                child: ListTile(
                  contentPadding: const EdgeInsets.all(14),
                  leading: const CircleAvatar(
                    backgroundColor: Color(0xFFFFF3D6),
                    child: Icon(Icons.person_outline, color: _orange),
                  ),
                  title: Text(
                    credit.customer,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${credit.phone}\nÉchéance : ${credit.dueDate}',
                  ),
                  isThreeLine: true,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${money(credit.remaining)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (credit.remaining > 0)
                        TextButton(
                          onPressed: () => _markPaid(index),
                          child: const Text('Payer'),
                        )
                      else
                        const Text(
                          'Réglé',
                          style: TextStyle(
                            color: _green,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class DirectoryPage extends StatefulWidget {
  const DirectoryPage({
    super.key,
    required this.title,
    required this.storageKey,
    required this.icon,
    required this.nameLabel,
    this.enableRoles = false,
  });
  final String title, storageKey, nameLabel;
  final IconData icon;
  final bool enableRoles;
  @override
  State<DirectoryPage> createState() => _DirectoryPageState();
}

class _DirectoryPageState extends State<DirectoryPage> {
  final List<Map<String, String>> _items = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(widget.storageKey);
    if (raw == null || !mounted) return;
    final decoded = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    setState(
      () => _items.addAll(
        decoded.map(
          (item) => item.map((key, value) => MapEntry(key, value.toString())),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(widget.storageKey, jsonEncode(_items));
  }

  void _add() {
    final name = TextEditingController();
    final phone = TextEditingController();
    final detail = TextEditingController();
    var selectedRole = 'Caissier';
    var isActive = true;
    showDialog<void>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('Ajouter • ${widget.title}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: InputDecoration(labelText: widget.nameLabel),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Téléphone'),
              ),
              const SizedBox(height: 10),
              if (widget.enableRoles) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: selectedRole,
                  decoration: const InputDecoration(
                    labelText: 'Rôle de l’utilisateur',
                    prefixIcon: Icon(Icons.admin_panel_settings_outlined),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'Caissier',
                      child: Text('Caissier • ventes et caisse'),
                    ),
                    DropdownMenuItem(
                      value: 'Vendeur',
                      child: Text('Vendeur • ventes et clients'),
                    ),
                    DropdownMenuItem(
                      value: 'Gestionnaire',
                      child: Text('Gestionnaire • stock et rapports'),
                    ),
                    DropdownMenuItem(
                      value: 'Administrateur',
                      child: Text('Administrateur • accès complet'),
                    ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => selectedRole = value!),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isActive,
                  onChanged: (value) => setDialogState(() => isActive = value),
                  title: const Text('Compte actif'),
                  subtitle: const Text('Autoriser cet utilisateur'),
                ),
              ] else
                TextField(
                  controller: detail,
                  decoration: const InputDecoration(
                    labelText: 'Rôle ou spécialité',
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('Annuler'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                setState(
                  () => _items.add({
                    'name': name.text.trim(),
                    'phone': phone.text.trim(),
                    'detail': widget.enableRoles
                        ? selectedRole
                        : detail.text.trim(),
                    'active': isActive.toString(),
                  }),
                );
                _save();
                Navigator.pop(c);
              },
              child: const Text('Ajouter'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.title)),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      icon: const Icon(Icons.add),
      label: const Text('Ajouter'),
    ),
    body: _items.isEmpty
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 55, color: Colors.black26),
                const SizedBox(height: 12),
                Text('Aucun élément dans ${widget.title.toLowerCase()}'),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: _items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final item = _items[index];
              final active = item['active'] != 'false';
              return Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: active
                        ? _green.withValues(alpha: .12)
                        : Colors.black12,
                    child: Icon(
                      widget.icon,
                      color: active ? _green : Colors.black38,
                    ),
                  ),
                  title: Text(
                    item['name']!,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: active ? null : Colors.black45,
                    ),
                  ),
                  subtitle: Text(
                    widget.enableRoles
                        ? '${item['phone']} • ${item['detail']} • ${active ? 'Actif' : 'Désactivé'}'
                        : '${item['phone']} • ${item['detail']}',
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'toggle') {
                        setState(() => item['active'] = (!active).toString());
                      } else if (action == 'delete') {
                        setState(() => _items.removeAt(index));
                      }
                      _save();
                    },
                    itemBuilder: (_) => [
                      if (widget.enableRoles)
                        PopupMenuItem(
                          value: 'toggle',
                          child: Text(active ? 'Désactiver' : 'Activer'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('Supprimer'),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}

class SupplierDebtsPage extends StatefulWidget {
  const SupplierDebtsPage({super.key});
  @override
  State<SupplierDebtsPage> createState() => _SupplierDebtsPageState();
}

class _SupplierDebtsPageState extends State<SupplierDebtsPage> {
  final List<Map<String, dynamic>> debts = [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('supplier_debts_v1');
    if (raw != null && mounted) {
      setState(
        () => debts.addAll(
          List<Map<String, dynamic>>.from(jsonDecode(raw) as List),
        ),
      );
    }
  }

  Future<void> _save() async => (await SharedPreferences.getInstance())
      .setString('supplier_debts_v1', jsonEncode(debts));

  void _add() {
    final supplier = TextEditingController();
    final amount = TextEditingController();
    final nature = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouvelle dette fournisseur'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: supplier,
              decoration: const InputDecoration(labelText: 'Fournisseur'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: nature,
              decoration: const InputDecoration(
                labelText: 'Marchandise ou motif',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant dû'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              if (supplier.text.isEmpty) return;
              setState(
                () => debts.insert(0, {
                  'supplier': supplier.text.trim(),
                  'nature': nature.text.trim(),
                  'amount': int.tryParse(amount.text) ?? 0,
                  'paid': 0,
                }),
              );
              _save();
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _pay(int index) {
    final remaining =
        (debts[index]['amount'] as int) - (debts[index]['paid'] as int);
    final value = TextEditingController(text: remaining.toString());
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Paiement fournisseur'),
        content: TextField(
          controller: value,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: 'Montant payé',
            helperText: 'Reste : ${money(remaining)} F',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () {
              final paid = int.tryParse(value.text) ?? 0;
              if (paid <= 0 || paid > remaining) return;
              setState(
                () =>
                    debts[index]['paid'] = (debts[index]['paid'] as int) + paid,
              );
              _save();
              Navigator.pop(c);
            },
            child: const Text('Payer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Dettes fournisseurs')),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _add,
      icon: const Icon(Icons.add),
      label: const Text('Ajouter'),
    ),
    body: debts.isEmpty
        ? const Center(child: Text('Aucune dette fournisseur'))
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: debts.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final item = debts[index];
              final remaining = (item['amount'] as int) - (item['paid'] as int);
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.local_shipping_outlined),
                  ),
                  title: Text(
                    item['supplier'] as String,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                  subtitle: Text(
                    '${item['nature']}\nPayé : ${money(item['paid'] as int)} F',
                  ),
                  isThreeLine: true,
                  trailing: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${money(remaining)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                      if (remaining > 0)
                        TextButton(
                          onPressed: () => _pay(index),
                          child: const Text('Payer'),
                        )
                      else
                        const Text('Réglé', style: TextStyle(color: _green)),
                    ],
                  ),
                ),
              );
            },
          ),
  );
}
