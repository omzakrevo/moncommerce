part of '../main.dart';

class StorefrontSettingsPage extends StatefulWidget {
  const StorefrontSettingsPage({
    super.key,
    required this.products,
    required this.onOpenOrders,
    required this.onPublish,
  });

  final List<Product> products;
  final VoidCallback onOpenOrders;
  final Future<void> Function() onPublish;

  @override
  State<StorefrontSettingsPage> createState() => _StorefrontSettingsPageState();
}

class _StorefrontSettingsPageState extends State<StorefrontSettingsPage> {
  String _link = '';
  bool _loading = true;
  bool _publishing = false;

  @override
  void initState() {
    super.initState();
    _loadLink();
  }

  Future<void> _loadLink() async {
    try {
      final userId = supabase.auth.currentUser!.id;
      var row = await supabase
          .from('profiles')
          .select('store_slug,shop_name')
          .eq('id', userId)
          .single();
      var slug = row['store_slug']?.toString().trim() ?? '';
      if (slug.isEmpty) {
        await supabase
            .from('profiles')
            .update({'store_slug': null})
            .eq('id', userId);
        row = await supabase
            .from('profiles')
            .select('store_slug,shop_name')
            .eq('id', userId)
            .single();
        slug = row['store_slug']?.toString().trim() ?? '';
      }
      if (mounted) {
        setState(() {
          _link = slug.isEmpty
              ? ''
              : Uri.parse(
                  _storefrontBaseUrl,
                ).replace(queryParameters: {'shop': slug}).toString();
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _publish() async {
    setState(() => _publishing = true);
    await widget.onPublish();
    if (!mounted) return;
    setState(() => _publishing = false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Catalogue web mis à jour.')));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Boutique en ligne')),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [_dark, _green]),
            borderRadius: BorderRadius.circular(22),
          ),
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.language_rounded, color: Colors.white, size: 34),
              SizedBox(height: 14),
              Text(
                'Votre catalogue est accessible sur le Web',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 21,
                  fontWeight: FontWeight.w900,
                ),
              ),
              SizedBox(height: 7),
              Text(
                'Le client consulte les articles, remplit son panier et envoie sa commande sans installer l’application.',
                style: TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'Lien public de la boutique',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                SelectableText(
                  _loading
                      ? 'Chargement…'
                      : (_link.isEmpty ? 'Lien indisponible' : _link),
                  style: const TextStyle(color: _green),
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _link.isEmpty
                      ? null
                      : () => SharePlus.instance.share(
                          ShareParams(
                            text:
                                'Découvrez nos articles et commandez ici : $_link',
                          ),
                        ),
                  icon: const Icon(Icons.share_outlined),
                  label: const Text('Partager le lien'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _link.isEmpty
                      ? null
                      : () => launchUrl(
                          Uri.parse(_link),
                          mode: LaunchMode.externalApplication,
                        ),
                  icon: const Icon(Icons.open_in_browser_rounded),
                  label: const Text('Voir ma boutique'),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.inventory_2_outlined),
                ),
                title: Text('${widget.products.length} article(s)'),
                subtitle: const Text(
                  'Publier les prix et stocks actuels sur le catalogue',
                ),
                trailing: _publishing
                    ? const SizedBox.square(
                        dimension: 22,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.sync_rounded),
                onTap: _publishing ? null : _publish,
              ),
              const Divider(height: 1, indent: 70),
              ListTile(
                leading: const CircleAvatar(
                  child: Icon(Icons.shopping_bag_outlined),
                ),
                title: const Text('Commandes reçues'),
                subtitle: const Text(
                  'Accepter, refuser ou valider le paiement',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: widget.onOpenOrders,
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class OnlineOrdersPage extends StatefulWidget {
  const OnlineOrdersPage({
    super.key,
    required this.products,
    required this.onValidated,
  });

  final List<Product> products;
  final Future<void> Function(Map<String, dynamic>) onValidated;

  @override
  State<OnlineOrdersPage> createState() => _OnlineOrdersPageState();
}

class _OnlineOrdersPageState extends State<OnlineOrdersPage> {
  Future<void> _changeStatus(Map<String, dynamic> order, String status) async {
    try {
      final result = await supabase
          .from('store_orders')
          .update({
            'status': status,
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          })
          .eq('id', order['id'])
          .neq('status', 'validated')
          .select();
      if (result.isEmpty) return;
      if (status == 'validated') await widget.onValidated(order);
      unawaited(
        _logActivity(
          'online_order_$status',
          'Commande ${order['order_number']} : $status',
          metadata: {'order_id': order['id'], 'amount': order['total']},
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Action impossible : $error')));
    }
  }

  Future<void> _accept(Map<String, dynamic> order) async {
    final customerPaid = order['customer_paid'] == true;
    await _changeStatus(order, customerPaid ? 'validated' : 'accepted');
  }

  @override
  Widget build(BuildContext context) {
    final userId = supabase.auth.currentUser!.id;
    return Scaffold(
      appBar: AppBar(title: const Text('Commandes en ligne')),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        stream: supabase
            .from('store_orders')
            .stream(primaryKey: ['id'])
            .eq('shop_id', userId)
            .order('created_at', ascending: false),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Erreur : ${snapshot.error}'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final orders = snapshot.data!;
          if (orders.isEmpty) {
            return const Center(
              child: Text('Aucune commande reçue pour le moment.'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: orders.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final order = orders[index];
              final items = ((order['items'] as List?) ?? const [])
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList();
              final status = order['status']?.toString() ?? 'pending';
              final paid = order['customer_paid'] == true;
              return Card(
                child: ExpansionTile(
                  initiallyExpanded: status == 'pending',
                  leading: CircleAvatar(
                    backgroundColor: status == 'validated'
                        ? Colors.green.shade100
                        : status == 'rejected'
                        ? Colors.red.shade100
                        : Colors.orange.shade100,
                    child: Icon(
                      status == 'validated'
                          ? Icons.check_rounded
                          : Icons.shopping_bag_outlined,
                      color: status == 'validated' ? _green : _orange,
                    ),
                  ),
                  title: Text(
                    order['order_number']?.toString() ?? 'Commande',
                    style: const TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text(
                    '${order['customer_name']} • ${money((order['total'] as num).toInt())} F\n${_orderStatus(status)}${paid ? ' • Paiement déclaré' : ''}',
                  ),
                  childrenPadding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                  children: [
                    ...items.map(
                      (item) => ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(item['name']?.toString() ?? 'Article'),
                        subtitle: Text(
                          '${item['quantity']} × ${money((item['unit_price'] as num).toInt())} F',
                        ),
                        trailing: Text(
                          '${money((item['amount'] as num).toInt())} F',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                    const Divider(),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Client : ${order['customer_name']}\nTéléphone : ${order['customer_phone']}\nAdresse : ${order['delivery_address']?.toString().isEmpty == true ? 'Non précisée' : order['delivery_address']}\nPaiement : ${order['payment_method']}',
                      ),
                    ),
                    if ((order['notes']?.toString() ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Note : ${order['notes']}'),
                      ),
                    ],
                    const SizedBox(height: 14),
                    if (status == 'pending')
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => _changeStatus(order, 'rejected'),
                              child: const Text('Refuser'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed: () => _accept(order),
                              child: Text(
                                paid ? 'Accepter et valider' : 'Accepter',
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (status == 'accepted')
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: () => _changeStatus(order, 'validated'),
                          icon: const Icon(Icons.payments_outlined),
                          label: const Text('Paiement reçu • valider la vente'),
                        ),
                      ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

String _orderStatus(String value) => switch (value) {
  'accepted' => 'Acceptée • paiement attendu',
  'validated' => 'Validée et enregistrée en vente',
  'rejected' => 'Refusée',
  _ => 'En attente',
};
