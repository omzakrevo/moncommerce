part of '../main.dart';

class MorePage extends StatelessWidget {
  const MorePage({
    super.key,
    required this.expenses,
    required this.expenseRecords,
    required this.revenue,
    required this.salesCount,
    required this.credits,
    required this.sales,
    required this.products,
    required this.onExpense,
    required this.onCredit,
    required this.onLogout,
    required this.onDataChanged,
    required this.isSuperAdmin,
    required this.onOpenOnlineOrders,
    required this.onPublishStorefront,
    required this.storageUserId,
    required this.shopName,
  });
  final int expenses;
  final List<ExpenseRecord> expenseRecords;
  final int revenue;
  final int salesCount;
  final List<Credit> credits;
  final List<SaleRecord> sales;
  final List<Product> products;
  final ValueChanged<ExpenseRecord> onExpense;
  final ValueChanged<Credit> onCredit;
  final Future<void> Function() onLogout;
  final Future<void> Function() onDataChanged;
  final bool isSuperAdmin;
  final VoidCallback onOpenOnlineOrders;
  final Future<void> Function() onPublishStorefront;
  final String storageUserId, shopName;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.only(bottom: 25),
    children: [
      const PageHeader('Gestion', 'Toutes les fonctions de votre boutique'),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Column(
          children: [
            _managementCard(
              context,
              'Dépenses du jour',
              '${money(expenses)} FCFA',
              Icons.payments_outlined,
              const Color(0xFFD56A4D),
              () => _expenseDialog(context),
              onOpen: () => _showExpenses(context),
            ),
            const SizedBox(height: 12),
            _managementCard(
              context,
              'Crédits clients',
              '${credits.length} dossiers • ${money(credits.fold(0, (s, c) => s + c.remaining))} F',
              Icons.people_outline,
              _orange,
              () => _creditDialog(context),
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CreditsPage(credits: credits, onChanged: onDataChanged),
                ),
              ),
            ),
            const SizedBox(height: 22),
            Card(
              child: Column(
                children: [
                  _menu(
                    Icons.language_rounded,
                    'Boutique en ligne',
                    'Partager le catalogue et gérer les commandes',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => StorefrontSettingsPage(
                          products: products,
                          onOpenOrders: onOpenOnlineOrders,
                          onPublish: onPublishStorefront,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.bar_chart_rounded,
                    'Rapports et statistiques',
                    'Analysez vos performances',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => ReportsPage(
                          revenue: revenue,
                          expenses: expenses,
                          salesCount: salesCount,
                          creditTotal: credits.fold(
                            0,
                            (s, c) => s + c.remaining,
                          ),
                          sales: sales,
                          products: products,
                          expenseRecords: expenseRecords,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.description_outlined,
                    'Documents commerciaux',
                    'Pro forma, devis, factures et commandes',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            CommercialDocumentsPage(products: products),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.local_shipping_outlined,
                    'Fournisseurs',
                    'Gérez vos approvisionnements',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const DirectoryPage(
                          title: 'Fournisseurs',
                          storageKey: 'suppliers_v1',
                          icon: Icons.local_shipping_outlined,
                          nameLabel: 'Nom du fournisseur',
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.account_balance_wallet_outlined,
                    'Dettes fournisseurs',
                    'Crédits reçus et paiements',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const SupplierDebtsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.store_mall_directory_outlined,
                    'Ma boutique',
                    'Informations et réglages',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const ShopSettingsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.people_alt_outlined,
                    'Utilisateurs',
                    'Caissiers et gestionnaires',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => LocalStaffPage(
                          shopId: storageUserId,
                          shopName: shopName,
                        ),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.cloud_upload_outlined,
                    'Sauvegarde cloud',
                    'Exporter ou restaurer vos données',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const BackupPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.workspace_premium_outlined,
                    'Licence et abonnement',
                    'Formule, activation et expiration',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const LicensePage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  _menu(
                    Icons.notifications_outlined,
                    'Notifications et mises à jour',
                    'Messages officiels de MonCommerce',
                    () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => const AnnouncementsPage(),
                      ),
                    ),
                  ),
                  const Divider(height: 1, indent: 65),
                  if (isSuperAdmin) ...[
                    _menu(
                      Icons.monitor_heart_outlined,
                      'Monitoring et journaux',
                      'Présence, actions et erreurs des utilisateurs',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminMonitoringPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                    _menu(
                      Icons.campaign_outlined,
                      'Diffusion aux utilisateurs',
                      'Publier une notification ou une version',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AdminBroadcastPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                    _menu(
                      Icons.admin_panel_settings_outlined,
                      'Administration des licences',
                      'Créer et révoquer les clés clients',
                      () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const SuperAdminLicensesPage(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 65),
                  ],
                  ListTile(
                    leading: const Icon(
                      Icons.logout_rounded,
                      color: Color(0xFFD56A4D),
                    ),
                    title: const Text(
                      'Se déconnecter',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: const Text('Fermer la session de cette boutique'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _confirmLogout(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _managementCard(
    BuildContext context,
    String title,
    String value,
    IconData icon,
    Color color,
    VoidCallback tap, {
    VoidCallback? onOpen,
  }) => Card(
    child: ListTile(
      onTap: onOpen,
      contentPadding: const EdgeInsets.all(15),
      leading: CircleAvatar(
        radius: 24,
        backgroundColor: color.withValues(alpha: .12),
        child: Icon(icon, color: color),
      ),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      subtitle: Text(value),
      trailing: FilledButton.tonal(
        onPressed: tap,
        child: const Text('Ajouter'),
      ),
    ),
  );
  Widget _menu(
    IconData icon,
    String title,
    String subtitle,
    VoidCallback onTap,
  ) => ListTile(
    leading: Icon(icon, color: _green),
    title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
    subtitle: Text(subtitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: onTap,
  );

  void _showExpenses(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (_) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 5, 22, 30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Dépenses du jour',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
              ),
              subtitle: Text('Total cumulé enregistré'),
            ),
            ...expenseRecords
                .take(8)
                .map(
                  (item) => Card(
                    child: ListTile(
                      leading: const CircleAvatar(
                        child: Icon(Icons.payments_outlined),
                      ),
                      title: Text(
                        item.nature,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      subtitle: Text(item.createdAt),
                      trailing: Text(
                        '${money(item.amount)} F',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ),
            if (expenseRecords.isEmpty)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Text('Aucune dépense détaillée enregistrée'),
              ),
          ],
        ),
      ),
    );
  }

  void _confirmLogout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Se déconnecter ?'),
        content: const Text(
          'Vos ventes restent enregistrées sur cet appareil.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(dialogContext);
              await onLogout();
            },
            child: const Text('Se déconnecter'),
          ),
        ],
      ),
    );
  }

  void _expenseDialog(BuildContext context) {
    final amount = TextEditingController();
    final nature = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouvelle dépense'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nature,
              decoration: const InputDecoration(
                labelText: 'Nature de la dépense',
                hintText: 'Transport, loyer, carburant…',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Montant (FCFA)',
                prefixIcon: Icon(Icons.payments_outlined),
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
              if (nature.text.trim().isEmpty) return;
              final now = DateTime.now();
              onExpense(
                ExpenseRecord(
                  nature.text.trim(),
                  int.tryParse(amount.text) ?? 0,
                  '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')} ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                ),
              );
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }

  void _creditDialog(BuildContext context) {
    final name = TextEditingController();
    final amount = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Nouveau crédit'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              decoration: const InputDecoration(labelText: 'Nom du client'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: amount,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Montant (FCFA)'),
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
              if (name.text.isEmpty) return;
              onCredit(
                Credit(
                  name.text,
                  '',
                  int.tryParse(amount.text) ?? 0,
                  'À définir',
                ),
              );
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    );
  }
}

class ShopSettingsPage extends StatefulWidget {
  const ShopSettingsPage({super.key});
  @override
  State<ShopSettingsPage> createState() => _ShopSettingsPageState();
}

class _ShopSettingsPageState extends State<ShopSettingsPage> {
  final name = TextEditingController();
  final phone = TextEditingController();
  final address = TextEditingController();
  final city = TextEditingController();
  double? latitude;
  double? longitude;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    name.text = prefs.getString('shop_name') ?? '';
    phone.text = prefs.getString('shop_phone') ?? '';
    address.text = prefs.getString('shop_address') ?? '';
    city.text = prefs.getString('shop_city') ?? '';
    if (mounted) {
      setState(() {
        latitude = prefs.getDouble('shop_latitude');
        longitude = prefs.getDouble('shop_longitude');
      });
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('shop_name', name.text.trim());
    await prefs.setString('shop_phone', phone.text.trim());
    await prefs.setString('shop_address', address.text.trim());
    await prefs.setString('shop_city', city.text.trim());
    if (latitude != null) await prefs.setDouble('shop_latitude', latitude!);
    if (longitude != null) await prefs.setDouble('shop_longitude', longitude!);
    final userId = supabase.auth.currentUser?.id;
    if (userId != null) {
      await supabase
          .from('profiles')
          .update({
            'shop_name': name.text.trim(),
            'phone': phone.text.trim(),
            'city': city.text.trim(),
          })
          .eq('id', userId);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Informations de la boutique enregistrées')),
    );
  }

  @override
  void dispose() {
    name.dispose();
    phone.dispose();
    address.dispose();
    city.dispose();
    super.dispose();
  }

  Future<void> _locate() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Autorisez la localisation dans les réglages.'),
          ),
        );
      }
      return;
    }
    final position = await Geolocator.getCurrentPosition();
    if (!mounted) return;
    setState(() {
      latitude = position.latitude;
      longitude = position.longitude;
    });
  }

  Future<void> _openMap() async {
    if (latitude == null || longitude == null) return;
    await launchUrl(
      Uri.parse(
        'https://www.google.com/maps/search/?api=1&query=$latitude,$longitude',
      ),
      mode: LaunchMode.externalApplication,
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Ma boutique')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Center(
          child: CircleAvatar(
            radius: 42,
            backgroundColor: _green,
            child: Icon(Icons.storefront, size: 42, color: Colors.white),
          ),
        ),
        const SizedBox(height: 25),
        const ReceiptPrintSettingsCard(),
        const SizedBox(height: 20),
        TextField(
          controller: name,
          decoration: const InputDecoration(
            labelText: 'Nom commercial',
            prefixIcon: Icon(Icons.store_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: phone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Téléphone',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: address,
          decoration: const InputDecoration(
            labelText: 'Adresse',
            prefixIcon: Icon(Icons.location_on_outlined),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: city,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(
            labelText: 'Ville',
            hintText: 'Ex. Ouagadougou, Bobo-Dioulasso',
            prefixIcon: Icon(Icons.location_city_outlined),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE1F1EA),
              child: Icon(Icons.map_outlined, color: _green),
            ),
            title: Text(
              latitude == null
                  ? 'Localisation non définie'
                  : '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Position GPS de la boutique'),
            onTap: latitude == null ? _locate : _openMap,
            trailing: IconButton(
              onPressed: _locate,
              icon: const Icon(Icons.my_location),
            ),
          ),
        ),
        const SizedBox(height: 22),
        SizedBox(
          height: 52,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save_outlined),
            label: const Text('Enregistrer les modifications'),
          ),
        ),
      ],
    ),
  );
}

