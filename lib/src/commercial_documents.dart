part of '../main.dart';

class CommercialDocumentsPage extends StatefulWidget {
  const CommercialDocumentsPage({super.key, required this.products});
  final List<Product> products;

  @override
  State<CommercialDocumentsPage> createState() =>
      _CommercialDocumentsPageState();
}

class _CommercialDocumentsPageState extends State<CommercialDocumentsPage> {
  static const _storageKey = 'commercial_documents_v1';
  static const _customersStorageKey = 'commercial_document_customers_v1';
  static const _headerImageKey = 'commercial_document_header_image_v1';
  static const _footerImageKey = 'commercial_document_footer_image_v1';
  static const _stampImageKey = 'commercial_document_stamp_image_v1';
  static const _signatureImageKey = 'commercial_document_signature_image_v1';
  static const _templateKey = 'commercial_document_template_v1';
  static const _showShopNameKey = 'commercial_document_show_shop_name_v1';
  static const _headerHeightKey = 'commercial_document_header_height_v1';
  static const _footerHeightKey = 'commercial_document_footer_height_v1';
  final documents = <CommercialDocument>[];
  final customers = <CommercialCustomer>[];
  final selectedDeliveryNotes = <CommercialDocument>{};
  bool selectingDeliveryNotes = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_storageKey);
    final rawCustomers = prefs.getString(_customersStorageKey);
    if (!mounted) return;
    final loadedDocuments = raw == null
        ? <CommercialDocument>[]
        : (jsonDecode(raw) as List)
              .map(
                (item) => CommercialDocument.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ),
              )
              .toList();
    final loadedCustomers = rawCustomers == null
        ? <CommercialCustomer>[]
        : (jsonDecode(rawCustomers) as List)
              .map(
                (item) => CommercialCustomer.fromJson(
                  Map<String, dynamic>.from(item as Map),
                ),
              )
              .toList();
    for (final document in loadedDocuments) {
      if (document.client.isEmpty ||
          loadedCustomers.any(
            (customer) =>
                customer.name.toLowerCase() == document.client.toLowerCase(),
          )) {
        continue;
      }
      loadedCustomers.add(
        CommercialCustomer(
          name: document.client,
          phone: document.phone,
          address: document.address,
          isCompany: false,
        ),
      );
    }
    setState(() {
      documents.addAll(loadedDocuments);
      customers.addAll(loadedCustomers);
    });
    if (rawCustomers == null && loadedCustomers.isNotEmpty)
      await _saveCustomers();
  }

  Future<void> _save() async =>
      (await SharedPreferences.getInstance()).setString(
        _storageKey,
        jsonEncode(documents.map((document) => document.toJson()).toList()),
      );

  Future<void> _saveCustomers() async =>
      (await SharedPreferences.getInstance()).setString(
        _customersStorageKey,
        jsonEncode(customers.map((customer) => customer.toJson()).toList()),
      );

  Future<void> _rememberCustomer(CommercialDocument document) async {
    final existingIndex = customers.indexWhere(
      (item) => item.name.toLowerCase() == document.client.toLowerCase(),
    );
    final customer = CommercialCustomer(
      name: document.client,
      phone: document.phone,
      address: document.address,
      isCompany: existingIndex >= 0
          ? customers[existingIndex].isCompany
          : false,
    );
    setState(() {
      if (existingIndex < 0) {
        customers.add(customer);
      } else {
        customers[existingIndex] = customer;
      }
    });
    await _saveCustomers();
  }

  Future<void> _create() async {
    final document = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
        ),
      ),
    );
    if (document == null) return;
    setState(() => documents.insert(0, document));
    await _rememberCustomer(document);
    await _save();
    unawaited(
      _logActivity(
        'document_created',
        '${document.type} ${document.number} créé',
        metadata: {
          'document_type': document.type,
          'document_number': document.number,
          'amount': document.total,
        },
      ),
    );
  }

  Future<void> _edit(CommercialDocument document, int index) async {
    final updated = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: document,
        ),
      ),
    );
    if (updated == null) return;
    setState(() => documents[index] = updated);
    await _rememberCustomer(updated);
    await _save();
    unawaited(
      _logActivity(
        'document_updated',
        '${updated.type} ${updated.number} modifié',
        metadata: {
          'document_type': updated.type,
          'document_number': updated.number,
          'amount': updated.total,
        },
      ),
    );
  }

  String? _nextDocumentType(String type) => switch (type) {
    'Devis' => 'Facture pro forma',
    'Facture pro forma' => 'Facture définitive',
    'Facture définitive' => 'Bordereau de livraison',
    _ => null,
  };

  String _newDocumentNumber(String type, DateTime now) {
    final prefix = switch (type) {
      'Devis' => 'DEV',
      'Facture pro forma' => 'PRO',
      'Facture définitive' => 'FAC',
      'Bordereau de livraison' => 'BL',
      _ => 'BC',
    };
    final suffix = now.millisecondsSinceEpoch.toString();
    return '$prefix-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${suffix.substring(suffix.length - 5)}';
  }

  Future<void> _evolve(CommercialDocument source) async {
    final targetType = _nextDocumentType(source.type);
    if (targetType == null) return;
    final now = DateTime.now();
    final evolved = CommercialDocument(
      type: targetType,
      number: _newDocumentNumber(targetType, now),
      client: source.client,
      phone: source.phone,
      address: source.address,
      object: source.object,
      purchaseOrderNumber: source.purchaseOrderNumber,
      notes: source.notes,
      createdAt: now,
      lines: source.lines
          .map(
            (line) => CommercialLine(
              line.description,
              line.quantity,
              line.unitPrice,
              observation: line.observation,
            ),
          )
          .toList(),
    );
    setState(() => documents.insert(0, evolved));
    await _save();
    unawaited(
      _logActivity(
        'document_evolved',
        '${source.type} transformé en $targetType',
        metadata: {
          'source_number': source.number,
          'target_number': evolved.number,
          'target_type': targetType,
        },
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$targetType ${evolved.number} créé avec succès')),
    );
  }

  Future<void> _duplicateInvoice(CommercialDocument source) async {
    final duplicate = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: source,
          createAsNew: true,
        ),
      ),
    );
    if (duplicate == null) return;
    setState(() => documents.insert(0, duplicate));
    await _rememberCustomer(duplicate);
    await _save();
    unawaited(
      _logActivity(
        'document_duplicated',
        'Facture ${source.number} dupliquée en ${duplicate.number}',
        metadata: {
          'source_number': source.number,
          'target_number': duplicate.number,
          'document_type': duplicate.type,
        },
      ),
    );
  }

  Future<void> _createInvoiceFromDeliveryNotes() async {
    final selected = selectedDeliveryNotes.toList();
    if (selected.isEmpty) return;
    final first = selected.first;
    final now = DateTime.now();
    final draft = CommercialDocument(
      type: 'Facture définitive',
      number: _newDocumentNumber('Facture définitive', now),
      client: first.client,
      phone: first.phone,
      address: first.address,
      object: selected.length == 1
          ? first.object
          : 'Facture des bordereaux ${selected.map((note) => note.number).join(', ')}',
      purchaseOrderNumber: first.purchaseOrderNumber,
      notes: selected
          .where((note) => note.notes.isNotEmpty)
          .map((note) => note.notes)
          .join('\n'),
      createdAt: now,
      lines: selected
          .expand((note) => note.lines)
          .map(
            (line) => CommercialLine(
              line.description,
              line.quantity,
              line.unitPrice,
              observation: line.observation,
            ),
          )
          .toList(),
    );
    final invoice = await Navigator.push<CommercialDocument>(
      context,
      MaterialPageRoute(
        builder: (_) => CommercialDocumentEditor(
          products: widget.products,
          customers: customers,
          document: draft,
          createAsNew: true,
        ),
      ),
    );
    if (invoice == null) return;
    setState(() {
      documents.insert(0, invoice);
      selectedDeliveryNotes.clear();
      selectingDeliveryNotes = false;
    });
    await _rememberCustomer(invoice);
    await _save();
    unawaited(
      _logActivity(
        'delivery_notes_invoiced',
        '${selected.length} bordereau(x) transformé(s) en ${invoice.number}',
        metadata: {
          'delivery_note_numbers': selected.map((note) => note.number).toList(),
          'invoice_number': invoice.number,
        },
      ),
    );
  }

  void _toggleDeliveryNoteSelection() {
    setState(() {
      selectingDeliveryNotes = !selectingDeliveryNotes;
      selectedDeliveryNotes.clear();
    });
  }

  void _selectDeliveryNote(CommercialDocument document) {
    if (selectedDeliveryNotes.isNotEmpty &&
        selectedDeliveryNotes.first.client.toLowerCase() !=
            document.client.toLowerCase()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Sélectionnez uniquement les bordereaux du même client.',
          ),
        ),
      );
      return;
    }
    setState(() {
      if (selectedDeliveryNotes.contains(document)) {
        selectedDeliveryNotes.remove(document);
      } else {
        selectedDeliveryNotes.add(document);
      }
    });
  }

  Future<void> _delete(int index) async {
    setState(() => documents.removeAt(index));
    await _save();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Documents commerciaux'),
      actions: [
        if (selectingDeliveryNotes) ...[
          IconButton(
            onPressed: selectedDeliveryNotes.isEmpty
                ? null
                : _createInvoiceFromDeliveryNotes,
            tooltip: 'Créer une facture définitive',
            icon: Badge(
              isLabelVisible: selectedDeliveryNotes.isNotEmpty,
              label: Text('${selectedDeliveryNotes.length}'),
              child: const Icon(Icons.receipt_long_outlined),
            ),
          ),
          IconButton(
            onPressed: _toggleDeliveryNoteSelection,
            tooltip: 'Annuler la sélection',
            icon: const Icon(Icons.close),
          ),
        ] else
          IconButton(
            onPressed:
                documents.any(
                  (document) => document.type == 'Bordereau de livraison',
                )
                ? _toggleDeliveryNoteSelection
                : null,
            tooltip: 'Sélectionner des bordereaux',
            icon: const Icon(Icons.playlist_add_check_outlined),
          ),
        IconButton(
          onPressed: _configureDocumentImages,
          tooltip: 'En-tete et pied de page',
          icon: const Icon(Icons.branding_watermark_outlined),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton.extended(
      onPressed: _create,
      icon: const Icon(Icons.add),
      label: const Text('Nouveau document'),
    ),
    body: documents.isEmpty
        ? const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.description_outlined,
                  size: 65,
                  color: Colors.black26,
                ),
                SizedBox(height: 12),
                Text('Aucun document commercial'),
              ],
            ),
          )
        : ListView.separated(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 90),
            itemCount: documents.length,
            separatorBuilder: (_, _) => const SizedBox(height: 10),
            itemBuilder: (_, index) {
              final document = documents[index];
              final isDeliveryNote = document.type == 'Bordereau de livraison';
              final isSelected = selectedDeliveryNotes.contains(document);
              return Card(
                child: ListTile(
                  onTap: selectingDeliveryNotes
                      ? (isDeliveryNote
                            ? () => _selectDeliveryNote(document)
                            : null)
                      : () => _actions(document, index),
                  contentPadding: const EdgeInsets.all(14),
                  leading: selectingDeliveryNotes
                      ? Checkbox(
                          value: isSelected,
                          onChanged: isDeliveryNote
                              ? (_) => _selectDeliveryNote(document)
                              : null,
                        )
                      : CircleAvatar(
                          backgroundColor: _green.withValues(alpha: .12),
                          child: const Icon(
                            Icons.description_outlined,
                            color: _green,
                          ),
                        ),
                  title: Text(
                    '${document.type} • ${document.number}',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${document.client}\n${document.createdAt.day.toString().padLeft(2, '0')}/${document.createdAt.month.toString().padLeft(2, '0')}/${document.createdAt.year}',
                  ),
                  isThreeLine: true,
                  trailing: document.type == 'Bordereau de livraison'
                      ? const Text(
                          'Sans montant',
                          style: TextStyle(fontWeight: FontWeight.w700),
                        )
                      : Text(
                          '${money(document.total)} F',
                          style: const TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              );
            },
          ),
  );

  Future<void> _configureDocumentImages() async {
    final prefs = await SharedPreferences.getInstance();
    Uint8List? header = _decodeStoredImage(prefs.getString(_headerImageKey));
    Uint8List? footer = _decodeStoredImage(prefs.getString(_footerImageKey));
    Uint8List? stamp = _decodeStoredImage(prefs.getString(_stampImageKey));
    Uint8List? signature = _decodeStoredImage(
      prefs.getString(_signatureImageKey),
    );
    String template = prefs.getString(_templateKey) ?? 'Classique';
    bool showShopName = prefs.getBool(_showShopNameKey) ?? true;
    double headerHeight = prefs.getDouble(_headerHeightKey) ?? 82;
    double footerHeight = prefs.getDouble(_footerHeightKey) ?? 58;
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              18,
              0,
              18,
              18 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Presentation des documents',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Personnalisez les images qui seront placees automatiquement sur vos documents PDF.',
                  ),
                  const SizedBox(height: 18),
                  DropdownButtonFormField<String>(
                    initialValue: template,
                    decoration: const InputDecoration(
                      labelText: 'Modele de document',
                      prefixIcon: Icon(Icons.dashboard_customize_outlined),
                      border: OutlineInputBorder(),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'Classique',
                        child: Text('Classique - vert professionnel'),
                      ),
                      DropdownMenuItem(
                        value: 'Moderne',
                        child: Text('Moderne - bleu dynamique'),
                      ),
                      DropdownMenuItem(
                        value: 'Simple',
                        child: Text('Simple - noir et blanc'),
                      ),
                    ],
                    onChanged: (value) async {
                      if (value == null) return;
                      await prefs.setString(_templateKey, value);
                      setSheetState(() => template = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text(
                      'Afficher le nom de la boutique',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text(
                      'Masquez-le si le nom figure deja dans votre image d\'en-tete.',
                    ),
                    value: showShopName,
                    onChanged: (value) async {
                      await prefs.setBool(_showShopNameKey, value);
                      setSheetState(() => showShopName = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  _documentImageSetting(
                    title: 'Image d\'en-tete',
                    image: header,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _headerImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => header = bytes);
                    },
                    onRemove: header == null
                        ? null
                        : () async {
                            await prefs.remove(_headerImageKey);
                            setSheetState(() => header = null);
                          },
                  ),
                  if (header != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Hauteur de l\'en-tete : ${headerHeight.round()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Slider(
                      value: headerHeight,
                      min: 40,
                      max: 170,
                      divisions: 13,
                      label: '${headerHeight.round()}',
                      onChanged: (value) {
                        setSheetState(() => headerHeight = value);
                      },
                      onChangeEnd: (value) async {
                        await prefs.setDouble(_headerHeightKey, value);
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Image de pied de page',
                    image: footer,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _footerImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => footer = bytes);
                    },
                    onRemove: footer == null
                        ? null
                        : () async {
                            await prefs.remove(_footerImageKey);
                            setSheetState(() => footer = null);
                          },
                  ),
                  if (footer != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Hauteur du pied de page : ${footerHeight.round()}',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    Slider(
                      value: footerHeight,
                      min: 30,
                      max: 130,
                      divisions: 10,
                      label: '${footerHeight.round()}',
                      onChanged: (value) {
                        setSheetState(() => footerHeight = value);
                      },
                      onChangeEnd: (value) async {
                        await prefs.setDouble(_footerHeightKey, value);
                      },
                    ),
                  ],
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Cachet de la boutique',
                    image: stamp,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _stampImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => stamp = bytes);
                    },
                    onRemove: stamp == null
                        ? null
                        : () async {
                            await prefs.remove(_stampImageKey);
                            setSheetState(() => stamp = null);
                          },
                  ),
                  const SizedBox(height: 14),
                  _documentImageSetting(
                    title: 'Signature',
                    image: signature,
                    onImport: () async {
                      final bytes = await _pickDocumentImage();
                      if (bytes == null) return;
                      await prefs.setString(
                        _signatureImageKey,
                        base64Encode(bytes),
                      );
                      setSheetState(() => signature = bytes);
                    },
                    onRemove: signature == null
                        ? null
                        : () async {
                            await prefs.remove(_signatureImageKey);
                            setSheetState(() => signature = null);
                          },
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(sheetContext),
                    child: const Text('Terminer'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _documentImageSetting({
    required String title,
    required Uint8List? image,
    required Future<void> Function() onImport,
    required Future<void> Function()? onRemove,
  }) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          if (image != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(image, height: 90, fit: BoxFit.contain),
            )
          else
            const SizedBox(
              height: 70,
              child: Center(child: Text('Aucune image importee')),
            ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onImport,
                  icon: const Icon(Icons.image_outlined),
                  label: Text(image == null ? 'Importer' : 'Remplacer'),
                ),
              ),
              if (onRemove != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: onRemove,
                  tooltip: 'Supprimer',
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                ),
              ],
            ],
          ),
        ],
      ),
    ),
  );

  Future<Uint8List?> _pickDocumentImage() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
      withData: true,
    );
    if (result == null) return null;
    final file = result.files.single;
    return file.bytes ??
        (file.path == null ? null : File(file.path!).readAsBytes());
  }

  Uint8List? _decodeStoredImage(String? encoded) {
    if (encoded == null || encoded.isEmpty) return null;
    try {
      return base64Decode(encoded);
    } catch (_) {
      return null;
    }
  }

  void _actions(CommercialDocument document, int index) {
    final nextType = _nextDocumentType(document.type);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                '${document.type} ${document.number}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text('${document.client} • ${money(document.total)} F'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined, color: _green),
              title: const Text('Modifier le document'),
              onTap: () {
                Navigator.pop(sheetContext);
                _edit(document, index);
              },
            ),
            if (document.type == 'Facture définitive' ||
                document.type == 'Facture pro forma')
              ListTile(
                leading: const Icon(Icons.copy_outlined, color: _orange),
                title: const Text('Dupliquer la facture'),
                subtitle: const Text('Créer une nouvelle facture modifiable'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _duplicateInvoice(document);
                },
              ),
            if (nextType != null)
              ListTile(
                leading: const Icon(Icons.upgrade_outlined, color: _orange),
                title: Text('Créer : $nextType'),
                subtitle: const Text('Reprendre le client et les articles'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _evolve(document);
                },
              ),
            ListTile(
              leading: const Icon(Icons.print_outlined, color: _green),
              title: const Text('Imprimer ou enregistrer en PDF'),
              onTap: () {
                Navigator.pop(sheetContext);
                _printDocument(document);
              },
            ),
            ListTile(
              leading: const Icon(Icons.share_outlined, color: _green),
              title: const Text('Partager le PDF'),
              onTap: () {
                Navigator.pop(sheetContext);
                _shareDocument(document);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: Color(0xFFD56A4D),
              ),
              title: const Text('Supprimer'),
              onTap: () {
                Navigator.pop(sheetContext);
                _delete(index);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<Uint8List> _pdfBytes(CommercialDocument document) async {
    final prefs = await SharedPreferences.getInstance();
    final shop = prefs.getString('shop_name') ?? 'MONCOMMERCE';
    final phone = prefs.getString('shop_phone') ?? '';
    final address = prefs.getString('shop_address') ?? '';
    final isDeliveryNote = document.type == 'Bordereau de livraison';
    final headerBytes = _decodeStoredImage(prefs.getString(_headerImageKey));
    final footerBytes = _decodeStoredImage(prefs.getString(_footerImageKey));
    final stampBytes = _decodeStoredImage(prefs.getString(_stampImageKey));
    final signatureBytes = _decodeStoredImage(
      prefs.getString(_signatureImageKey),
    );
    final template = prefs.getString(_templateKey) ?? 'Classique';
    final showShopName = prefs.getBool(_showShopNameKey) ?? true;
    final headerHeight = (prefs.getDouble(_headerHeightKey) ?? 82).clamp(
      40.0,
      170.0,
    );
    final footerHeight = (prefs.getDouble(_footerHeightKey) ?? 58).clamp(
      30.0,
      130.0,
    );
    final accentColor = switch (template) {
      'Moderne' => PdfColors.blue700,
      'Simple' => PdfColors.grey800,
      _ => PdfColors.green800,
    };
    final tableHeaderColor = template == 'Simple'
        ? PdfColors.grey200
        : accentColor;
    final tableHeaderTextColor = template == 'Simple'
        ? PdfColors.black
        : PdfColors.white;
    final headerImage = headerBytes == null
        ? null
        : pw.MemoryImage(headerBytes);
    final footerImage = footerBytes == null
        ? null
        : pw.MemoryImage(footerBytes);
    final stampImage = stampBytes == null ? null : pw.MemoryImage(stampBytes);
    final signatureImage = signatureBytes == null
        ? null
        : pw.MemoryImage(signatureBytes);
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: headerImage == null
            ? null
            : (context) {
                if (context.pageNumber != 1) return pw.SizedBox();
                return pw.SizedBox(
                  height: headerHeight + 14,
                  child: pw.Transform.translate(
                    offset: const PdfPoint(-36, 0),
                    child: pw.OverflowBox(
                      minWidth: PdfPageFormat.a4.width,
                      maxWidth: PdfPageFormat.a4.width,
                      alignment: pw.Alignment.topLeft,
                      child: pw.SizedBox(
                        width: PdfPageFormat.a4.width,
                        height: headerHeight,
                        child: pw.Center(
                          child: pw.Image(headerImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                );
              },
        footer: footerImage == null
            ? null
            : (context) {
                final isFirstPageOfMultiPage =
                    context.pagesCount > 1 && context.pageNumber == 1;
                if (isFirstPageOfMultiPage) return pw.SizedBox();
                return pw.SizedBox(
                  height: footerHeight + 10,
                  child: pw.Transform.translate(
                    offset: const PdfPoint(-36, -36),
                    child: pw.OverflowBox(
                      minWidth: PdfPageFormat.a4.width,
                      maxWidth: PdfPageFormat.a4.width,
                      alignment: pw.Alignment.bottomLeft,
                      child: pw.SizedBox(
                        width: PdfPageFormat.a4.width,
                        height: footerHeight,
                        child: pw.Center(
                          child: pw.Image(footerImage, fit: pw.BoxFit.contain),
                        ),
                      ),
                    ),
                  ),
                );
              },
        build: (_) => [
          pw.Container(
            padding: template == 'Moderne'
                ? const pw.EdgeInsets.all(14)
                : pw.EdgeInsets.zero,
            decoration: template == 'Moderne'
                ? pw.BoxDecoration(
                    color: PdfColors.blue50,
                    border: pw.Border(
                      left: pw.BorderSide(color: accentColor, width: 5),
                    ),
                  )
                : null,
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    if (showShopName)
                      pw.Text(
                        shop.toUpperCase(),
                        style: pw.TextStyle(
                          fontSize: 20,
                          color: template == 'Simple' ? null : accentColor,
                          fontWeight: pw.FontWeight.bold,
                        ),
                      ),
                    if (phone.isNotEmpty) pw.Text('Tel : $phone'),
                    if (address.isNotEmpty) pw.Text(address),
                  ],
                ),
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.end,
                  children: [
                    pw.Text(
                      _pdfType(document.type),
                      style: pw.TextStyle(
                        fontSize: 18,
                        color: template == 'Simple' ? null : accentColor,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text('N ${document.number}'),
                    pw.Text(
                      'Date : ${document.createdAt.day.toString().padLeft(2, '0')}/${document.createdAt.month.toString().padLeft(2, '0')}/${document.createdAt.year}',
                    ),
                    if (document.purchaseOrderNumber.isNotEmpty)
                      pw.Text(
                        'N° Bon de commande : ${document.purchaseOrderNumber}',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                  ],
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 24),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(12),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: PdfColors.grey400),
            ),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'CLIENT',
                  style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                ),
                pw.Text(document.client),
                if (document.phone.isNotEmpty)
                  pw.Text('Tel : ${document.phone}'),
                if (document.address.isNotEmpty) pw.Text(document.address),
              ],
            ),
          ),
          if (document.object.isNotEmpty) ...[
            pw.SizedBox(height: 12),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 9,
              ),
              decoration: pw.BoxDecoration(
                color: template == 'Simple' ? null : PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey400),
              ),
              child: pw.RichText(
                text: pw.TextSpan(
                  children: [
                    pw.TextSpan(
                      text: 'OBJET : ',
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                    pw.TextSpan(text: document.object),
                  ],
                ),
              ),
            ),
          ],
          pw.SizedBox(height: 20),
          pw.TableHelper.fromTextArray(
            headers: isDeliveryNote
                ? const ['Description', 'Quantite livree', 'Observation']
                : const ['Description', 'Qte', 'Prix unitaire', 'Total'],
            data: document.lines
                .map(
                  (line) => isDeliveryNote
                      ? [line.description, '${line.quantity}', line.observation]
                      : [
                          line.description,
                          '${line.quantity}',
                          '${money(line.unitPrice)} F',
                          '${money(line.total)} F',
                        ],
                )
                .toList(),
            headerStyle: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: tableHeaderTextColor,
            ),
            headerDecoration: pw.BoxDecoration(color: tableHeaderColor),
            border: template == 'Simple'
                ? pw.TableBorder.all(color: PdfColors.grey500, width: .5)
                : null,
            cellPadding: const pw.EdgeInsets.all(8),
          ),
          if (!isDeliveryNote) ...[
            pw.SizedBox(height: 16),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Container(
                padding: const pw.EdgeInsets.all(12),
                decoration: pw.BoxDecoration(
                  color: template == 'Moderne' ? PdfColors.blue50 : null,
                  border: pw.Border.all(color: accentColor, width: 1.5),
                ),
                child: pw.Text(
                  'TOTAL : ${money(document.total)} FCFA',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              'Arrete le present document a la somme de : ${_amountInWords(document.total)} francs CFA.',
              style: pw.TextStyle(fontSize: 10, fontStyle: pw.FontStyle.italic),
            ),
          ],
          if (document.notes.isNotEmpty) ...[
            pw.SizedBox(height: 20),
            pw.Text('Notes : ${document.notes}'),
          ],
          pw.SizedBox(height: 28),
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  children: [
                    pw.Text(
                      'Le Receptionniste',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 111),
                  ],
                ),
              ),
              pw.SizedBox(width: 28),
              pw.SizedBox(
                width: 190,
                child: pw.Column(
                  children: [
                    pw.Text(
                      'Le Responsable',
                      style: pw.TextStyle(
                        fontSize: 12,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 6),
                    pw.SizedBox(
                      width: 170,
                      height: 105,
                      child: pw.Stack(
                        alignment: pw.Alignment.center,
                        children: [
                          if (stampImage != null)
                            pw.SizedBox(
                              width: 105,
                              height: 100,
                              child: pw.Image(
                                stampImage,
                                fit: pw.BoxFit.contain,
                              ),
                            ),
                          if (signatureImage != null)
                            pw.Transform.translate(
                              offset: const PdfPoint(-28, -6),
                              child: pw.SizedBox(
                                width: 155,
                                height: 75,
                                child: pw.Image(
                                  signatureImage,
                                  fit: pw.BoxFit.contain,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return pdf.save();
  }

  String _pdfType(String type) => switch (type) {
    'Facture pro forma' => 'FACTURE PRO FORMA',
    'Facture définitive' => 'FACTURE DEFINITIVE',
    'Bon de commande' => 'BON DE COMMANDE',
    'Bordereau de livraison' => 'BORDEREAU DE LIVRAISON',
    _ => 'DEVIS',
  };

  String _amountInWords(int amount) {
    if (amount == 0) return 'zero';
    if (amount < 0) return 'moins ${_amountInWords(-amount)}';
    final parts = <String>[];
    void addScale(int value, int scale, String singular, String plural) {
      if (value < scale) return;
      final count = value ~/ scale;
      if (count == 1 && scale == 1000) {
        parts.add(singular);
      } else {
        parts.add('${_underThousand(count)} ${count > 1 ? plural : singular}');
      }
    }

    var rest = amount;
    if (rest >= 1000000000) {
      addScale(rest, 1000000000, 'milliard', 'milliards');
      rest %= 1000000000;
    }
    if (rest >= 1000000) {
      addScale(rest, 1000000, 'million', 'millions');
      rest %= 1000000;
    }
    if (rest >= 1000) {
      addScale(rest, 1000, 'mille', 'mille');
      rest %= 1000;
    }
    if (rest > 0) parts.add(_underThousand(rest));
    return parts.join(' ');
  }

  String _underThousand(int value) {
    if (value < 100) return _underHundred(value);
    final hundreds = value ~/ 100;
    final rest = value % 100;
    final prefix = hundreds == 1 ? 'cent' : '${_underHundred(hundreds)} cent';
    return rest == 0 ? prefix : '$prefix ${_underHundred(rest)}';
  }

  String _underHundred(int value) {
    const units = [
      'zero',
      'un',
      'deux',
      'trois',
      'quatre',
      'cinq',
      'six',
      'sept',
      'huit',
      'neuf',
      'dix',
      'onze',
      'douze',
      'treize',
      'quatorze',
      'quinze',
      'seize',
    ];
    if (value <= 16) return units[value];
    if (value < 20) return 'dix-${units[value - 10]}';
    if (value < 70) {
      const tens = [
        '',
        '',
        'vingt',
        'trente',
        'quarante',
        'cinquante',
        'soixante',
      ];
      final ten = value ~/ 10;
      final unit = value % 10;
      if (unit == 0) return tens[ten];
      return '${tens[ten]}${unit == 1 ? ' et ' : '-'}${units[unit]}';
    }
    if (value < 80) {
      final rest = value - 60;
      return 'soixante${rest == 11 ? ' et ' : '-'}${_underHundred(rest)}';
    }
    final rest = value - 80;
    if (rest == 0) return 'quatre-vingts';
    return 'quatre-vingt-${_underHundred(rest)}';
  }

  Future<void> _printDocument(CommercialDocument document) async =>
      Printing.layoutPdf(
        name: '${document.number}.pdf',
        onLayout: (_) => _pdfBytes(document),
      );

  Future<void> _shareDocument(CommercialDocument document) async =>
      Printing.sharePdf(
        bytes: await _pdfBytes(document),
        filename: '${document.number}.pdf',
      );
}

class CommercialDocumentEditor extends StatefulWidget {
  const CommercialDocumentEditor({
    super.key,
    required this.products,
    required this.customers,
    this.document,
    this.createAsNew = false,
  });
  final List<Product> products;
  final List<CommercialCustomer> customers;
  final CommercialDocument? document;
  final bool createAsNew;

  @override
  State<CommercialDocumentEditor> createState() =>
      _CommercialDocumentEditorState();
}

class _CommercialDocumentEditorState extends State<CommercialDocumentEditor> {
  String type = 'Facture pro forma';
  final client = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final object = TextEditingController();
  final purchaseOrderNumber = TextEditingController();
  final notes = TextEditingController();
  final lines = <CommercialLine>[];

  @override
  void initState() {
    super.initState();
    final document = widget.document;
    if (document == null) return;
    type = document.type;
    client.text = document.client;
    phone.text = document.phone;
    address.text = document.address;
    object.text = document.object;
    purchaseOrderNumber.text = document.purchaseOrderNumber;
    notes.text = document.notes;
    lines.addAll(
      document.lines.map(
        (line) => CommercialLine(
          line.description,
          line.quantity,
          line.unitPrice,
          observation: line.observation,
        ),
      ),
    );
  }

  @override
  void dispose() {
    client.dispose();
    phone.dispose();
    address.dispose();
    object.dispose();
    purchaseOrderNumber.dispose();
    notes.dispose();
    super.dispose();
  }

  String _number(DateTime now) {
    final prefix = switch (type) {
      'Facture pro forma' => 'PRO',
      'Devis' => 'DEV',
      'Facture définitive' => 'FAC',
      'Bordereau de livraison' => 'BL',
      _ => 'BC',
    };
    return '$prefix-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${now.millisecondsSinceEpoch.toString().substring(8)}';
  }

  Future<CommercialCustomer?> _createCustomer() async {
    final name = TextEditingController();
    final phoneController = TextEditingController();
    final addressController = TextEditingController();
    var isCompany = false;
    final customer = await showDialog<CommercialCustomer>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Nouveau client ou entreprise'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Client')),
                    ButtonSegment(value: true, label: Text('Entreprise')),
                  ],
                  selected: {isCompany},
                  onSelectionChanged: (value) =>
                      setDialogState(() => isCompany = value.first),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: name,
                  decoration: InputDecoration(
                    labelText: isCompany
                        ? 'Nom de l’entreprise'
                        : 'Nom du client',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Téléphone'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(labelText: 'Adresse'),
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
                Navigator.pop(
                  dialogContext,
                  CommercialCustomer(
                    name: name.text.trim(),
                    phone: phoneController.text.trim(),
                    address: addressController.text.trim(),
                    isCompany: isCompany,
                  ),
                );
              },
              child: const Text('Utiliser ce contact'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    phoneController.dispose();
    addressController.dispose();
    return customer;
  }

  Future<void> _chooseCustomer() async {
    final customer = await showModalBottomSheet<CommercialCustomer>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              title: Text(
                'Importer un client ou une entreprise',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text('Les coordonnées sont reprises dans le document.'),
            ),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1_outlined),
              title: const Text('Créer un client ou une entreprise'),
              onTap: () => Navigator.pop(
                sheetContext,
                CommercialCustomer(
                  name: '',
                  phone: '',
                  address: '',
                  isCompany: false,
                ),
              ),
            ),
            if (widget.customers.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(18, 8, 18, 18),
                child: Text('Aucun contact enregistré pour le moment.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: widget.customers.length,
                  itemBuilder: (_, index) {
                    final item = widget.customers[index];
                    return ListTile(
                      leading: Icon(
                        item.isCompany
                            ? Icons.business_outlined
                            : Icons.person_outline,
                      ),
                      title: Text(item.name),
                      subtitle: Text(
                        [
                          item.phone,
                          item.address,
                        ].where((value) => value.isNotEmpty).join(' • '),
                      ),
                      onTap: () => Navigator.pop(sheetContext, item),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
    if (customer == null || !mounted) return;
    final selected = customer.name.isEmpty ? await _createCustomer() : customer;
    if (selected == null || !mounted) return;
    setState(() {
      final alreadyKnown = widget.customers.any(
        (item) => item.name.toLowerCase() == selected.name.toLowerCase(),
      );
      if (!alreadyKnown) widget.customers.add(selected);
      client.text = selected.name;
      phone.text = selected.phone;
      address.text = selected.address;
    });
  }

  Future<void> _addLine([int? editIndex]) async {
    Product? selected;
    final existing = editIndex == null ? null : lines[editIndex];
    final description = TextEditingController(text: existing?.description);
    final quantity = TextEditingController(
      text: existing?.quantity.toString() ?? '1',
    );
    final price = TextEditingController(text: existing?.unitPrice.toString());
    final observation = TextEditingController(text: existing?.observation);
    final line = await showDialog<CommercialLine>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            editIndex == null ? 'Ajouter un article' : 'Modifier l\'article',
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<Product?>(
                  isExpanded: true,
                  initialValue: selected,
                  decoration: const InputDecoration(
                    labelText: 'Produit existant (facultatif)',
                  ),
                  items: [
                    const DropdownMenuItem<Product?>(
                      value: null,
                      child: Text('Saisie libre'),
                    ),
                    ...widget.products.map(
                      (product) => DropdownMenuItem<Product?>(
                        value: product,
                        child: Text(product.name),
                      ),
                    ),
                  ],
                  onChanged: (product) {
                    setDialogState(() => selected = product);
                    if (product != null) {
                      description.text = product.name;
                      if (type != 'Bordereau de livraison') {
                        price.text = product.price.toString();
                      }
                    }
                  },
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: description,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: quantity,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Quantité'),
                ),
                if (type != 'Bordereau de livraison') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: price,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Prix unitaire (FCFA)',
                    ),
                  ),
                ],
                if (type == 'Bordereau de livraison') ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: observation,
                    maxLines: 2,
                    decoration: const InputDecoration(
                      labelText: 'Observation',
                      hintText: 'Ex. Livré en bon état',
                    ),
                  ),
                ],
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
                final qty = int.tryParse(quantity.text) ?? 0;
                final unitPrice = type == 'Bordereau de livraison'
                    ? existing?.unitPrice ?? 0
                    : int.tryParse(price.text) ?? 0;
                if (description.text.trim().isEmpty || qty < 1) return;
                Navigator.pop(
                  dialogContext,
                  CommercialLine(
                    description.text.trim(),
                    qty,
                    unitPrice,
                    observation: observation.text.trim(),
                  ),
                );
              },
              child: Text(editIndex == null ? 'Ajouter' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
    if (line != null) {
      setState(() {
        if (editIndex == null) {
          lines.add(line);
        } else {
          lines[editIndex] = line;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = lines.fold(0, (sum, line) => sum + line.total);
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.document == null || widget.createAsNew
              ? 'Nouveau document'
              : 'Modifier le document',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          DropdownButtonFormField<String>(
            initialValue: type,
            decoration: const InputDecoration(labelText: 'Type de document'),
            items: const [
              DropdownMenuItem(
                value: 'Facture pro forma',
                child: Text('Facture pro forma'),
              ),
              DropdownMenuItem(value: 'Devis', child: Text('Devis')),
              DropdownMenuItem(
                value: 'Facture définitive',
                child: Text('Facture définitive'),
              ),
              DropdownMenuItem(
                value: 'Bon de commande',
                child: Text('Bon de commande'),
              ),
              DropdownMenuItem(
                value: 'Bordereau de livraison',
                child: Text('Bordereau de livraison'),
              ),
            ],
            onChanged: (value) => setState(() => type = value!),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: client,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              labelText: 'Nom du client ou entreprise',
              prefixIcon: const Icon(Icons.person_outline),
              suffixIcon: IconButton(
                onPressed: _chooseCustomer,
                tooltip: 'Importer ou créer un contact',
                icon: const Icon(Icons.contacts_outlined),
              ),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Téléphone du client'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: address,
            decoration: const InputDecoration(labelText: 'Adresse du client'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: object,
            decoration: const InputDecoration(
              labelText: 'Objet du document',
              prefixIcon: Icon(Icons.subject_outlined),
            ),
          ),
          if (type == 'Facture définitive' ||
              type == 'Bordereau de livraison') ...[
            const SizedBox(height: 10),
            TextField(
              controller: purchaseOrderNumber,
              decoration: const InputDecoration(
                labelText: 'N° du Bon de Commande',
                prefixIcon: Icon(Icons.numbers_outlined),
              ),
            ),
          ],
          const SizedBox(height: 18),
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Articles',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _addLine(),
                icon: const Icon(Icons.add),
                label: const Text('Ajouter'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (lines.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: Text('Ajoutez au moins un article')),
              ),
            )
          else
            ...List.generate(lines.length, (index) {
              final line = lines[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    title: Text(
                      line.description,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                    subtitle: Text(
                      type == 'Bordereau de livraison'
                          ? '${line.quantity} livré(s)${line.observation.isEmpty ? '' : ' • ${line.observation}'}'
                          : '${line.quantity} × ${money(line.unitPrice)} F',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          onPressed: () => _addLine(index),
                          tooltip: 'Modifier',
                          icon: const Icon(Icons.edit_outlined, color: _green),
                        ),
                        if (type != 'Bordereau de livraison')
                          Text(
                            '${money(line.total)} F',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        IconButton(
                          onPressed: () =>
                              setState(() => lines.removeAt(index)),
                          icon: const Icon(
                            Icons.close,
                            color: Color(0xFFD56A4D),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          const SizedBox(height: 10),
          TextField(
            controller: notes,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Conditions ou notes (facultatif)',
            ),
          ),
          if (type != 'Bordereau de livraison') ...[
            const SizedBox(height: 18),
            Card(
              color: _green.withValues(alpha: .10),
              child: ListTile(
                title: const Text(
                  'TOTAL A PAYER',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
                trailing: Text(
                  '${money(total)} FCFA',
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              onPressed: client.text.trim().isEmpty || lines.isEmpty
                  ? null
                  : () {
                      final now = DateTime.now();
                      final existing = widget.document;
                      Navigator.pop(
                        context,
                        CommercialDocument(
                          type: type,
                          number: existing == null || widget.createAsNew
                              ? _number(now)
                              : existing.number,
                          client: client.text.trim(),
                          phone: phone.text.trim(),
                          address: address.text.trim(),
                          object: object.text.trim(),
                          purchaseOrderNumber: purchaseOrderNumber.text.trim(),
                          notes: notes.text.trim(),
                          createdAt: existing == null || widget.createAsNew
                              ? now
                              : existing.createdAt,
                          lines: List.of(lines),
                        ),
                      );
                    },
              icon: const Icon(Icons.save_outlined),
              label: Text(
                widget.document == null || widget.createAsNew
                    ? 'Créer le document'
                    : 'Enregistrer les modifications',
              ),
            ),
          ),
        ],
      ),
    );
  }
}
