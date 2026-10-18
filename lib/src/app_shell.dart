part of '../main.dart';

class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.shopName,
    required this.isSuperAdmin,
    required this.onLogout,
    this.storageUserId = 'offline',
    this.offlineMode = false,
    this.enableCloudAnnouncements = false,
    this.staffAccount,
  });
  final String shopName;
  final bool isSuperAdmin;
  final String storageUserId;
  final bool offlineMode;
  final bool enableCloudAnnouncements;
  final LocalStaffAccount? staffAccount;
  final Future<void> Function() onLogout;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  String get _storageKey => 'moncommerce_data_v2_${widget.storageUserId}';
  RealtimeChannel? _announcementChannel;
  RealtimeChannel? _ordersChannel;
  Timer? _presenceTimer;
  int _page = 0;
  int _salesCount = 0;
  int _revenue = 0;
  int _expenses = 0;
  final products = <Product>[];
  final credits = <Credit>[];
  final sales = <SaleRecord>[];
  final expenseRecords = <ExpenseRecord>[];

  @override
  void initState() {
    super.initState();
    _loadData();
    if (!widget.offlineMode && widget.staffAccount == null) {
      if (widget.enableCloudAnnouncements) _listenForAnnouncements();
      _listenForOnlineOrders();
      unawaited(_checkForUpdate());
      unawaited(_updatePresence(lastAction: 'app_active'));
      _presenceTimer = Timer.periodic(
        const Duration(minutes: 5),
        (_) => unawaited(_updatePresence(lastAction: 'heartbeat')),
      );
    }
  }

  void _listenForAnnouncements() {
    _announcementChannel = supabase
        .channel('app-announcements-${supabase.auth.currentUser?.id}')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'app_announcements',
          callback: (payload) {
            if (!mounted) return;
            final row = payload.newRecord;
            final isUpdate = row['kind'] == 'update';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 10),
                content: Text(
                  '${isUpdate ? 'Mise à jour' : 'Notification'} : ${row['title'] ?? ''}',
                ),
                action: SnackBarAction(
                  label: 'Voir',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => const AnnouncementsPage(),
                    ),
                  ),
                ),
              ),
            );
          },
        )
        .subscribe();
  }

  Future<void> _checkForUpdate() async {
    try {
      final rows = await supabase
          .from('app_announcements')
          .select('title, body, version, download_url, is_mandatory')
          .eq('kind', 'update')
          .order('created_at', ascending: false)
          .limit(1)
          .timeout(const Duration(seconds: 6));
      if (rows.isEmpty || !mounted) return;
      final update = Map<String, dynamic>.from(rows.first);
      final version = update['version']?.toString() ?? '';
      final downloadUrl = update['download_url']?.toString() ?? '';
      if (version.isEmpty ||
          downloadUrl.isEmpty ||
          !_isNewerVersion(version, _appVersion)) {
        return;
      }
      final mandatory = update['is_mandatory'] == true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog<void>(
          context: context,
          barrierDismissible: !mandatory,
          builder: (dialogContext) => AlertDialog(
            title: Text('Mise à jour $version disponible'),
            content: Text(
              '${update['body'] ?? 'Une nouvelle version de MonCommerce est disponible.'}${mandatory ? '\n\nCette mise à jour est obligatoire.' : ''}',
            ),
            actions: [
              if (!mandatory)
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Plus tard'),
                ),
              UpdateDownloadButton(downloadUrl: downloadUrl, version: version),
            ],
          ),
        );
      });
    } catch (_) {}
  }

  void _listenForOnlineOrders() {
    if (!_supabaseReady) return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null) return;
    _ordersChannel = supabase
        .channel('store-orders-$userId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'store_orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'shop_id',
            value: userId,
          ),
          callback: (payload) {
            if (!mounted) return;
            final row = payload.newRecord;
            final number = row['order_number']?.toString() ?? 'Nouvelle';
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                duration: const Duration(seconds: 12),
                content: Text(
                  '$number • ${row['customer_name'] ?? 'Client'} • ${money((row['total'] as num?)?.toInt() ?? 0)} FCFA',
                ),
                action: SnackBarAction(
                  label: 'OUVRIR',
                  onPressed: _openOnlineOrders,
                ),
              ),
            );
            unawaited(
              _localNotifications.show(
                id: number.hashCode,
                title: 'Nouvelle commande $number',
                body:
                    '${row['customer_name'] ?? 'Client'} • ${money((row['total'] as num?)?.toInt() ?? 0)} FCFA',
                notificationDetails: const NotificationDetails(
                  android: AndroidNotificationDetails(
                    'moncommerce_alerts',
                    'Notifications MonCommerce',
                    channelDescription:
                        'Annonces et mises à jour envoyées par MonCommerce',
                    importance: Importance.max,
                    priority: Priority.high,
                  ),
                ),
              ),
            );
          },
        )
        .subscribe();
  }

  @override
  void dispose() {
    _presenceTimer?.cancel();
    _shopSyncTimer?.cancel();
    final channel = _announcementChannel;
    if (channel != null) supabase.removeChannel(channel);
    final ordersChannel = _ordersChannel;
    if (ordersChannel != null) supabase.removeChannel(ordersChannel);
    super.dispose();
  }

  bool _dataReady = false;
  SharedPreferences? _shopPreferences;
  bool _syncBusy = false;
  bool _syncConflict = false;
  String? _lastPublishedCatalog;
  bool _hasLocalData = false;
  int _localGeneration = 0;
  Timer? _shopSyncTimer;
  String _syncStatus = 'Synchronisation en attente';

  Map<String, dynamic> _shopData() => {
    'revenue': _revenue,
    'expenses': _expenses,
    'salesCount': _salesCount,
    'products': products.map((p) => p.toJson()).toList(),
    'credits': credits.map((p) => p.toJson()).toList(),
    'sales': sales.map((p) => p.toJson()).toList(),
    'expenseRecords': expenseRecords.map((p) => p.toJson()).toList(),
    'settings': _shopPreferences == null
        ? <String, dynamic>{}
        : readSharedShopPreferences(_shopPreferences!),
  };

  void _applyShopData(Map<String, dynamic> data) {
    setState(() {
      _revenue = data['revenue'] as int;
      _expenses = data['expenses'] as int;
      _salesCount = data['salesCount'] as int;
      products
        ..clear()
        ..addAll(
          (data['products'] as List).map(
            (item) => Product.fromJson(item as Map<String, dynamic>),
          ),
        );
      credits
        ..clear()
        ..addAll(
          (data['credits'] as List).map(
            (item) => Credit.fromJson(item as Map<String, dynamic>),
          ),
        );
      sales
        ..clear()
        ..addAll(
          (data['sales'] as List).map(
            (item) => SaleRecord.fromJson(item as Map<String, dynamic>),
          ),
        );
      expenseRecords
        ..clear()
        ..addAll(
          ((data['expenseRecords'] as List?) ?? const []).map(
            (item) => ExpenseRecord.fromJson(item as Map<String, dynamic>),
          ),
        );
    });
  }

  Future<void> _loadData() async {
    final preferences = await SharedPreferences.getInstance();
    _shopPreferences = preferences;
    final stored = preferences.getString(_storageKey);
    if (!mounted) return;
    if (stored != null) {
      try {
        _applyShopData(Map<String, dynamic>.from(jsonDecode(stored) as Map));
        _hasLocalData = true;
      } catch (_) {
        setState(
          () => _syncStatus =
              'Données locales illisibles : synchronisation suspendue',
        );
        return;
      }
    }
    setState(() => _dataReady = true);
    await _synchronizeShop();
    if (!mounted) return;
    _shopSyncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => unawaited(_synchronizeShop()),
    );
  }

  Future<void> _synchronizeShop() async {
    if (!_supabaseReady ||
        !_dataReady ||
        _syncBusy ||
        widget.staffAccount != null ||
        supabase.auth.currentUser?.id != widget.storageUserId)
      return;
    // Sending local sales is allowed while the till is open. Applying a different
    // remote snapshot waits until the editor/sale route closes.
    _syncBusy = true;
    final generation = _localGeneration;
    try {
      final preferences = await SharedPreferences.getInstance();
      final remote = SupabaseShopSyncRemote(supabase, widget.storageUserId);
      final sync = ShopSync(widget.storageUserId, remote, preferences);
      var local = _shopData();
      final capturedLocal = canonicalShopData(local);
      if (!_hasLocalData && await remote.read() == null) {
        final rows = await supabase
            .from('store_products')
            .select('product_key,name,price,stock,image_url')
            .eq('shop_id', widget.storageUserId)
            .eq('active', true);
        local = {
          ...local,
          'products': [
            for (final row in rows)
              {
                'cloudKey': row['product_key'],
                'name': row['name'],
                'price': row['price'],
                'stock': row['stock'],
                'imageUrl': row['image_url'] ?? '',
              },
          ],
        };
      }
      final result = await sync.synchronize(
        local,
        hasLocalData: _hasLocalData,
        remember: false,
      );
      if (!mounted) return;
      if (generation == _localGeneration &&
          canonicalShopData(_shopData()) == capturedLocal &&
          (ModalRoute.of(context)?.isCurrent == true ||
              canonicalShopData(result) == capturedLocal)) {
        if (canonicalShopData(result) != canonicalShopData(_shopData())) {
          if (_hasLocalData)
            await preferences.setString(
              '${_storageKey}_before_sync',
              jsonEncode(_shopData()),
            );
          if (!mounted ||
              generation != _localGeneration ||
              ModalRoute.of(context)?.isCurrent != true)
            return;
          _applyShopData(result);
        }
        if (result['settings'] is Map) {
          await writeSharedShopPreferences(
            preferences,
            Map<String, dynamic>.from(result['settings'] as Map),
          );
        }
        if (!await preferences.setString(_storageKey, jsonEncode(_shopData())))
          throw StateError('Sauvegarde locale impossible.');
        await sync.commit(result);
        _hasLocalData = true;
        await _syncStorefrontProducts();
        if (generation == _localGeneration &&
            mounted &&
            ModalRoute.of(context)?.isCurrent == true) {
          final withImages = _shopData();
          if (canonicalShopData(withImages) != canonicalShopData(result)) {
            await sync.synchronize(
              withImages,
              hasLocalData: true,
              remember: false,
            );
            await sync.commit(withImages);
          }
        }
        if (mounted)
          setState(() {
            _syncStatus = 'Boutique synchronisée';
            _syncConflict = false;
          });
      } else {
        setState(
          () => _syncStatus = 'Modifications locales en attente d’envoi',
        );
      }
    } on ShopSyncConflict {
      if (mounted)
        setState(() {
          _syncConflict = true;
          _syncStatus =
              'Conflit : modifications sur deux appareils. Données locales conservées.';
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _syncStatus =
              'Non synchronisé : vérifiez Internet et la configuration du serveur. Données conservées sur cet appareil.',
        );
    } finally {
      _syncBusy = false;
    }
  }

  Future<void> _resolveShopConflict() async {
    if (_syncBusy) return;
    setState(() => _syncBusy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final remote = SupabaseShopSyncRemote(supabase, widget.storageUserId);
      final cloud = await remote.read();
      if (cloud == null || !mounted) return;
      final local = _shopData();
      final generation = _localGeneration;
      String summary(Map<String, dynamic> data) =>
          '${(data['products'] as List? ?? []).length} produits • ${(data['sales'] as List? ?? []).length} ventes • ${(data['expenseRecords'] as List? ?? []).length} dépenses';
      final choice = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Choisir la version de la boutique'),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Cet appareil : ${summary(local)}'),
                  const SizedBox(height: 12),
                  Text('Version synchronisée : ${summary(cloud.data)}'),
                  const SizedBox(height: 16),
                  const Text(
                    'Les modifications des deux versions ne seront pas fusionnées. La version choisie remplacera l’autre. Les deux copies seront sauvegardées sur cet appareil avant le remplacement.',
                  ),
                  TextButton(
                    onPressed: () async {
                      await FilePicker.saveFile(
                        dialogTitle: 'Sauvegarder les deux versions',
                        fileName: 'sauvegarde-conflit-boutique.json',
                        type: FileType.custom,
                        allowedExtensions: ['json'],
                        bytes: Uint8List.fromList(
                          utf8.encode(
                            jsonEncode({'local': local, 'cloud': cloud.data}),
                          ),
                        ),
                      );
                    },
                    child: const Text(
                      'Exporter les deux copies avant de choisir',
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Annuler'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, 'cloud'),
              child: const Text('Récupérer la version synchronisée'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, 'local'),
              child: const Text('Garder cet appareil'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted || generation != _localGeneration) return;
      if (!await prefs.setString(
        'shop_conflict_backup_${widget.storageUserId}_${DateTime.now().millisecondsSinceEpoch}',
        jsonEncode({'local': local, 'cloud': cloud.data}),
      ))
        throw StateError('Sauvegarde impossible');
      final chosen = choice == 'local' ? local : cloud.data;
      final revision = choice == 'local'
          ? await remote.write(local, cloud.revision)
          : cloud.revision;
      if (!mounted) return;
      if (choice == 'cloud') {
        _applyShopData(chosen);
        if (chosen['settings'] is Map)
          await writeSharedShopPreferences(
            prefs,
            Map<String, dynamic>.from(chosen['settings'] as Map),
          );
      }
      if (!await prefs.setString(_storageKey, jsonEncode(_shopData())))
        throw StateError('Enregistrement local impossible');
      final sync = ShopSync(widget.storageUserId, remote, prefs)
        ..synchronizedRevision = revision;
      await sync.commit(chosen);
      if (mounted)
        setState(() {
          _syncConflict = false;
          _syncStatus = 'Version choisie enregistrée';
        });
    } catch (_) {
      if (mounted)
        setState(
          () => _syncStatus =
              'Résolution interrompue. Les copies sont conservées ; réessayez la synchronisation.',
        );
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _saveData() async {
    _localGeneration++;
    for (var i = 0; i < products.length; i++) {
      if (products[i].cloudKey.isEmpty)
        products[i].cloudKey = '${DateTime.now().microsecondsSinceEpoch}-$i';
    }
    final payload = jsonEncode(_shopData());
    final preferences = await SharedPreferences.getInstance();
    final saved = await preferences.setString(_storageKey, payload);
    if (!saved) throw StateError('Enregistrement local impossible.');
    _hasLocalData = true;
    unawaited(_synchronizeShop());
  }

  Future<void> _syncStorefrontProducts() async {
    if (!_supabaseReady || widget.offlineMode || widget.staffAccount != null)
      return;
    final userId = supabase.auth.currentUser?.id;
    if (userId == null || userId != widget.storageUserId) return;
    if (_lastPublishedCatalog ==
        canonicalShopData(products.map((p) => p.toJson()).toList()))
      return;
    try {
      var generatedKey = false;
      for (var index = 0; index < products.length; index++) {
        final product = products[index];
        if (product.cloudKey.isEmpty) {
          product.cloudKey =
              '${DateTime.now().microsecondsSinceEpoch}-$index-${product.name.hashCode.abs()}';
          generatedKey = true;
        }
        final localImage = File(product.imagePath);
        if (product.imagePath.isNotEmpty &&
            localImage.existsSync() &&
            (product.imageUrl.isEmpty ||
                product.syncedImagePath != product.imagePath)) {
          final rawExtension = product.imagePath.contains('.')
              ? product.imagePath.split('.').last.toLowerCase()
              : 'jpg';
          final extension =
              const ['jpg', 'jpeg', 'png', 'webp'].contains(rawExtension)
              ? rawExtension
              : 'jpg';
          final contentType = extension == 'png'
              ? 'image/png'
              : extension == 'webp'
              ? 'image/webp'
              : 'image/jpeg';
          final objectPath = '$userId/${product.cloudKey}.$extension';
          await supabase.storage
              .from('product-images')
              .upload(
                objectPath,
                localImage,
                fileOptions: FileOptions(
                  upsert: true,
                  contentType: contentType,
                ),
              );
          product.imageUrl = supabase.storage
              .from('product-images')
              .getPublicUrl(objectPath);
          product.syncedImagePath = product.imagePath;
          generatedKey = true;
        }
      }
      final keys = products.map((product) => product.cloudKey).toList();
      if (products.isNotEmpty) {
        await supabase
            .from('store_products')
            .upsert(
              products
                  .map(
                    (product) => {
                      'shop_id': userId,
                      'product_key': product.cloudKey,
                      'name': product.name,
                      'price': product.price,
                      'stock': product.stock,
                      'image_url': product.imageUrl,
                      'active': true,
                    },
                  )
                  .toList(),
              onConflict: 'shop_id,product_key',
            );
      }
      final existing = await supabase
          .from('store_products')
          .select('product_key')
          .eq('shop_id', userId);
      for (final row in existing) {
        final key = row['product_key']?.toString() ?? '';
        if (!keys.contains(key)) {
          await supabase
              .from('store_products')
              .update({'active': false})
              .eq('shop_id', userId)
              .eq('product_key', key);
        }
      }
      if (generatedKey) {
        final preferences = await SharedPreferences.getInstance();
        await preferences.setString(
          _storageKey,
          jsonEncode({
            'revenue': _revenue,
            'expenses': _expenses,
            'salesCount': _salesCount,
            'products': products.map((item) => item.toJson()).toList(),
            'credits': credits.map((item) => item.toJson()).toList(),
            'sales': sales.map((item) => item.toJson()).toList(),
            'expenseRecords': expenseRecords
                .map((item) => item.toJson())
                .toList(),
          }),
        );
      }
      _lastPublishedCatalog = canonicalShopData(
        products.map((p) => p.toJson()).toList(),
      );
    } catch (error) {
      unawaited(
        _logActivity(
          'storefront_sync_error',
          'Échec de synchronisation du catalogue web',
          severity: 'warning',
          metadata: {'error': error.toString()},
        ),
      );
    }
  }

  void _openOnlineOrders() {
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => OnlineOrdersPage(
          products: products,
          onValidated: _validateOnlineOrder,
        ),
      ),
    );
  }

  Future<void> _validateOnlineOrder(Map<String, dynamic> order) async {
    final rawItems = (order['items'] as List?) ?? const [];
    final items = rawItems
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    final total = (order['total'] as num?)?.toInt() ?? 0;
    final now = DateTime.now();
    setState(() {
      for (final item in items) {
        final productName = item['name']?.toString() ?? '';
        final quantity = (item['quantity'] as num?)?.toInt() ?? 0;
        final matches = products.where(
          (product) => product.name == productName,
        );
        if (matches.isNotEmpty) {
          matches.first.stock = (matches.first.stock - quantity).clamp(
            0,
            1 << 31,
          );
        }
      }
      _salesCount++;
      _revenue += total;
      sales.insert(
        0,
        SaleRecord(
          items.map((item) => item['name']).join(', '),
          total,
          order['payment_method']?.toString() ?? 'Commande web',
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
          number:
              'V-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${_salesCount.toString().padLeft(5, '0')}',
          client: order['customer_name']?.toString() ?? 'Client web',
          date:
              '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
          items: items
              .map(
                (item) => SaleItemRecord(
                  item['name']?.toString() ?? 'Article',
                  (item['quantity'] as num?)?.toInt() ?? 0,
                  (item['unit_price'] as num?)?.toInt() ?? 0,
                ),
              )
              .toList(),
        ),
      );
    });
    await _saveData();
  }

  void _openSale() {
    if (products.isEmpty) {
      _toast('Ajoutez d’abord au moins un produit.');
      return;
    }
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => Scaffold(
          body: SafeArea(
            child: SaleSheet(
              products: products,
              onValidated: (lines, payment, client) async {
                final receiptMessage =
                    (await SharedPreferences.getInstance()).getString(
                      receiptFooterKey,
                    ) ??
                    defaultReceiptFooter;
                final staff = widget.staffAccount;
                if (staff != null) {
                  final latest = (await LocalStaffStore().forShop(
                    staff.shopId,
                  )).where((a) => a.id == staff.id).firstOrNull;
                  if (latest == null ||
                      !latest.active ||
                      latest.role != staff.role) {
                    throw StateError(
                      'Session utilisateur expirée. Reconnectez-vous.',
                    );
                  }
                }
                final total = lines.fold(0, (sum, line) => sum + line.total);
                setState(() {
                  for (final line in lines) {
                    line.product.stock -= line.quantity;
                  }
                  _salesCount++;
                  _revenue += total;
                  final now = DateTime.now();
                  sales.insert(
                    0,
                    SaleRecord(
                      lines
                          .map(
                            (line) => line.quantity > 1
                                ? '${line.product.name} × ${line.quantity}'
                                : line.product.name,
                          )
                          .join(', '),
                      total,
                      payment,
                      '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}',
                      operatorId: widget.staffAccount?.id ?? '',
                      operatorName: widget.staffAccount?.name ?? '',
                      receiptMessage: receiptMessage,
                      number:
                          'V-${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-${_salesCount.toString().padLeft(5, '0')}',
                      client: client.isEmpty ? 'Client comptoir' : client,
                      date:
                          '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
                      items: lines
                          .map(
                            (line) => SaleItemRecord(
                              line.product.name,
                              line.quantity,
                              line.product.price,
                            ),
                          )
                          .toList(),
                    ),
                  );
                });
                final savedSale = sales.first;
                try {
                  await _finishSale(savedSale);
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      sales.remove(savedSale);
                      _salesCount--;
                      _revenue -= total;
                      for (final line in lines) {
                        line.product.stock += line.quantity;
                      }
                    });
                  }
                  rethrow;
                }
                unawaited(
                  _logActivity(
                    'sale_created',
                    'Vente de ${money(total)} FCFA enregistrée',
                    metadata: {
                      'amount': total,
                      'payment': payment,
                      'client': client.isEmpty ? 'Client comptoir' : client,
                      'items_count': lines.length,
                    },
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _toast(String message, {bool aboveSaleControls = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        margin: aboveSaleControls
            ? const EdgeInsets.fromLTRB(18, 0, 18, 100)
            : null,
      ),
    );
  }

  Future<void> _finishSale(SaleRecord sale) async {
    try {
      await _saveData();
    } catch (_) {
      throw StateError(
        'Échec de l’enregistrement local. Impression non lancée.',
      );
    }
    try {
      final sent = await ReceiptPrinting.afterSale(
        name: '${sale.number}.pdf',
        format: saleReceiptFormat(sale),
        buildReceipt: () => buildSaleReceipt(sale),
      );
      if (mounted) {
        _toast(
          sent
              ? 'Vente enregistrée • Ticket envoyé à l’imprimante'
              : 'Vente enregistrée • ${sale.payment}',
          aboveSaleControls: true,
        );
      }
    } catch (error) {
      if (!mounted) return;
      final detail = error is StateError
          ? error.message
          : 'Vérifiez l’imprimante.';
      _toast(
        'Vente enregistrée. Impression non confirmée : $detail Réimprimez depuis Ventes si nécessaire.',
        aboveSaleControls: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.staffAccount != null)
      return _staffWorkspace(widget.staffAccount!);
    final pages = [
      DashboardPage(
        shopName: widget.shopName,
        revenue: _revenue,
        expenses: _expenses,
        salesCount: _salesCount,
        products: products,
        credits: credits,
        onSale: _openSale,
        onNavigate: (index) => setState(() => _page = index),
      ),
      SalesPage(sales: sales, onSale: _openSale),
      ProductsPage(
        products: products,
        onChanged: () {
          setState(() {});
          _saveData();
          unawaited(
            _logActivity(
              'inventory_updated',
              'Catalogue ou stock modifié',
              metadata: {'products_count': products.length},
            ),
          );
        },
      ),
      MorePage(
        storageUserId: widget.storageUserId,
        shopName: widget.shopName,
        isSuperAdmin: widget.isSuperAdmin,
        revenue: _revenue,
        salesCount: _salesCount,
        expenses: _expenses,
        expenseRecords: expenseRecords,
        credits: credits,
        sales: sales,
        products: products,
        onOpenOnlineOrders: _openOnlineOrders,
        onPublishStorefront: _syncStorefrontProducts,
        onExpense: (record) {
          setState(() {
            expenseRecords.insert(0, record);
            _expenses += record.amount;
          });
          _saveData();
          unawaited(
            _logActivity(
              'expense_created',
              'Dépense ${record.nature} enregistrée',
              metadata: {'nature': record.nature, 'amount': record.amount},
            ),
          );
        },
        onCredit: (credit) {
          setState(() => credits.add(credit));
          _saveData();
          unawaited(
            _logActivity(
              'customer_credit_created',
              'Crédit client enregistré',
              metadata: {'customer': credit.customer, 'amount': credit.amount},
            ),
          );
        },
        onLogout: widget.onLogout,
        onDataChanged: _saveData,
      ),
    ];
    final isDesktop = MediaQuery.sizeOf(context).width >= 900;
    final navigation = const [
      NavigationRailDestination(
        icon: Icon(Icons.grid_view_rounded),
        label: Text('Accueil'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.receipt_long_outlined),
        label: Text('Ventes'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.inventory_2_outlined),
        label: Text('Produits'),
      ),
      NavigationRailDestination(
        icon: Icon(Icons.apps_rounded),
        label: Text('Plus'),
      ),
    ];
    final content = IndexedStack(index: _page, children: pages);
    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (isDesktop)
              NavigationRail(
                selectedIndex: _page,
                extended: MediaQuery.sizeOf(context).width >= 1180,
                minExtendedWidth: 210,
                labelType: MediaQuery.sizeOf(context).width >= 1180
                    ? NavigationRailLabelType.none
                    : NavigationRailLabelType.all,
                leading: Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Column(
                    children: [
                      const Icon(
                        Icons.storefront_rounded,
                        color: _green,
                        size: 32,
                      ),
                      const SizedBox(height: 14),
                      if (_page == 1)
                        FilledButton.icon(
                          onPressed: _openSale,
                          icon: const Icon(Icons.add),
                          label: const Text('Nouvelle vente'),
                        ),
                    ],
                  ),
                ),
                onDestinationSelected: (value) => setState(() => _page = value),
                destinations: navigation,
              ),
            if (isDesktop) const VerticalDivider(width: 1),
            Expanded(
              child: Column(
                children: [
                  if (_supabaseReady && widget.staffAccount == null)
                    Material(
                      color: const Color(0xFFF1F5F2),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Row(
                          children: [
                            const Icon(Icons.cloud_outlined, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _syncStatus,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Synchroniser maintenant',
                              onPressed: _syncBusy ? null : _synchronizeShop,
                              icon: const Icon(Icons.sync),
                            ),
                            if (_syncConflict)
                              TextButton(
                                onPressed: _syncBusy
                                    ? null
                                    : _resolveShopConflict,
                                child: const Text('Résoudre'),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.offlineMode)
                    Container(
                      width: double.infinity,
                      color: const Color(0xFFFFF3D6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 9,
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            color: Color(0xFF9A6510),
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Mode hors ligne : vos données restent disponibles localement.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Expanded(
                    child: isDesktop
                        ? Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1500),
                              child: content,
                            ),
                          )
                        : content,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: isDesktop
          ? null
          : NavigationBar(
              selectedIndex: _page,
              indicatorColor: _green.withValues(alpha: .14),
              onDestinationSelected: (value) => setState(() => _page = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.grid_view_rounded),
                  label: 'Accueil',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  label: 'Ventes',
                ),
                NavigationDestination(
                  icon: Icon(Icons.inventory_2_outlined),
                  label: 'Produits',
                ),
                NavigationDestination(
                  icon: Icon(Icons.apps_rounded),
                  label: 'Plus',
                ),
              ],
            ),
      floatingActionButton: _page == 1 && !isDesktop
          ? FloatingActionButton.extended(
              onPressed: _openSale,
              backgroundColor: _green,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle vente'),
            )
          : null,
    );
  }

  Widget _staffWorkspace(LocalStaffAccount staff) {
    final pages = <Widget>[
      SalesPage(sales: sales, onSale: _openSale),
      if (staff.canManageStock)
        ProductsPage(
          products: products,
          onChanged: () {
            setState(() {});
            _saveData();
          },
        ),
      if (staff.canManageStock)
        ReportsPage(
          revenue: _revenue,
          expenses: _expenses,
          salesCount: _salesCount,
          creditTotal: credits.fold(0, (sum, c) => sum + c.remaining),
          sales: sales,
          products: products,
          expenseRecords: expenseRecords,
        ),
      if (staff.canManageUsers)
        LocalStaffPage(
          shopId: widget.storageUserId,
          shopName: widget.shopName,
          actingAccountId: staff.id,
        ),
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            '${staff.name} • ${staff.role}',
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
          ),
          Text(
            'Boutique : ${widget.shopName}\nSession locale • sans connexion Internet',
          ),
          const SizedBox(height: 20),
          const ReceiptPrintSettingsCard(),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
            label: const Text('Déconnexion / changer d’utilisateur'),
          ),
        ],
      ),
    ];
    final destinations = <NavigationDestination>[
      const NavigationDestination(
        icon: Icon(Icons.receipt_long),
        label: 'Ventes',
      ),
      if (staff.canManageStock)
        const NavigationDestination(
          icon: Icon(Icons.inventory_2_outlined),
          label: 'Produits',
        ),
      if (staff.canManageStock)
        const NavigationDestination(
          icon: Icon(Icons.bar_chart),
          label: 'Rapports',
        ),
      if (staff.canManageUsers)
        const NavigationDestination(
          icon: Icon(Icons.people),
          label: 'Utilisateurs',
        ),
      const NavigationDestination(
        icon: Icon(Icons.badge_outlined),
        label: 'Session',
      ),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.shopName} • ${staff.name} (${staff.role})'),
        actions: [
          IconButton(
            tooltip: 'Déconnexion',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: IndexedStack(index: _page, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _page,
        destinations: destinations,
        onDestinationSelected: (value) => setState(() => _page = value),
      ),
      floatingActionButton: _page == 0
          ? FloatingActionButton.extended(
              onPressed: _openSale,
              icon: const Icon(Icons.add),
              label: const Text('Nouvelle vente'),
            )
          : null,
    );
  }
}
