import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const receiptFooterKey = 'receipt_footer_message_v1';
const defaultReceiptFooter = 'Merci pour votre confiance !';

/// Printer choices belong to this workstation, not to the cloud shop profile.
class ReceiptPrintSettings {
  const ReceiptPrintSettings({this.enabled = false, this.printer});

  final bool enabled;
  final Printer? printer;

  static Future<ReceiptPrintSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('receipt_printer_url');
    return ReceiptPrintSettings(
      enabled: prefs.getBool('receipt_auto_print') ?? false,
      printer: url == null || url.isEmpty
          ? null
          : Printer(url: url, name: prefs.getString('receipt_printer_name')),
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (enabled && printer == null) {
      throw StateError(
        'Choisissez une imprimante avant d’activer l’impression.',
      );
    }
    if (printer != null) {
      if (!await prefs.setString('receipt_printer_url', printer!.url) ||
          !await prefs.setString('receipt_printer_name', printer!.name)) {
        throw StateError('Impossible de mémoriser l’imprimante.');
      }
    }
    if (!await prefs.setBool('receipt_auto_print', enabled)) {
      throw StateError('Impossible de mémoriser le réglage.');
    }
  }
}

class ReceiptPrinting {
  /// Returns false when disabled. A failure never retries a physical print job.
  static Future<bool> afterSale({
    required String name,
    required PdfPageFormat format,
    required Future<Uint8List> Function() buildReceipt,
  }) async {
    final settings = await ReceiptPrintSettings.load();
    if (!settings.enabled) return false;
    final selected = settings.printer;
    if (selected == null) {
      throw StateError('Aucune imprimante de tickets sélectionnée.');
    }
    final info = await Printing.info();
    if (!info.directPrint || !info.canListPrinters) {
      throw StateError(
        'L’impression directe est indisponible sur cet appareil.',
      );
    }
    final matches = (await Printing.listPrinters()).where(
      (printer) => printer.url == selected.url && printer.isAvailable,
    );
    if (matches.isEmpty) {
      throw StateError('Imprimante indisponible : ${selected.name}.');
    }
    final bytes = await buildReceipt();
    final sent = await Printing.directPrintPdf(
      printer: matches.first,
      onLayout: (_) async => bytes,
      name: name,
      format: format,
      dynamicLayout: false,
    );
    if (!sent) throw StateError('Le ticket n’a pas été envoyé à l’imprimante.');
    return true;
  }
}

class ReceiptPrintSettingsCard extends StatefulWidget {
  const ReceiptPrintSettingsCard({super.key});

  @override
  State<ReceiptPrintSettingsCard> createState() =>
      _ReceiptPrintSettingsCardState();
}

class _ReceiptPrintSettingsCardState extends State<ReceiptPrintSettingsCard> {
  ReceiptPrintSettings settings = const ReceiptPrintSettings();
  bool busy = true;
  String? error;
  String footer = defaultReceiptFooter;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final saved = await ReceiptPrintSettings.load();
      final prefs = await SharedPreferences.getInstance();
      if (mounted)
        setState(() {
          settings = saved;
          footer = prefs.getString(receiptFooterKey) ?? defaultReceiptFooter;
        });
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Impossible de charger les réglages.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _editFooter() async {
    final saved = await showDialog<String>(
      context: context,
      builder: (_) => _ReceiptFooterEditor(initialText: footer),
    );
    if (saved != null && mounted) setState(() => footer = saved);
  }

  Future<void> _update({bool? enabled, bool choosePrinter = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      var printer = settings.printer;
      if (choosePrinter || (enabled == true && printer == null)) {
        final info = await Printing.info();
        if (!info.directPrint || !info.canListPrinters) {
          throw StateError(
            'L’impression directe est indisponible sur cet appareil.',
          );
        }
        final printers = (await Printing.listPrinters())
            .where((p) => p.isAvailable)
            .toList();
        if (printers.isEmpty) {
          throw StateError(
            'Aucune imprimante trouvée. Installez votre imprimante thermique dans les paramètres Windows.',
          );
        }
        if (!mounted) return;
        printer = await showDialog<Printer>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Choisir l’imprimante thermique'),
            children: printers
                .map(
                  (p) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(context, p),
                    child: Text(p.name),
                  ),
                )
                .toList(),
          ),
        );
        if (printer == null) return;
      }
      final updated = ReceiptPrintSettings(
        enabled: enabled ?? settings.enabled,
        printer: printer,
      );
      await updated.save();
      if (mounted) setState(() => settings = updated);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is StateError
              ? failure.message.toString()
              : 'Impossible de configurer l’impression. Vérifiez votre imprimante.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Tickets de caisse',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Imprimer après chaque vente'),
            subtitle: const Text(
              'Envoi direct à l’imprimante après enregistrement de la vente.',
            ),
            value: settings.enabled,
            onChanged: busy ? null : (value) => _update(enabled: value),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.print_outlined),
            title: Text(
              settings.printer?.name ?? 'Aucune imprimante sélectionnée',
            ),
            subtitle: const Text('Imprimante thermique • papier 80 mm'),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : () => _update(choosePrinter: true),
          ),
          const Text(
            'Réglages enregistrés automatiquement sur cet appareil. Vous pouvez réimprimer un ticket depuis l’historique des ventes.',
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.edit_note),
            title: const Text('Message personnalisé du ticket'),
            subtitle: Text(
              footer.isEmpty ? 'Aucun message' : footer,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: busy ? null : _editFooter,
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
  );
}

class _ReceiptFooterEditor extends StatefulWidget {
  const _ReceiptFooterEditor({required this.initialText});
  final String initialText;
  @override
  State<_ReceiptFooterEditor> createState() => _ReceiptFooterEditorState();
}

class _ReceiptFooterEditorState extends State<_ReceiptFooterEditor> {
  late final controller = TextEditingController(text: widget.initialText);
  bool busy = false;
  String? error;
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final message = controller.text.trim();
      if (!await prefs.setString(receiptFooterKey, message))
        throw StateError('save');
      if (mounted) Navigator.pop(context, message);
    } catch (_) {
      if (mounted)
        setState(() {
          busy = false;
          error = 'Impossible d’enregistrer le message.';
        });
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: const Text('Message personnalisé du ticket'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              enabled: !busy,
              maxLength: 240,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Message au bas du ticket',
                hintText: 'Merci de votre visite ! À bientôt.',
                helperText: 'Laissez vide pour ne pas afficher de message.',
              ),
            ),
            if (error != null) Text(error!),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Annuler'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(busy ? 'Enregistrement…' : 'Enregistrer'),
        ),
      ],
    ),
  );
}