class BackupPage extends StatefulWidget {
  const BackupPage({super.key});
  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  static const _keys = [
    'moncommerce_data_v1',
    'shop_name',
    'shop_phone',
    'shop_address',
    'shop_city',
    'suppliers_v1',
    'users_v1',
    'license_plan',
    'license_key',
    'license_expiry',
  ];

  Future<void> _export() async {
    setState(() => _busy = true);
    final prefs = await SharedPreferences.getInstance();
    final data = <String, dynamic>{
      'version': 1,
      'exportedAt': DateTime.now().toIso8601String(),
    };
    for (final key in _keys) {
      data[key] = prefs.get(key);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent('  ').convert(data)),
    );
    await SharePlus.instance.share(
      ShareParams(
        files: [
          XFile.fromData(
            bytes,
            mimeType: 'application/json',
            name: 'moncommerce-sauvegarde.json',
          ),
        ],
        subject: 'Sauvegarde MonCommerce',
        text: 'Sauvegarde de ma boutique MonCommerce',
      ),
    );
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _restore() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.single.bytes == null) return;
    try {
      final data =
          jsonDecode(utf8.decode(result.files.single.bytes!))
              as Map<String, dynamic>;
      final prefs = await SharedPreferences.getInstance();
      for (final key in _keys) {
        final value = data[key];
        if (value is String) await prefs.setString(key, value);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Sauvegarde restaurée. Redémarrez l’application.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Ce fichier de sauvegarde est invalide.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Sauvegarde cloud')),
    body: ListView(
      padding: const EdgeInsets.all(20),
      children: [
        const Icon(Icons.cloud_done_outlined, size: 75, color: _green),
        const SizedBox(height: 18),
        const Text(
          'Protégez les données de votre boutique',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 8),
        const Text(
          'Exportez votre sauvegarde vers Google Drive, OneDrive, WhatsApp ou tout autre service disponible sur le téléphone.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54),
        ),
        const SizedBox(height: 28),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFE1F1EA),
              child: Icon(Icons.cloud_upload_outlined, color: _green),
            ),
            title: const Text(
              'Créer une sauvegarde',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Ventes, produits, crédits et réglages'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _busy ? null : _export,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: const CircleAvatar(
              backgroundColor: Color(0xFFFFF3D6),
              child: Icon(Icons.restore, color: _orange),
            ),
            title: const Text(
              'Restaurer une sauvegarde',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            subtitle: const Text('Sélectionner un fichier MonCommerce JSON'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _restore,
          ),
        ),
      ],
    ),
  );
}
