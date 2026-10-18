import 'package:flutter/material.dart';

class InventoryEntry {
  const InventoryEntry(this.name, this.barcode, this.stock);
  final String name, barcode;
  final int stock;
}

/// Null quantities leave the corresponding article unchanged.
class InventoryDialog extends StatefulWidget {
  const InventoryDialog({
    super.key,
    required this.entries,
    this.restock = false,
  });
  final List<InventoryEntry> entries;
  final bool restock;
  @override
  State<InventoryDialog> createState() => _InventoryDialogState();
}

class _InventoryDialogState extends State<InventoryDialog> {
  late final controllers = List.generate(
    widget.entries.length,
    (_) => TextEditingController(),
  );
  String search = '';
  @override
  void dispose() {
    for (final controller in controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  void submit() {
    // Validate all rows, including those hidden by the search.
    for (final controller in controllers) {
      final value = controller.text.trim();
      if (value.isNotEmpty &&
          (!RegExp(r'^\d+$').hasMatch(value) ||
              int.tryParse(value) == null ||
              (widget.restock && int.parse(value) == 0))) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.restock
                  ? 'Saisissez des quantités entières supérieures à zéro.'
                  : 'Saisissez des quantités entières positives ou nulles.',
            ),
          ),
        );
        return;
      }
    }
    final values = controllers.map((c) => int.tryParse(c.text.trim())).toList();
    if (values.every((v) => v == null)) {
      return;
    }
    Navigator.pop(context, values);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.restock ? 'Ajouter du stock' : 'Inventaire physique'),
    content: SizedBox(
      width: 680,
      height: 460,
      child: Column(
        children: [
          Text(
            widget.restock
                ? 'Les quantités reçues seront ajoutées au stock actuel.'
                : 'Les quantités comptées remplaceront le stock actuel. Saisissez 0 pour un article épuisé.',
          ),
          const Text(
            'Laissez vide pour conserver un article sans modification.',
          ),
          const SizedBox(height: 12),
          TextField(
            decoration: const InputDecoration(
              labelText: 'Rechercher : nom ou code-barres',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: (value) =>
                setState(() => search = value.trim().toLowerCase()),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: widget.entries.length,
              itemBuilder: (context, index) {
                final entry = widget.entries[index];
                if (!'${entry.name} ${entry.barcode}'.toLowerCase().contains(
                  search,
                )) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              entry.name,
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text('Stock actuel : ${entry.stock}'),
                            if (entry.barcode.isNotEmpty) Text(entry.barcode),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      SizedBox(
                        width: 180,
                        child: TextField(
                          key: ValueKey('inventory-$index'),
                          controller: controllers[index],
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: widget.restock
                                ? 'Quantité reçue'
                                : 'Quantité comptée',
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          Text(
            '${controllers.where((c) => c.text.trim().isNotEmpty).length} article(s) renseigné(s)',
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annuler'),
      ),
      FilledButton(
        onPressed: submit,
        child: Text(
          widget.restock ? 'Ajouter au stock' : 'Valider l’inventaire',
        ),
      ),
    ],
  );
}
