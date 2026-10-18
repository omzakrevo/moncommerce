import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';
import 'package:moncommerce/product_import.dart';

void main() {
  test('export Excel réimportable, prix achat et zéros conservés', () {
    final result = parseProductWorkbook(exportProductWorkbook([
      const ImportedProduct(name: 'Savon', price: 750, stock: 12, purchasePrice: 500, barcode: '001234'),
      const ImportedProduct(name: 'Riz', price: 4000, stock: 0),
    ]));
    expect(result.issues, isEmpty);
    expect(result.products.length, 2);
    expect(result.products.first.barcode, '001234');
    expect(result.products.first.purchasePrice, 500);
    expect(result.products.last.purchasePrice, isNull);
    expect(result.products.last.stock, 0);
  });

  testWidgets('inventaire, ajout de stock et annulation', (tester) async {
    final products = [Product('Savon', 750, 12, Icons.inventory), Product('Riz', 4000, 5, Icons.inventory)];
    var saves = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ProductsPage(products: products, onChanged: () => saves++))));
    Future<void> open(String action) async {
      await tester.tap(find.byTooltip('Import, export et inventaire'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
    }
    await open('Faire un inventaire');
    await tester.enterText(find.byKey(const ValueKey('inventory-0')), '-2');
    await tester.tap(find.text('Valider l’inventaire'));
    await tester.pump();
    expect(saves, 0);
    await tester.enterText(find.byKey(const ValueKey('inventory-0')), '0');
    await tester.tap(find.text('Valider l’inventaire'));
    await tester.pumpAndSettle();
    expect(products[0].stock, 0);
    expect(products[1].stock, 5);
    expect(saves, 1);
    await open('Ajouter du stock aux articles');
    await tester.enterText(find.byKey(const ValueKey('inventory-0')), '20');
    await tester.tap(find.text('Ajouter au stock'));
    await tester.pumpAndSettle();
    expect(products[0].stock, 20);
    expect(saves, 2);
    await open('Faire un inventaire');
    await tester.enterText(find.byKey(const ValueKey('inventory-0')), '99');
    await tester.tap(find.text('Annuler'));
    await tester.pumpAndSettle();
    expect(products[0].stock, 20);
    expect(saves, 2);
  });
}
