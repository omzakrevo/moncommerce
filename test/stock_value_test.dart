import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/stock_value.dart';

void main() {
  test('valorisation du stock et prix manquants', () {
    final value = StockValue([
      (stock: 10, price: 750, purchasePrice: 500),
      (stock: 2, price: 4000, purchasePrice: null),
      (stock: 0, price: 1000, purchasePrice: null),
    ]);
    expect(value.saleValue, 15500);
    expect(value.purchaseValue, 5000);
    expect(value.potentialMargin, 2500);
    expect(value.missingPrices, 1);
    expect(value.units, 12);
    expect(value.references, 2);
  });
  test('stock vide, achat gratuit et marge négative', () {
    expect(StockValue([]).saleValue, 0);
    final value = StockValue([(stock: 2, price: 100, purchasePrice: 150), (stock: 1, price: 20, purchasePrice: 0)]);
    expect(value.potentialMargin, -80);
    expect(value.missingPrices, 0);
  });
}
