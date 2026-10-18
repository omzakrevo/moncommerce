import 'package:flutter/material.dart';

class StockValue {
  StockValue(Iterable<({int stock, int price, int? purchasePrice})> articles) {
    for (final article in articles) {
      if (article.stock <= 0) {
        continue;
      }
      units += article.stock;
      references++;
      saleValue += article.stock * article.price;
      if (article.purchasePrice == null) {
        missingPrices++;
      } else {
        purchaseValue += article.stock * article.purchasePrice!;
        knownSaleValue += article.stock * article.price;
      }
    }
  }
  int units = 0, references = 0, saleValue = 0, purchaseValue = 0;
  int missingPrices = 0, knownSaleValue = 0;
  int get potentialMargin => knownSaleValue - purchaseValue;
}

class StockValueCard extends StatelessWidget {
  const StockValueCard({super.key, required this.value});
  final StockValue value;
  String amount(int number) =>
      '${number.toString().replaceAllMapped(RegExp(r"\B(?=(\d{3})+(?!\d))"), (_) => ' ')} FCFA';
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Valeur de la boutique',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 6),
          Text(
            '${value.references} article(s) en stock • ${value.units} unité(s)',
          ),
          const Divider(height: 24),
          Text(
            'Valeur du stock au prix d’achat${value.missingPrices > 0 ? ' (partielle)' : ''}',
          ),
          Text(
            amount(value.purchaseValue),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 14),
          const Text('Valeur du stock au prix de vente'),
          Text(
            amount(value.saleValue),
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 14),
          Text(
            'Marge potentielle${value.missingPrices > 0 ? ' sur les articles avec prix d’achat' : ''} : ${amount(value.potentialMargin)}',
          ),
          if (value.missingPrices > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '${value.missingPrices} article(s) en stock sans prix d’achat. Complétez leurs fiches pour obtenir la valeur totale au coût d’achat.',
              ),
            ),
          const SizedBox(height: 12),
          const Text(
            'Calcul basé sur les quantités actuellement en stock. La marge est estimée avant dépenses. Ces montants ne comprennent ni la caisse, ni les dettes, ni le matériel.',
          ),
        ],
      ),
    ),
  );
}
