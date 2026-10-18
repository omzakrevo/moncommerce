import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moncommerce/main.dart';
import 'package:moncommerce/receipt_printing.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:printing/src/interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakePrinting extends PrintingPlatform {
  List<Printer> printers = [
    const Printer(url: 'usb-thermal', name: 'Thermique 80 mm'),
  ];
  int jobs = 0;
  int queries = 0;
  bool accept = true;
  Printer? destination;
  PdfPageFormat? paper;

  @override
  Future<PrintingInfo> info() async =>
      const PrintingInfo(directPrint: true, canListPrinters: true);

  @override
  Future<List<Printer>> listPrinters() async {
    queries++;
    return printers;
  }

  @override
  Future<bool> layoutPdf(
    Printer? printer,
    LayoutCallback onLayout,
    String name,
    PdfPageFormat format,
    bool dynamicLayout,
    bool usePrinterSettings,
    OutputType outputType,
    bool forceCustomPrintPaper,
  ) async {
    jobs++;
    destination = printer;
    paper = format;
    expect(await onLayout(format), isNotEmpty);
    return accept;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePrinting printer;
  late PrintingPlatform original;
  final sale = SaleRecord(
    'Riz, Savon',
    5500,
    'Espèces',
    '14:30',
    number: 'V-20260924-00001',
    date: '24/09/2026',
    items: [
      SaleItemRecord('Riz parfumé 5 kg', 1, 4000),
      SaleItemRecord('Savon de Marseille', 2, 750),
    ],
  );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    original = PrintingPlatform.instance;
    printer = FakePrinting();
    PrintingPlatform.instance = printer;
  });
  tearDown(() => PrintingPlatform.instance = original);

  Future<bool> printSale() => ReceiptPrinting.afterSale(
    name: sale.number,
    format: saleReceiptFormat(sale),
    buildReceipt: () => buildSaleReceipt(sale),
  );
  Future<void> enable() => ReceiptPrintSettings(
    enabled: true,
    printer: printer.printers.first,
  ).save();

  test('désactivé par défaut : aucun PDF ni appel à l’imprimante', () async {
    expect(
      await ReceiptPrinting.afterSale(
        name: 'test',
        format: PdfPageFormat.roll80,
        buildReceipt: () async =>
            throw StateError('Ne doit pas générer de PDF'),
      ),
      isFalse,
    );
    expect(printer.jobs, 0);
    expect(printer.queries, 0);
  });

  test('réglage persistant, envoi unique et désactivation', () async {
    await enable();
    expect((await ReceiptPrintSettings.load()).printer!.url, 'usb-thermal');
    expect(await printSale(), isTrue);
    expect(printer.jobs, 1);
    expect(printer.destination!.url, 'usb-thermal');
    expect(printer.paper!.width, closeTo(80 * PdfPageFormat.mm, .01));
    await ReceiptPrintSettings(printer: printer.printers.first).save();
    expect(await printSale(), isFalse);
    expect(printer.jobs, 1);
  });

  test(
    'imprimante disparue : aucune redirection vers une autre imprimante',
    () async {
      await enable();
      printer.printers = [const Printer(url: 'office', name: 'Bureau')];
      await expectLater(printSale(), throwsStateError);
      expect(printer.jobs, 0);
    },
  );

  test('échec d’envoi : signalement sans tentative supplémentaire', () async {
    await enable();
    printer.accept = false;
    await expectLater(printSale(), throwsStateError);
    expect(printer.jobs, 1);
  });

  testWidgets('paramètres : sélection, activation et désactivation immédiate', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ReceiptPrintSettingsCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Thermique 80 mm'));
    await tester.pumpAndSettle();
    expect((await ReceiptPrintSettings.load()).enabled, isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect((await ReceiptPrintSettings.load()).enabled, isFalse);
    expect(printer.jobs, 0);
  });

  testWidgets('annuler le choix ne déclenche pas l’impression automatique', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ReceiptPrintSettingsCard())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    Navigator.of(tester.element(find.byType(SimpleDialog))).pop();
    await tester.pumpAndSettle();
    expect((await ReceiptPrintSettings.load()).enabled, isFalse);
  });

  test('le ticket réutilisé est un PDF valide', () async {
    await (await SharedPreferences.getInstance()).setString(
      receiptFooterKey,
      'Merci de votre visite !\nLes échanges sont possibles sous 48 heures avec ce ticket.',
    );
    final bytes = await buildSaleReceipt(sale);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    // Optional visual QA output; normal test runs do not write artifacts.
    if (const bool.fromEnvironment('RECEIPT_QA')) {
      await Directory('tmp/pdfs').create(recursive: true);
      await File(
        'tmp/pdfs/ticket-vente.pdf',
      ).writeAsBytes(Uint8List.fromList(bytes));
    }
  });

  testWidgets('message personnalisé enregistré depuis les réglages', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: ReceiptPrintSettingsCard()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Message personnalisé du ticket'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Message au bas du ticket'),
      'À bientôt chez nous !',
    );
    await tester.tap(find.text('Enregistrer'));
    await tester.pumpAndSettle();
    expect(
      (await SharedPreferences.getInstance()).getString(receiptFooterKey),
      'À bientôt chez nous !',
    );
    expect(find.text('À bientôt chez nous !'), findsOneWidget);
  });

  testWidgets('la caisse permet d’activer l’impression sans quitter la vente', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1366, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SaleSheet(
            products: [Product('Savon', 750, 5, Icons.inventory)],
            onValidated: (_, _, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Valider la vente'), findsOneWidget);
    await tester.tap(find.byTooltip('Configurer l’impression du ticket'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Thermique 80 mm'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Terminé'));
    await tester.pumpAndSettle();
    expect(find.byType(SaleSheet), findsOneWidget);
    expect(find.text('Valider et imprimer'), findsOneWidget);
    expect(find.text('Ticket automatique : Thermique 80 mm'), findsOneWidget);
    expect(printer.jobs, 0);
    expect(tester.takeException(), isNull);
  });

  for (final printSucceeds in [true, false]) {
    testWidgets(
      'validation de vente persistée, impression acceptée : $printSucceeds',
      (tester) async {
        tester.view.physicalSize = const Size(1366, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'moncommerce_data_v2_offline',
          jsonEncode({
            'revenue': 0,
            'expenses': 0,
            'salesCount': 0,
            'products': [
              Product(
                'Savon',
                750,
                5,
                Icons.inventory,
                barcode: '00123',
              ).toJson(),
            ],
            'credits': [],
            'sales': [],
            'expenseRecords': [],
          }),
        );
        await enable();
        printer.accept = printSucceeds;
        await tester.pumpWidget(
          MaterialApp(
            home: AppShell(
              shopName: 'Test',
              isSuperAdmin: false,
              offlineMode: true,
              onLogout: () async {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Vendre'));
        await tester.pumpAndSettle();
        expect(tester.getSize(find.byType(SaleSheet)), const Size(1366, 900));
        expect(find.text('Valider et imprimer'), findsOneWidget);
        expect(
          find.text('Ticket automatique : Thermique 80 mm'),
          findsOneWidget,
        );
        await tester.enterText(
          find.widgetWithText(TextField, 'Lecteur de code-barres USB'),
          '00123',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Valider et imprimer'));
        await tester.pumpAndSettle();
        final saved =
            jsonDecode(prefs.getString('moncommerce_data_v2_offline')!)
                as Map<String, dynamic>;
        expect(saved['salesCount'], 1);
        expect(saved['sales'], hasLength(1));
        expect(saved['products'][0]['stock'], 4);
        expect(printer.jobs, 1);
        expect(find.byType(SaleSheet), findsOneWidget);
        expect(find.text('Panier (0)'), findsOneWidget);
        expect(
          find.text(
            'Nouvelle vente prête. Scannez ou sélectionnez un produit.',
          ),
          findsOneWidget,
        );
        // A second customer can check out without opening another route.
        await tester.enterText(
          find.widgetWithText(TextField, 'Lecteur de code-barres USB'),
          '00123',
        );
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Valider et imprimer'));
        await tester.pumpAndSettle();
        final nextSaved =
            jsonDecode(prefs.getString('moncommerce_data_v2_offline')!)
                as Map<String, dynamic>;
        expect(nextSaved['salesCount'], 2);
        expect(nextSaved['sales'], hasLength(2));
        expect(nextSaved['products'][0]['stock'], 3);
        expect(printer.jobs, 2);
        expect(find.text('Panier (0)'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
