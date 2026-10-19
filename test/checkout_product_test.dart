import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  void desktop(WidgetTester tester) {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets(
    'attendre la fin, bloquer les doubles validations et préparer le client suivant',
    (tester) async {
      desktop(tester);
      final completion = Completer<void>();
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SaleSheet(
              products: [Product('Savon', 750, 5, Icons.inventory)],
              onValidated: (_, _, _) {
                calls++;
                return completion.future;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Ajouter au panier'));
      await tester.enterText(
        find.widgetWithText(TextField, 'Client (facultatif)'),
        'Issa',
      );
      await tester.tap(find.text('Orange Money'));
      await tester.tap(find.text('Valider la vente'));
      await tester.pump();
      expect(calls, 1);
      expect(find.text('Panier (1)'), findsOneWidget);
      expect(find.text('Validation en cours…'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find
            .ancestor(
              of: find.text('Validation en cours…'),
              matching: find.byWidgetPredicate((w) => w is FilledButton),
            )
            .first,
      );
      expect(button.onPressed, isNull);
      completion.complete();
      await tester.pumpAndSettle();
      expect(find.text('Panier (0)'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Client (facultatif)'),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<ChoiceChip>(
              find.ancestor(
                of: find.text('Espèces'),
                matching: find.byType(ChoiceChip),
              ),
            )
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<TextField>(
              find.widgetWithText(TextField, 'Lecteur de code-barres USB'),
            )
            .focusNode!
            .hasFocus,
        isTrue,
      );
      expect(calls, 1);
    },
  );

  testWidgets('échec d’enregistrement : conserver le panier', (tester) async {
    desktop(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SaleSheet(
            products: [Product('Savon', 750, 5, Icons.inventory)],
            onValidated: (_, _, _) async => throw StateError('storage failure'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ajouter au panier'));
    await tester.pump();
    await tester.tap(find.text('Valider la vente'));
    await tester.pumpAndSettle();
    expect(find.text('Panier (1)'), findsOneWidget);
    expect(find.textContaining('Vente non enregistrée'), findsOneWidget);
  });

  testWidgets('prix d’achat : ajout, validation et modification', (
    tester,
  ) async {
    desktop(tester);
    final products = <Product>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => ProductsPage(
              products: products,
              onChanged: () => setState(() {}),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Nom du produit'),
      'Savon',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prix de vente'),
      '750',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Stock initial'),
      '5',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prix d’achat (FCFA)'),
      '-10',
    );
    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    expect(products, isEmpty);
    expect(
      find.text('Saisissez un montant entier positif ou nul.'),
      findsOneWidget,
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prix d’achat (FCFA)'),
      '500',
    );
    await tester.tap(find.text('Ajouter'));
    await tester.pumpAndSettle();
    expect(products.single.purchasePrice, 500);
    expect(products.single.price, 750);
    await tester.tap(find.text('Savon'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.widgetWithText(TextField, 'Prix d’achat (FCFA)'),
          )
          .controller!
          .text,
      '500',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Prix d’achat (FCFA)'),
      '450',
    );
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(products.single.purchasePrice, 450);
    expect(products.single.price, 750);
    expect(Product.fromJson(products.single.toJson()).purchasePrice, 450);
    expect(tester.takeException(), isNull);
  });
}
