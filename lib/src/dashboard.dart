part of '../main.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.revenue,
    required this.shopName,
    required this.expenses,
    required this.salesCount,
    required this.products,
    required this.credits,
    required this.onSale,
    required this.onNavigate,
  });
  final int revenue, expenses, salesCount;
  final String shopName;
  final List<Product> products;
  final List<Credit> credits;
  final VoidCallback onSale;
  final ValueChanged<int> onNavigate;

  @override
  Widget build(BuildContext context) {
    final lowStock = products.where((p) => p.stock <= 6).length;
    final width = MediaQuery.sizeOf(context).width;
    final side = width > 1120 ? (width - 1120) / 2 + 18 : 18.0;
    return ListView(
      padding: EdgeInsets.fromLTRB(side, 18, side, 28),
      children: [
        Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: _green,
                borderRadius: BorderRadius.circular(15),
              ),
              child: const Icon(Icons.storefront_rounded, color: Colors.white),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Bonjour, $shopName',
                    style: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 17,
                    ),
                  ),
                  Text(
                    _todayLabel(),
                    style: const TextStyle(color: Colors.black54),
                  ),
                ],
              ),
            ),
            IconButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Notifications'),
                  content: Text(
                    '$lowStock produit(s) en stock faible et ${credits.length} crédit(s) à suivre.',
                  ),
                  actions: [
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Compris'),
                    ),
                  ],
                ),
              ),
              icon: const Badge(child: Icon(Icons.notifications_none_rounded)),
            ),
          ],
        ),
        const SizedBox(height: 22),
        Container(
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_dark, _green],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'CHIFFRE D’AFFAIRES DU JOUR',
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 12,
                  letterSpacing: .7,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${money(revenue)} FCFA',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 29,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _miniMetric(
                    Icons.shopping_bag_outlined,
                    '$salesCount ventes',
                  ),
                  const SizedBox(width: 22),
                  _miniMetric(
                    Icons.shopping_basket_outlined,
                    salesCount == 0
                        ? 'Panier moyen : -'
                        : 'Panier moyen : ${money(revenue ~/ salesCount)} F',
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: MetricCard(
                label: 'Bénéfice estimé',
                value: '${money(revenue - expenses)} F',
                icon: Icons.account_balance_wallet_outlined,
                color: _green,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: MetricCard(
                label: 'Dépenses',
                value: '${money(expenses)} F',
                icon: Icons.arrow_outward_rounded,
                color: const Color(0xFFD56A4D),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const SectionTitle('Actions rapides'),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: QuickAction(
                'Vendre',
                Icons.add_shopping_cart_rounded,
                _green,
                onSale,
                highlighted: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: QuickAction(
                'Produits',
                Icons.inventory_2_outlined,
                const Color(0xFF4776B7),
                () => onNavigate(2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: QuickAction(
                'Dépense',
                Icons.payments_outlined,
                const Color(0xFFD56A4D),
                () => onNavigate(3),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: QuickAction(
                'Crédits',
                Icons.people_outline_rounded,
                _orange,
                () => onNavigate(3),
              ),
            ),
          ],
        ),
        const SizedBox(height: 26),
        StockValueCard(
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
        const SizedBox(height: 24),
        SectionTitle('À surveiller', trailing: '$lowStock stock(s) faible(s)'),
        const SizedBox(height: 12),
        Card(
          child: Column(
            children: [
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFE9DF),
                  child: Icon(
                    Icons.warning_amber_rounded,
                    color: Color(0xFFD56A4D),
                  ),
                ),
                title: Text(
                  '$lowStock produits bientôt épuisés',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: const Text('Vérifiez votre stock'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onNavigate(2),
              ),
              const Divider(height: 1, indent: 72),
              ListTile(
                leading: const CircleAvatar(
                  backgroundColor: Color(0xFFFFF3D6),
                  child: Icon(Icons.schedule, color: _orange),
                ),
                title: Text(
                  '${credits.length} crédits à encaisser',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text(
                  '${money(credits.fold(0, (sum, item) => sum + item.remaining))} FCFA en attente',
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => onNavigate(3),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

String _todayLabel() {
  const days = [
    'Lundi',
    'Mardi',
    'Mercredi',
    'Jeudi',
    'Vendredi',
    'Samedi',
    'Dimanche',
  ];
  const months = [
    'janvier',
    'février',
    'mars',
    'avril',
    'mai',
    'juin',
    'juillet',
    'août',
    'septembre',
    'octobre',
    'novembre',
    'décembre',
  ];
  final now = DateTime.now();
  return '${days[now.weekday - 1]} ${now.day} ${months[now.month - 1]}';
}

Widget _miniMetric(IconData icon, String text) => Row(
  children: [
    Icon(icon, size: 17, color: Colors.white70),
    const SizedBox(width: 6),
    Text(
      text,
      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
    ),
  ],
);

class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label, value;
  final IconData icon;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(height: 14),
          Text(
            value,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.black54, fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class QuickAction extends StatelessWidget {
  const QuickAction(
    this.label,
    this.icon,
    this.color,
    this.onTap, {
    super.key,
    this.highlighted = false,
  });
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final bool highlighted;
  @override
  Widget build(BuildContext context) => Material(
    color: highlighted ? _green : Colors.white,
    elevation: 1.5,
    shadowColor: const Color(0x1A0F1F46),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
        child: Column(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: highlighted
                    ? Colors.white
                    : color.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: highlighted ? _green : color),
            ),
            const SizedBox(height: 8),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: highlighted ? Colors.white : _dark,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.trailing});
  final String title;
  final String? trailing;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w900,
            color: _dark,
          ),
        ),
      ),
      if (trailing != null)
        Text(
          trailing!,
          style: const TextStyle(
            color: _green,
            fontWeight: FontWeight.w600,
            fontSize: 12,
          ),
        ),
    ],
  );
}

class PageHeader extends StatelessWidget {
  const PageHeader(this.title, this.subtitle, {super.key});
  final String title, subtitle;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      MediaQuery.sizeOf(context).width > 1120
          ? (MediaQuery.sizeOf(context).width - 1120) / 2 + 18
          : 18,
      22,
      18,
      12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w900,
            color: _dark,
          ),
        ),
        const SizedBox(height: 3),
        Text(subtitle, style: const TextStyle(color: Colors.black54)),
      ],
    ),
  );
}

PdfPageFormat saleReceiptFormat(SaleRecord sale, {String? footerMessage}) =>
    PdfPageFormat(
      80 * PdfPageFormat.mm,
      (122 +
              (footerMessage ?? sale.receiptMessage ?? defaultReceiptFooter)
                      .split('\n')
                      .fold<int>(
                        0,
                        (count, line) =>
                            count + (line.length / 36).ceil().clamp(1, 100),
                      ) *
                  4 +
              (sale.items.isEmpty
                      ? sale.product.split(',').length
                      : sale.items.length) *
                  9) *
          PdfPageFormat.mm,
    );

Future<Uint8List> buildSaleReceipt(SaleRecord sale) async {
  final prefs = await SharedPreferences.getInstance();
  final footer =
      sale.receiptMessage ??
      prefs.getString(receiptFooterKey) ??
      defaultReceiptFooter;
  final shop = prefs.getString('shop_name') ?? 'MONCOMMERCE';
  final phone = prefs.getString('shop_phone') ?? '';
  final address = prefs.getString('shop_address') ?? '';
  final items = sale.items.isEmpty
      ? sale.product.split(',').map((rawItem) {
          final label = rawItem.trim();
          final quantityMatch = RegExp(
            r'\s*[×x]\s*(\d+)\s*$',
          ).firstMatch(label);
          final quantity = quantityMatch == null
              ? 1
              : int.tryParse(quantityMatch.group(1)!) ?? 1;
          final name = quantityMatch == null
              ? label
              : label.substring(0, quantityMatch.start).trim();
          return SaleItemRecord(
            name,
            quantity,
            sale.product.contains(',') ? 0 : sale.amount ~/ quantity,
          );
        }).toList()
      : sale.items;
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: saleReceiptFormat(sale, footerMessage: footer),
      margin: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 12),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Center(
            child: pw.Text(
              shop.toUpperCase(),
              style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold),
            ),
          ),
          if (address.isNotEmpty)
            pw.Center(
              child: pw.Text(address, style: const pw.TextStyle(fontSize: 8)),
            ),
          if (phone.isNotEmpty)
            pw.Center(
              child: pw.Text(
                'Tel : $phone',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.Text(
              'TICKET DE VENTE',
              style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ),
          pw.SizedBox(height: 4),
          pw.Text(
            '================================',
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                sale.number.isEmpty ? 'VENTE' : sale.number,
                style: const pw.TextStyle(fontSize: 8),
              ),
              pw.Text(
                '${sale.date} ${sale.time}',
                style: const pw.TextStyle(fontSize: 8),
              ),
            ],
          ),
          pw.Text(
            'Client : ${sale.client}',
            style: const pw.TextStyle(fontSize: 8),
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            children: [
              pw.Expanded(
                child: pw.Text(
                  'PRODUIT',
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 46,
                child: pw.Text(
                  'P. UNIT.',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 26,
                child: pw.Text(
                  'QTE',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
              pw.SizedBox(
                width: 48,
                child: pw.Text(
                  'MONTANT',
                  textAlign: pw.TextAlign.right,
                  style: pw.TextStyle(
                    fontSize: 6.5,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          pw.Text(
            '--------------------------------',
            style: const pw.TextStyle(fontSize: 7),
          ),
          ...items.map(
            (item) => pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 3),
              child: pw.Row(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Expanded(
                    child: pw.Text(
                      item.name,
                      style: const pw.TextStyle(fontSize: 8),
                    ),
                  ),
                  pw.SizedBox(
                    width: 46,
                    child: pw.Text(
                      item.unitPrice > 0 ? money(item.unitPrice) : '-',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  pw.SizedBox(
                    width: 26,
                    child: pw.Text(
                      '${item.quantity}',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                  pw.SizedBox(
                    width: 48,
                    child: pw.Text(
                      item.unitPrice > 0 ? money(item.total) : '-',
                      textAlign: pw.TextAlign.right,
                      style: const pw.TextStyle(fontSize: 7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          pw.Text(
            '================================',
            style: const pw.TextStyle(fontSize: 7),
          ),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                'TOTAL',
                style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              ),
              pw.Text(
                '${money(sale.amount)} FCFA',
                style: pw.TextStyle(
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('Paiement', style: const pw.TextStyle(fontSize: 8)),
              pw.Text(sale.payment, style: const pw.TextStyle(fontSize: 8)),
            ],
          ),
          pw.SizedBox(height: 7),
          if (footer.isNotEmpty)
            pw.Center(
              child: pw.Text(
                footer,
                textAlign: pw.TextAlign.center,
                style: const pw.TextStyle(fontSize: 8),
              ),
            ),
          pw.SizedBox(height: 5),
          pw.Center(
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data:
                  'MonCommerce|${sale.number}|${sale.date} ${sale.time}|${sale.amount} FCFA',
              width: 45,
              height: 45,
            ),
          ),
        ],
      ),
    ),
  );
  return document.save();
}
